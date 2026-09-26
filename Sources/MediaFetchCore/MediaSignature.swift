import Foundation

/// Identifies downloaded media from its first bytes. A CDN that answers
/// `200 OK` with an HTML error page produces a file with the right name and
/// extension that cannot be played; reading the header tells them apart before
/// the file is hashed into a provenance manifest.
public enum MediaSignature: String, Codable, Sendable {
    case isoBMFF
    case matroska
    case mpegTS
    case mpegAudio
    case flac
    case ogg
    case wave
    case image
    case subtitle
    case json
    case html
    case unknown

    public var isErrorPage: Bool { self == .html }

    public static func detect(_ header: Data) -> MediaSignature {
        let b = [UInt8](header.prefix(64))
        func starts(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
            b.count >= offset + prefix.count && Array(b[offset..<offset + prefix.count]) == prefix
        }
        if starts(Array("ftyp".utf8), at: 4) { return .isoBMFF }
        if starts([0x1A, 0x45, 0xDF, 0xA3]) { return .matroska }
        if b.count >= 1, b[0] == 0x47, b.count < 189 || b[188] == 0x47 { return .mpegTS }
        if starts(Array("ID3".utf8)) || (b.count >= 2 && b[0] == 0xFF && (b[1] & 0xE0) == 0xE0) { return .mpegAudio }
        if starts(Array("fLaC".utf8)) { return .flac }
        if starts(Array("OggS".utf8)) { return .ogg }
        if starts(Array("RIFF".utf8)) && starts(Array("WAVE".utf8), at: 8) { return .wave }
        if starts([0xFF, 0xD8, 0xFF]) || starts([0x89, 0x50, 0x4E, 0x47])
            || (starts(Array("RIFF".utf8)) && starts(Array("WEBP".utf8), at: 8)) { return .image }
        let text = String(decoding: b, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
            .lowercased()
        if text.hasPrefix("webvtt") || text.hasPrefix("1\n00:") || text.hasPrefix("1\r\n00:") { return .subtitle }
        if text.hasPrefix("<!doctype html") || text.hasPrefix("<html") || text.hasPrefix("<head") { return .html }
        if text.hasPrefix("{") || text.hasPrefix("[") { return .json }
        return .unknown
    }

    public static func detect(fileAt url: URL) -> MediaSignature {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        return detect((try? handle.read(upToCount: 256)) ?? Data())
    }

    /// Media-bearing extensions whose content must never be an HTML page.
    public static func expectsMedia(_ url: URL) -> Bool {
        ["mp4", "m4a", "m4v", "mov", "mkv", "webm", "mka", "ts", "mp3", "aac", "opus", "ogg", "flac", "wav"]
            .contains(url.pathExtension.lowercased())
    }
}
