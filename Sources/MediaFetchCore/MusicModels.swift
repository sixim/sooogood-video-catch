import Foundation

/// Audio quality tiers as music services name them. Ordered low → high.
public enum MusicQualityTier: Int, Codable, Comparable, CaseIterable, Sendable {
    case low        // < 128 kbps (e.g. 48/96 kbps AAC)
    case standard   // 128 kbps
    case higher     // 192 kbps
    case high       // 320 kbps (极高 / HQ)
    case lossless   // 16-bit FLAC/APE/ALAC (无损 / SQ)
    case hires      // 24-bit or > 48 kHz lossless (Hi-Res / 母带)

    public var displayName: String {
        switch self {
        case .low: return String(localized: "低音质")
        case .standard: return String(localized: "标准 128k")
        case .higher: return String(localized: "较高 192k")
        case .high: return String(localized: "极高 320k")
        case .lossless: return String(localized: "无损")
        case .hires: return "Hi-Res"
        }
    }

    public var isLossless: Bool { self >= .lossless }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    static let losslessCodecs: Set<String> = ["flac", "alac", "ape", "wav", "pcm_s16le", "pcm_s24le"]

    /// Classifies one yt-dlp format. NetEase level names are authoritative
    /// when present; otherwise codec and bitrate decide.
    public static func classify(formatID: String?, codec: String?, ext: String?, bitrate: Double?, sampleRate: Double?) -> MusicQualityTier {
        switch formatID?.lowercased() {
        case "standard": return .standard
        case "higher": return .higher
        case "exhigh": return .high
        case "lossless": return .lossless
        case "hires", "jymaster", "jyeffect": return .hires
        default: break
        }
        let codec = (codec ?? "").lowercased()
        let ext = (ext ?? "").lowercased()
        if losslessCodecs.contains(codec) || ["flac", "ape", "wav"].contains(ext) {
            if let rate = sampleRate, rate > 48_000 { return .hires }
            return .lossless
        }
        guard let kbps = bitrate else { return .standard }
        switch kbps {
        case 300...: return .high
        case 180..<300: return .higher
        case 120..<180: return .standard
        default: return .low
        }
    }
}

public struct MusicFormatOption: Equatable, Sendable, Identifiable {
    public let formatID: String
    public let tier: MusicQualityTier
    public let ext: String
    public let bitrate: Double?
    public let fileSize: Int64?

    public var id: String { formatID }
}

/// One track as resolved by yt-dlp (`-J`), reduced to what the music UI needs.
public struct MusicTrackInfo: Equatable, Sendable {
    public let id: String
    public let title: String
    public let artists: [String]
    public let album: String?
    public let duration: Double?
    public let thumbnail: String?
    public let hasLyrics: Bool
    public let formats: [MusicFormatOption]

    public var artistLine: String { artists.isEmpty ? String(localized: "未知歌手") : artists.joined(separator: " / ") }
    public var bestTier: MusicQualityTier? { formats.map(\.tier).max() }
    public var availableTiers: [MusicQualityTier] { Array(Set(formats.map(\.tier))).sorted() }

    public static func parse(_ json: JSONValue) -> MusicTrackInfo? {
        guard let id = json["id"]?.stringValue, let title = json["title"]?.stringValue ?? json["track"]?.stringValue else { return nil }
        func strings(_ key: String) -> [String] { json[key]?.arrayValue?.compactMap(\.stringValue) ?? [] }
        var artists = strings("artists")
        if artists.isEmpty { artists = strings("creators") }
        if artists.isEmpty, let single = json["artist"]?.stringValue ?? json["creator"]?.stringValue {
            artists = single.components(separatedBy: ", ")
        }
        if artists.isEmpty { artists = strings("album_artists") }
        let formats = (json["formats"]?.arrayValue ?? []).compactMap { format -> MusicFormatOption? in
            guard let formatID = format["format_id"]?.stringValue else { return nil }
            let vcodec = format["vcodec"]?.stringValue ?? "none"
            guard vcodec == "none" || vcodec.isEmpty else { return nil } // audio only
            let bitrate = format["abr"]?.doubleValue ?? format["tbr"]?.doubleValue
            return MusicFormatOption(
                formatID: formatID,
                tier: .classify(formatID: formatID, codec: format["acodec"]?.stringValue, ext: format["ext"]?.stringValue,
                                bitrate: bitrate, sampleRate: format["asr"]?.doubleValue),
                ext: format["ext"]?.stringValue ?? "",
                bitrate: bitrate,
                fileSize: (format["filesize"]?.doubleValue ?? format["filesize_approx"]?.doubleValue).map { Int64($0) }
            )
        }
        let subtitles = json["subtitles"]?.objectValue ?? [:]
        return MusicTrackInfo(
            id: id, title: title, artists: artists, album: json["album"]?.stringValue,
            duration: json["duration"]?.doubleValue, thumbnail: json["thumbnail"]?.stringValue,
            hasLyrics: subtitles.keys.contains { $0.lowercased().contains("lyric") }, formats: formats
        )
    }
}

