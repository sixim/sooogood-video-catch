import Foundation
import MediaFetchCore

/// Embeds downloaded `.lrc` lyrics into the audio file's own tags, so players
/// show lyrics without the sidecar. Audio streams are never re-encoded.
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

    private static func remux(_ audio: URL, metadata: [String: String], ffmpeg: URL?, environment: [String: String]) -> Bool {
        guard let ffmpeg else { return false }
        let temporary = audio.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).\(audio.pathExtension)")
        var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", audio.path, "-map", "0", "-c", "copy", "-map_metadata", "0"]
        for (key, value) in metadata { arguments += ["-metadata", "\(key)=\(value)"] }
        arguments.append(temporary.path)
        let result = ProcessRunner.run(ffmpeg, arguments, environment: environment)
        guard result.status == 0, FileManager.default.fileExists(atPath: temporary.path) else {
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
