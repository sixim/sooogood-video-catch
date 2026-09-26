import Foundation

/// A file produced from another file (proxy, transcode, transcript…), recorded
/// in `derivatives.json` next to the source. The original `manifest.json` is
/// never rewritten; this log is how later steps (e.g. Resolve proxy linking)
/// know what came from what.
public struct DerivativeRecord: Codable, Equatable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable {
        case proxy
        case transcode
        case audio
        case subtitle
        case transcript
        case preview
        case compressed
    }

    public struct FileRef: Codable, Equatable, Sendable {
        public let relativePath: String
        public let byteSize: Int64
        public let sha256: String

        public init(relativePath: String, byteSize: Int64, sha256: String) {
            self.relativePath = relativePath
            self.byteSize = byteSize
            self.sha256 = sha256
        }
    }

    public let id: UUID
    public let createdAt: Date
    public let tool: String
    public let preset: String
    public let role: Role
    public let source: FileRef
    public let output: FileRef
    /// Engine command, for reproducibility; contains local paths only.
    public let command: [String]
    public let engineVersion: String
    public let elapsedSeconds: Double

    public init(tool: String, preset: String, role: Role, source: FileRef, output: FileRef,
                command: [String], engineVersion: String, elapsedSeconds: Double) {
        id = UUID()
        createdAt = Date()
        self.tool = tool
        self.preset = preset
        self.role = role
        self.source = source
        self.output = output
        self.command = command
        self.engineVersion = engineVersion
        self.elapsedSeconds = elapsedSeconds
    }
}

public enum DerivativeLog {
    public static let fileName = "derivatives.json"
    public static let schemaVersion = 1

    struct Document: Codable {
        let schemaVersion: Int
        var derivatives: [DerivativeRecord]
    }

    public static func load(in directory: URL) -> [DerivativeRecord] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return [] }
        return (try? decoder.decode(Document.self, from: data))?.derivatives ?? []
    }

    public static func append(_ record: DerivativeRecord, in directory: URL) throws {
        var document = Document(schemaVersion: schemaVersion, derivatives: load(in: directory))
        document.derivatives.append(record)
        try encoder.encode(document).write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }

    /// Edit-grade proxies win when a clip has several (Resolve links one).
    static let proxyPreference = ["proresProxy", "dnxhrLB", "h264Proxy"]

    /// Absolute source path → absolute proxy path, for proxies whose files still exist.
    public static func proxies(in directory: URL) -> [String: String] {
        var best: [String: (rank: Int, path: String)] = [:]
        for record in load(in: directory) where record.role == .proxy {
            let source = directory.appendingPathComponent(record.source.relativePath).path
            let proxy = directory.appendingPathComponent(record.output.relativePath).path
            guard FileManager.default.fileExists(atPath: proxy) else { continue }
            let rank = proxyPreference.firstIndex(of: record.preset) ?? proxyPreference.count
            if let current = best[source], current.rank <= rank { continue }
            best[source] = (rank, proxy)
        }
        return best.mapValues(\.path)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
