import Foundation
import MediaFetchCore

/// Builds yt-dlp argument arrays. Arguments are always passed as an array to
/// `Process`, never through a shell. Pure: no file system or process access,
/// so every flag decision is unit-testable.
public enum YtDLPArgumentBuilder {
    /// Parallel fragment ceiling for YouTube; above this measured gains vanish
    /// and 429 risk rises.
    public static let youtubeFragmentCeiling = 16
    public static let defaultFragments = 8

    /// Flags that make a single run survive flaky networks before our own
    /// attempt-level retry kicks in.
    public static let resilienceArguments = [
        "--retries", "5",
        "--fragment-retries", "5",
        "--extractor-retries", "3",
        "--file-access-retries", "3",
        "--socket-timeout", "30",
        "--retry-sleep", "exp=1:30"
    ]

    public static func isYouTube(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return host == "youtu.be" || host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com")
    }

    /// Tags, embedded cover, kept cover file and synced lyrics for music tracks.
    /// Formats stay the platform's originals; ffmpeg only remuxes tags in.
    public static let musicArguments = [
        "--embed-metadata", "--embed-thumbnail", "--convert-thumbnails", "jpg", "--write-thumbnail",
        "--write-subs", "--sub-langs", "lyrics,lrc", "--sub-format", "lrc/best"
    ]

    public static func isCoursePlatform(_ url: String) -> Bool {
        guard let parsed = URL(string: url) else { return false }
        let host = parsed.host?.lowercased() ?? ""
        return host.hasSuffix("udemy.com") || (host.hasSuffix("bilibili.com") && parsed.path.hasPrefix("/cheese"))
    }

    /// `--flat-playlist` listing for courses and playlists.
    public static func expansionArguments(url: String, cookieArguments: [String]) -> [String] {
        ["--flat-playlist", "--dump-single-json", "--ignore-errors", "--no-warnings", "--socket-timeout", "30", "--extractor-retries", "3"]
            + (isCoursePlatform(url) ? ["--sleep-requests", "1"] : [])
            + cookieArguments + [url]
    }

    public static func concurrentFragments(isYouTube: Bool, sessionRateLimitCount: Int) -> Int {
        guard isYouTube else { return defaultFragments }
        switch sessionRateLimitCount {
        case 0: return defaultFragments
        case 1: return 4
        default: return 2
        }
    }

    /// Arguments shared by analysis and download for per-attempt tuning.
    public static func tuningArguments(
        url: String,
        state: EngineAttemptState,
        sessionRateLimitCount: Int,
        forDownload: Bool = true
    ) -> [String] {
        var arguments: [String] = []
        let youtube = isYouTube(url)
        if youtube && (forDownload || state.youtubePlayerClient != nil) {
            // `formats=dashy` serves YouTube DASH as fragments so --concurrent-fragments
            // actually parallelises; measured +15–25 % on 2026-09-26 (Wi-Fi, 355 MB, 1440p60).
            var options = forDownload ? ["formats=dashy"] : []
            if let client = state.youtubePlayerClient { options.insert("player_client=\(client)", at: 0) }
            arguments += ["--extractor-args", "youtube:" + options.joined(separator: ";")]
        }
        if state.forceIPv4 { arguments.append("--force-ipv4") }
        // Course platforms watch request rates per account: always pace them.
        let paced = isCoursePlatform(url)
        if (youtube && sessionRateLimitCount > 0) || paced {
            arguments += ["--sleep-requests", "1", "--sleep-interval", "2", "--max-sleep-interval", "5"]
        }
        return arguments
    }

    public static func analysisArguments(
        url: String,
        state: EngineAttemptState = EngineAttemptState(),
        sessionRateLimitCount: Int = 0,
        cookieArguments: [String] = []
    ) -> [String] {
        ["--dump-single-json", "--skip-download", "--no-playlist", "--no-warnings",
         "--socket-timeout", "30", "--extractor-retries", "3"]
            + tuningArguments(url: url, state: state, sessionRateLimitCount: sessionRateLimitCount, forDownload: false)
            + cookieArguments
            + [url]
    }

