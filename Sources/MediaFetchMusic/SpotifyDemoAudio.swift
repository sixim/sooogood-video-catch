import Foundation

/// Creates tiny, silent WAV files for the Store review/demo path.
///
/// These files are generated locally only after the user explicitly chooses
/// “查看演示”. They contain no third-party recording and never use ffprobe,
/// FFmpeg, a network request, or an external executable.
public enum SpotifyDemoAudioFactory {
    public static func prepare(
        in directory: URL,
        tracks: [SpotifyTrackReference],
        fileManager: FileManager = .default
    ) throws -> [URL] {
        guard directory.isFileURL else { return [] }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        return try tracks.prefix(2).enumerated().map { index, track in
            let filename = String(format: "%02d-%02d %@ - %@.wav", track.discNumber, track.trackNumber, track.artists.first ?? "Demo Artist", track.title)
            let url = directory.appendingPathComponent(sanitized(filename))
            try silentWAV().write(to: url, options: .atomic)
            return url
        }
    }

    private static func silentWAV() -> Data {
        let sampleRate: UInt32 = 44_100
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let sampleCount = sampleRate
        let dataSize = sampleCount * UInt32(channels) * UInt32(bitsPerSample / 8)

        var data = Data()
        data.append(contentsOf: Data("RIFF".utf8))
        appendLittleEndian(36 + dataSize, to: &data)
        data.append(contentsOf: Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(channels, to: &data)
        appendLittleEndian(sampleRate, to: &data)
        appendLittleEndian(sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8), to: &data)
        appendLittleEndian(channels * (bitsPerSample / 8), to: &data)
        appendLittleEndian(bitsPerSample, to: &data)
        data.append(contentsOf: Data("data".utf8))
        appendLittleEndian(dataSize, to: &data)
        data.append(Data(repeating: 0, count: Int(dataSize)))
        return data
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func appendLittleEndian(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func sanitized(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:\0")
        let result = value
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "MediaFetch Demo.wav" : result
    }
}
