import Foundation
import MediaFetchCore

/// Embeds downloaded `.lrc` lyrics and recovered covers into the audio file's
/// own tags, so players show them without sidecars. Audio is never re-encoded.
enum MusicTagger {
    /// Returns true when lyrics were embedded.
    @discardableResult
    static func embedLyrics(audio: URL, lrc: URL, ffmpeg: URL?, environment: [String: String]) -> Bool {
        guard let lyrics = try? String(contentsOf: lrc, encoding: .utf8), !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        switch audio.pathExtension.lowercased() {
        case "mp3":
            // ffmpeg writes lyrics as TXXX; players read USLT, so write that frame directly.
            guard let data = try? Data(contentsOf: audio),
                  let tagged = try? ID3LyricsWriter.embed(lyrics: LRCText.plainText(lyrics), into: data) else { return false }
            return (try? tagged.write(to: audio, options: .atomic)) != nil
        case "flac", "ogg", "opus":
            return remux(audio, metadata: ["LYRICS": lyrics], ffmpeg: ffmpeg, environment: environment)
        case "m4a", "mp4", "aac":
            return remux(audio, metadata: ["lyrics": LRCText.plainText(lyrics)], ffmpeg: ffmpeg, environment: environment)
        default:
            return false
        }
    }

    /// Whether the audio file already carries an embedded cover.
    static func hasEmbeddedCover(_ audio: URL, ffprobe: URL?, environment: [String: String]) -> Bool {
        guard let ffprobe else { return false }
        let result = ProcessRunner.run(ffprobe, ["-v", "error", "-of", "json", "-show_streams", audio.path], environment: environment)
        return result.status == 0 && MusicCover.hasAttachedPicture(ffprobeJSON: result.stdout)
    }

    /// Embeds `image` as the front cover (audio copied, never re-encoded).
    /// Returns true when the file was rewritten.
    @discardableResult
    static func embedCover(audio: URL, image: URL, ffmpeg: URL?, environment: [String: String]) -> Bool {
        guard let ffmpeg else { return false }
        let temporary = audio.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).\(audio.pathExtension)")
        guard let arguments = MusicCover.embedArguments(audio: audio, image: image, output: temporary) else { return false }
        return replace(audio, with: temporary, after: ProcessRunner.run(ffmpeg, arguments, environment: environment).status)
    }

    private static func remux(_ audio: URL, metadata: [String: String], ffmpeg: URL?, environment: [String: String]) -> Bool {
        guard let ffmpeg else { return false }
        let temporary = audio.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).\(audio.pathExtension)")
        var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", audio.path, "-map", "0", "-c", "copy", "-map_metadata", "0"]
        for (key, value) in metadata { arguments += ["-metadata", "\(key)=\(value)"] }
        arguments.append(temporary.path)
        return replace(audio, with: temporary, after: ProcessRunner.run(ffmpeg, arguments, environment: environment).status)
    }

    private static func replace(_ audio: URL, with temporary: URL, after status: Int32) -> Bool {
        guard status == 0, FileManager.default.fileExists(atPath: temporary.path) else {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
        do {
            _ = try FileManager.default.replaceItemAt(audio, withItemAt: temporary)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
    }
}