    public static func downloadArguments(
        job: DownloadJob,
        destination: URL,
        ffmpegPath: String?,
        state: EngineAttemptState,
        sessionRateLimitCount: Int,
        cookieArguments: [String]
    ) -> [String] {
        let youtube = isYouTube(job.sourceURL)
        var arguments = [
            "--newline", "--no-playlist", "--continue",
            "--format", job.musicQuality?.formatSelector ?? job.profile.formatSelector,
            "--paths", destination.path,
            "--progress-template", "download:MF_PROGRESS|%(progress._percent_str)s|%(progress.downloaded_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
            "--progress-template", "postprocess:MF_POSTPROCESS|%(info.title)s",
            "--print", "before_dl:MF_ID|%(id)s",
            "--print", "before_dl:MF_TITLE|%(title)s",
            "--print", "before_dl:MF_PLATFORM|%(extractor)s",
            "--print", "before_dl:MF_FORMAT|%(format_id)s|%(resolution)s|%(vcodec)s|%(acodec)s|%(ext)s",
            "--print", "after_move:MF_FILE|%(filepath)s"
        ]
        arguments += resilienceArguments
        if job.musicQuality != nil {
            // Music files are small; NetEase occasionally stalls one API call until
            // the socket timeout, so a shorter timeout halves that worst case.
            // (Later --socket-timeout wins in yt-dlp's option parsing.)
            arguments += ["--socket-timeout", "15"]
        }
        arguments += [
            "--concurrent-fragments",
            String(concurrentFragments(isYouTube: youtube, sessionRateLimitCount: sessionRateLimitCount))
        ]
        if youtube { arguments += ["--throttled-rate", "100K"] }

        if job.musicQuality != nil {
            let layout = job.musicLayout ?? (job.collection == nil ? .flat : .collection)
            arguments += ["--output", layout.outputTemplate(collection: job.collection, custom: job.musicNameTemplate)]
            arguments += musicArguments
            arguments += ["--print", "before_dl:MF_MUSIC|%(creators.0,artists.0,artist,album_artists.0|)s|%(album|)s"]
        } else if let collection = job.collection {
            arguments += ["--output", CollectionPaths.outputTemplate(for: collection, separateStreams: job.profile == .sourceStreams)]
        } else {
            let packageName = "%(title).180B [%(id)s]"
            if job.profile == .sourceStreams {
                arguments += ["--output", "\(packageName)/\(packageName).f%(format_id)s.%(ext)s"]
            } else {
                arguments += ["--output", "\(packageName)/\(packageName).%(ext)s"]
            }
        }
        if job.profile == .highest {
            arguments += ["--merge-output-format", "mkv"]
        } else if job.profile == .compatibleMP4 {
            arguments += ["--merge-output-format", "mp4"]
        }
        if job.includeSidecars { arguments += ["--write-info-json", "--write-thumbnail"] }
        if job.includeSubtitles && state.subtitlesEnabled && job.musicQuality == nil {
            arguments += [
                "--write-subs", "--write-auto-subs", "--sub-langs",
                "en,zh,zh-CN,zh-TW,zh-Hans,zh-Hant,-live_chat"
            ]
            if youtube { arguments += ["--sleep-subtitles", "5"] }
        }
        if let ffmpegPath { arguments += ["--ffmpeg-location", ffmpegPath] }
        arguments += tuningArguments(url: job.sourceURL, state: state, sessionRateLimitCount: sessionRateLimitCount)
        arguments += cookieArguments
        arguments.append(job.sourceURL)
        return arguments
    }

    /// Human-readable command for the audit view. Cookie file paths are
    /// replaced so temporary credential locations never reach UI or logs.
    public static func redactedCommandLine(executable: String, arguments: [String]) -> String {
        var parts = [shellQuoted(executable)]
        var hideNext = false
        for argument in arguments {
            if hideNext {
                parts.append("<cookies>")
                hideNext = false
                continue
            }
            if argument == "--cookies" { hideNext = true }
            parts.append(shellQuoted(argument))
        }
        return parts.joined(separator: " ")
    }

    static func shellQuoted(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=,+@%"))
        if !value.isEmpty && value.unicodeScalars.allSatisfy(safe.contains) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
