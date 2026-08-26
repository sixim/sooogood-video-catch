import CryptoKit
import Foundation

struct MediaManifest: Codable {
    struct ToolVersions: Codable {
        let mediaFetch: String
        let ytDLP: String
        let ffmpeg: String
    }

    struct FileRecord: Codable {
        let relativePath: String
        let byteSize: Int64
        let sha256: String
    }

    let schemaVersion: Int
    let jobID: UUID
    let sourceURL: String
    let platform: String?
    let mediaID: String?
    let title: String?
    let downloadedAt: Date
    let profile: String
    let formatSelector: String
    let selectedFormats: [SelectedFormatInfo]
    let browserSessionSource: String?
    let sidecarsRequested: Bool
    let subtitlesRequested: Bool
    let tools: ToolVersions
    let files: [FileRecord]
}

enum ManifestWriter {
    static func write(
        job: DownloadJob,
        packageDirectory: URL,
        platform: String?,
        mediaID: String?,
        selectedFormats: [SelectedFormatInfo],
        ytDLPPath: String,
        ffmpegPath: String?
    ) throws -> URL {
        let manager = FileManager.default
        let fileURLs = try manager.contentsOfDirectory(
            at: packageDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        let records = try fileURLs
            .filter { $0.lastPathComponent != "manifest.json" }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url -> MediaManifest.FileRecord in
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                return MediaManifest.FileRecord(
                    relativePath: url.lastPathComponent,
                    byteSize: Int64(values.fileSize ?? 0),
                    sha256: try sha256(url)
                )
            }

        let manifest = MediaManifest(
            schemaVersion: 1,
            jobID: job.id,
            sourceURL: job.sourceURL,
            platform: platform,
            mediaID: mediaID,
            title: job.title,
            downloadedAt: Date(),
            profile: job.profile.rawValue,
            formatSelector: job.profile.formatSelector,
            selectedFormats: selectedFormats,
            browserSessionSource: job.browserCookieSource?.displayName,
            sidecarsRequested: job.includeSidecars,
            subtitlesRequested: job.includeSubtitles,
            tools: .init(
                mediaFetch: "0.2.1",
                ytDLP: version(of: ytDLPPath, arguments: ["--version"]),
                ffmpeg: ffmpegPath.map { version(of: $0, arguments: ["-version"], firstLineOnly: true) } ?? "not installed"
            ),
            files: records
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let url = packageDirectory.appendingPathComponent("manifest.json")
        try encoder.encode(manifest).write(to: url, options: .atomic)
        return url
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func version(of executable: String, arguments: [String], firstLineOnly: Bool = false) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            return firstLineOnly ? (text.components(separatedBy: .newlines).first ?? text) : text
        } catch {
            return "unknown"
        }
    }
}
