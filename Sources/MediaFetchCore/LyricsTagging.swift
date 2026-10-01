import Foundation

/// LRC handling for embedding lyrics into audio tags.
public enum LRCText {
    private static let timestamp = try! NSRegularExpression(pattern: #"\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\]"#)
    private static let tagLine = try! NSRegularExpression(pattern: #"^\[(ar|ti|al|by|offset|re|ve|length):.*\]$"#, options: [.caseInsensitive])

    /// Plain text for unsynchronised lyrics frames (USLT / ©lyr): timestamps and
    /// LRC header tags removed, repeated blank lines collapsed.
    public static func plainText(_ lrc: String) -> String {
        var lines: [String] = []
        for raw in lrc.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if tagLine.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil { continue }
            let range = NSRange(raw.startIndex..., in: raw)
            let text = timestamp.stringByReplacingMatches(in: raw, range: range, withTemplate: "").trimmingCharacters(in: .whitespaces)
            if text.isEmpty && (lines.last?.isEmpty ?? true) { continue }
            lines.append(text)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

/// Inserts (or replaces) an ID3v2 USLT frame — the lyrics frame players read —
/// in an MP3 that already has an ID3v2.3/2.4 tag (yt-dlp/ffmpeg always write one).
public enum ID3LyricsWriter {
    public enum Failure: Error, Equatable {
        case noID3Tag
        case unsupportedTag(String)
    }

    public static func embed(lyrics: String, language: String = "chi", into mp3: Data) throws -> Data {
        let bytes = [UInt8](mp3)
        guard bytes.count >= 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else { throw Failure.noID3Tag }
        let major = bytes[3]
        guard major == 3 || major == 4 else { throw Failure.unsupportedTag("ID3v2.\(major)") }
        let flags = bytes[5]
        guard flags & 0xC0 == 0 else { throw Failure.unsupportedTag("unsynchronised or extended header") }
        let tagSize = syncsafe(bytes[6...9])
        let tagEnd = 10 + tagSize
        guard tagEnd <= bytes.count else { throw Failure.unsupportedTag("truncated tag") }

        // Keep every frame except an existing USLT; drop padding.
        var frames: [UInt8] = []
        var offset = 10
        while offset + 10 <= tagEnd {
            let id = bytes[offset..<offset + 4]
            if id.allSatisfy({ $0 == 0 }) { break } // padding
            let size = major == 4 ? syncsafe(bytes[offset + 4...offset + 7]) : bigEndian(bytes[offset + 4...offset + 7])
            let frameEnd = offset + 10 + size
            guard size >= 0, frameEnd <= tagEnd else { throw Failure.unsupportedTag("bad frame size") }
            if Array(id) != Array("USLT".utf8) { frames += bytes[offset..<frameEnd] }
            offset = frameEnd
        }

        // USLT: encoding 1 (UTF-16 with BOM), language, empty descriptor, text.
        var body: [UInt8] = [0x01] + Array(language.utf8.prefix(3)) + Array(repeating: 0x20, count: max(0, 3 - language.utf8.count))
        body += [0xFF, 0xFE, 0x00, 0x00]
        body += [0xFF, 0xFE] + utf16LE(lyrics)
        var header = Array("USLT".utf8)
        header += major == 4 ? encodeSyncsafe(body.count) : encodeBigEndian(body.count)
        header += [0x00, 0x00]
        frames += header + body

        let newHeader: [UInt8] = [0x49, 0x44, 0x33, major, bytes[4], flags & 0x30] + encodeSyncsafe(frames.count)
        return Data(newHeader + frames + bytes[tagEnd...])
    }

    static func syncsafe(_ slice: ArraySlice<UInt8>) -> Int {
        slice.reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
    }

    static func bigEndian(_ slice: ArraySlice<UInt8>) -> Int {
        slice.reduce(0) { ($0 << 8) | Int($1) }
    }

    static func encodeSyncsafe(_ value: Int) -> [UInt8] {
        [UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F), UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)]
    }

    static func encodeBigEndian(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    static func utf16LE(_ text: String) -> [UInt8] {
        text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    }
}