/// What the user wants when several qualities exist.
public enum MusicQualityPreference: String, Codable, CaseIterable, Sendable, Identifiable {
    case best
    case losslessOnly
    case upTo320

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .best: return String(localized: "最高可用音质")
        case .losslessOnly: return String(localized: "只要无损")
        case .upTo320: return String(localized: "最高 320k（省空间）")
        }
    }

    /// yt-dlp `--format` selector. Platform original formats only; never transcodes.
    public var formatSelector: String {
        switch self {
        case .best: return "ba/b"
        case .losslessOnly: return "ba[acodec=flac]/ba[ext=flac]/ba[acodec=alac]/ba[ext=ape]"
        case .upTo320: return "ba[acodec!=flac][ext!=flac][ext!=ape][abr<=320]/ba[acodec!=flac][ext!=flac][ext!=ape]"
        }
    }

    /// Which tier this preference would pick from what a track offers (nil = would fail).
    public func expectedTier(from tiers: [MusicQualityTier]) -> MusicQualityTier? {
        switch self {
        case .best: return tiers.max()
        case .losslessOnly: return tiers.filter(\.isLossless).max()
        case .upTo320: return tiers.filter { !$0.isLossless }.max()
        }
    }
}

/// How downloaded tracks are arranged on disk. Each track is still its own
/// package folder (audio + cover + lyrics + manifest.json).
public enum MusicLayout: String, Codable, CaseIterable, Sendable, Identifiable {
    case artistAlbum
    case flat
    case collection
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .artistAlbum: return String(localized: "歌手 / 专辑 / 歌曲")
        case .flat: return String(localized: "歌手 - 歌曲（平铺）")
        case .collection: return String(localized: "按歌单顺序")
        case .custom: return String(localized: "自定义模板")
        }
    }

    /// yt-dlp output template. Metadata fields are sanitized by yt-dlp; our own
    /// folder names (collection) go through `CollectionPaths.safeComponent`.
    public func outputTemplate(collection: CollectionContext?, custom: String? = nil) -> String {
        if self == .custom { return MusicNameTemplate(custom ?? MusicNameTemplate.defaultTemplate).ytDLPTemplate(collection: collection) }
        let artist = "%(creators.0,artists.0,artist,album_artists.0,uploader|\(MusicFallbackName.artist)).80B"
        let album = "%(album|\(MusicFallbackName.album)).80B"
        let track = "\(artist) - %(title).120B [%(id)s]"
        switch self {
        case .artistAlbum:
            return "\(artist)/\(album)/\(track)/\(track).%(ext)s"
        case .flat:
            return "\(track)/\(track).%(ext)s"
        case .custom:
            return "\(track)/\(track).%(ext)s"
        case .collection:
            guard let collection else { return "\(track)/\(track).%(ext)s" }
            let root = collection.rootFolderName.replacingOccurrences(of: "%", with: "%%")
            let numbered = String(format: "%03d", collection.index) + " - " + track
            return "\(root)/\(numbered)/\(numbered).%(ext)s"
        }
    }
}

/// What the downloaded file actually is, measured with ffprobe — not what the
/// platform labelled it. Written into the package manifest.
public struct AudioQualityReport: Codable, Equatable, Sendable {
    public let codec: String
    public let sampleRate: Int?
    public let bitsPerSample: Int?
    public let bitrate: Int?
    public let channels: Int?
    public let durationSeconds: Double?
    public let tier: MusicQualityTier
    /// Tier the selected platform format promised (from its format id / codec).
    public let expectedTier: MusicQualityTier?

    /// False when the file is worse than what the platform said it would be.
    public var meetsExpectation: Bool { expectedTier.map { tier >= $0 } ?? true }

    public var summary: String {
        var parts = [codec.uppercased()]
        if let rate = sampleRate { parts.append(String(format: "%.1f kHz", Double(rate) / 1000)) }
        if let bits = bitsPerSample, tier.isLossless { parts.append("\(bits)-bit") }
        if let bitrate, !tier.isLossless { parts.append("\(bitrate / 1000) kbps") }
        return parts.joined(separator: " · ")
    }

