import Foundation

/// Cover art checks for music packages. yt-dlp only warns when the thumbnail
/// fetch fails, so a finished track can silently lack its cover; these helpers
/// detect that and build the ffmpeg call that embeds a recovered image.
public enum MusicCover {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp"]

    /// The kept cover file next to the audio (same base name, as yt-dlp writes it).
    public static func sidecar(for audio: URL, in files: [URL]) -> URL? {
        let base = audio.deletingPathExtension().lastPathComponent
        return files.first {
            imageExtensions.contains($0.pathExtension.lowercased()) && $0.deletingPathExtension().lastPathComponent == base
        }
    }

    /// Whether `ffprobe -of json -show_streams` reports an attached picture.
    public static func hasAttachedPicture(ffprobeJSON data: Data) -> Bool {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return false }
        return json["streams"]?.arrayValue?.contains {
            $0["disposition"]?["attached_pic"]?.doubleValue == 1
        } == true
    }

    /// ffmpeg arguments that add `image` as the front cover without re-encoding
    /// audio, or nil when the container has no attached-picture support here.
    public static func embedArguments(audio: URL, image: URL, output: URL) -> [String]? {
        let ext = audio.pathExtension.lowercased()
        guard ["mp3", "flac", "m4a", "mp4"].contains(ext) else { return nil }
        var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                         "-i", audio.path, "-i", image.path,
                         "-map", "0:a", "-map", "1:0", "-c", "copy", "-map_metadata", "0",
                         "-disposition:v:0", "attached_pic"]
        if ext == "mp3" {
            arguments += ["-id3v2_version", "3", "-metadata:s:v", "title=Album cover", "-metadata:s:v", "comment=Cover (front)"]
        }
        return arguments + [output.path]
    }

    /// yt-dlp output template for the cover file: the audio's base name with
    /// `%` escaped so it is taken literally.
    public static func thumbnailTemplate(for audio: URL) -> String {
        audio.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "%", with: "%%") + ".%(ext)s"
    }
}
