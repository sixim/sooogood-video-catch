import Foundation
import MediaFetchCore

// BitTorrent is Local-profile only; nothing here ships in the Store binary.
#if !MEDIAFETCH_STORE_PROFILE
/// App-side facts about a torrent that the engine does not keep: why and when
/// it was added, the seeding policy, and where its manifest went. Stored apart
/// from video/Spotify history, per the module boundary rules.
public struct TorrentRecord: Codable, Equatable, Sendable, Identifiable {
    public let hash: String
    public var name: String
    public let addedAt: Date
    public var downloadDirectory: String
    public var magnetLink: String?
    public var seedPolicy: SeedPolicy
    public var awaitingFileSelection: Bool
    public var manifestPath: String?
    public var completedAt: Date?
    public var lastError: String?

    public var id: String { hash }

    public init(hash: String, name: String, downloadDirectory: String, magnetLink: String?,
                seedPolicy: SeedPolicy, awaitingFileSelection: Bool) {
        self.hash = hash
        self.name = name
        addedAt = Date()
        self.downloadDirectory = downloadDirectory
        self.magnetLink = magnetLink
        self.seedPolicy = seedPolicy
        self.awaitingFileSelection = awaitingFileSelection
    }
}

public enum TorrentHistoryStore {
    public static var historyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MediaFetch", isDirectory: true)
            .appendingPathComponent("torrent-history.json")
    }

    public static func load(from url: URL = historyURL) -> [TorrentRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TorrentRecord].self, from: data)) ?? []
    }

    public static func save(_ records: [TorrentRecord], to url: URL = historyURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(to: url, options: .atomic)
    }
}

/// Provenance for a finished torrent, in the same spirit as the video package
/// manifest: infohash plus SHA-256 of every downloaded file.
public enum TorrentManifestWriter {
    public static let schemaVersion = 1

    struct Manifest: Codable {
        struct File: Codable {
            let relativePath: String
            let byteSize: Int64
            let sha256: String
        }
        let schemaVersion: Int
        let kind: String
        let infoHash: String
        let name: String
        let magnetLink: String?
        let addedAt: Date
        let completedAt: Date
        let engine: String
        let mediaFetch: String
        let files: [File]
    }

    /// Multi-file torrents get `torrent-manifest.json` inside their folder;
    /// single-file torrents get `<file>.torrent-manifest.json` beside the file.
    public static func manifestURL(for snapshot: TorrentSnapshot) -> URL {
        let base = URL(fileURLWithPath: snapshot.downloadDirectory, isDirectory: true)
        let isFolder = snapshot.files.count > 1 || snapshot.files.first?.name.contains("/") == true
        if isFolder {
            return base.appendingPathComponent(snapshot.name, isDirectory: true)
                .appendingPathComponent("torrent-manifest.json")
        }
        return base.appendingPathComponent(snapshot.name + ".torrent-manifest.json")
    }

    public static func write(snapshot: TorrentSnapshot, record: TorrentRecord, engineVersion: String) throws -> URL {
        let base = URL(fileURLWithPath: snapshot.downloadDirectory, isDirectory: true)
        let root = base.standardizedFileURL.path + "/"
        let files = try snapshot.files.filter(\.wanted).sorted { $0.name < $1.name }.map { file in
            let url = base.appendingPathComponent(file.name).standardizedFileURL
            guard url.path.hasPrefix(root) else { throw TorrentError.invalidTorrentFile }
            return Manifest.File(relativePath: file.name, byteSize: file.length, sha256: try ManifestWriter.sha256(url))
        }
        let manifest = Manifest(
            schemaVersion: schemaVersion, kind: "torrent", infoHash: snapshot.hash, name: snapshot.name,
            magnetLink: record.magnetLink, addedAt: record.addedAt, completedAt: Date(),
            engine: "transmission \(engineVersion)", mediaFetch: MediaFetchRelease.version, files: files
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let url = manifestURL(for: snapshot)
        try encoder.encode(manifest).write(to: url, options: .atomic)
        return url
    }
}
#endif