    /// Parses `ffprobe -of json -show_format -show_streams`; the first real audio stream counts.
    public static func parse(ffprobeJSON data: Data, expectedTier: MusicQualityTier?) -> AudioQualityReport? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let stream = json["streams"]?.arrayValue?.first(where: { $0["codec_type"]?.stringValue == "audio" }),
              let codec = stream["codec_name"]?.stringValue else { return nil }
        func int(_ value: JSONValue?) -> Int? { value?.stringValue.flatMap(Int.init) ?? value?.intValue }
        let sampleRate = int(stream["sample_rate"])
        var bits = int(stream["bits_per_raw_sample"])
        if bits == nil || bits == 0 { bits = int(stream["bits_per_sample"]) }
        if bits == 0 { bits = nil }
        let duration = stream["duration"]?.stringValue.flatMap(Double.init) ?? json["format"]?["duration"]?.stringValue.flatMap(Double.init)
        var bitrate = int(stream["bit_rate"])
        if bitrate == nil, let total = int(json["format"]?["bit_rate"]) { bitrate = total }
        var tier = MusicQualityTier.classify(formatID: nil, codec: codec, ext: nil,
                                             bitrate: bitrate.map { Double($0) / 1000 }, sampleRate: sampleRate.map(Double.init))
        if tier == .lossless, let bits, bits > 16 { tier = .hires }
        return AudioQualityReport(codec: codec, sampleRate: sampleRate, bitsPerSample: bits, bitrate: bitrate,
                                  channels: int(stream["channels"]), durationSeconds: duration,
                                  tier: tier, expectedTier: expectedTier)
    }
}

/// User file-name template with `{artist}` `{album}` `{title}` `{id}` `{index}`
/// tokens and `/` for folders. Literal text is escaped for yt-dlp, `..` and
/// empty segments are dropped, and the track id is always kept in the last
/// segment so two songs with the same title never collide.
public struct MusicNameTemplate: Equatable, Sendable {
    public static let defaultTemplate = "{artist}/{album}/{artist} - {title}"
    public static let tokens = ["artist", "album", "title", "id", "index"]

    public let raw: String

    public init(_ raw: String) { self.raw = raw }

    var segments: [String] {
        raw.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    public func ytDLPTemplate(collection: CollectionContext?) -> String {
        var parts = segments.isEmpty ? MusicNameTemplate(Self.defaultTemplate).segments : segments
        if !(parts.last ?? "").contains("{id}") { parts[parts.count - 1] += " [{id}]" }
        let index = collection.map { String(format: "%03d", $0.index) } ?? "%(playlist_index|0)03d"
        let fields: [String: String] = [
            "artist": "%(creators.0,artists.0,artist,album_artists.0,uploader|\(MusicFallbackName.artist)).80B",
            "album": "%(album|\(MusicFallbackName.album)).80B",
            "title": "%(title).120B",
            "id": "%(id)s",
            "index": index
        ]
        let converted = parts.map { segment -> String in
            var output = ""
            var rest = Substring(segment.replacingOccurrences(of: "%", with: "%%"))
            while let open = rest.firstIndex(of: "{") {
                output += rest[..<open]
                guard let close = rest[open...].firstIndex(of: "}") else { output += rest[open...]; rest = ""; break }
                let name = String(rest[rest.index(after: open)..<close])
                output += fields[name] ?? "{\(name)}"
                rest = rest[rest.index(after: close)...]
            }
            return output + rest
        }
        let leaf = converted.last!
        return (converted + ["\(leaf).%(ext)s"]).joined(separator: "/")
    }

    /// Example path for the settings preview.
    public func preview() -> String {
        var parts = segments.isEmpty ? MusicNameTemplate(Self.defaultTemplate).segments : segments
        if !(parts.last ?? "").contains("{id}") { parts[parts.count - 1] += " [{id}]" }
        let sample = ["artist": String(localized: "周杰伦"), "album": String(localized: "叶惠美"), "title": String(localized: "晴天"), "id": "0039MnYb0qxYhV", "index": "001"]
        var text = parts.joined(separator: "/")
        for (key, value) in sample { text = text.replacingOccurrences(of: "{\(key)}", with: value) }
        return text + "/" + (text.split(separator: "/").last.map(String.init) ?? "") + ".flac"
    }
}

/// Folder names used when a track has no artist / album, in the UI language.
/// Characters with meaning in yt-dlp output templates are removed.
public enum MusicFallbackName {
    public static var artist: String { sanitized(String(localized: "未知歌手")) }
    public static var album: String { sanitized(String(localized: "未知专辑")) }

    static func sanitized(_ name: String) -> String {
        String(name.filter { !"%|()/\\".contains($0) })
    }
}
