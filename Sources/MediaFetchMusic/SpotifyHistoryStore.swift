import Foundation

public struct SpotifyBridgeHistoryRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let collectionID: String
    public let collectionKind: SpotifyResourceKind
    public let collectionTitle: String
    public let packagePath: String
    public let manifestPath: String
    public let savedCount: Int

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        collectionID: String,
        collectionKind: SpotifyResourceKind,
        collectionTitle: String,
        packagePath: String,
        manifestPath: String,
        savedCount: Int
    ) {
        self.id = id
        self.createdAt = createdAt
        self.collectionID = collectionID
        self.collectionKind = collectionKind
        self.collectionTitle = collectionTitle
        self.packagePath = packagePath
        self.manifestPath = manifestPath
        self.savedCount = savedCount
    }
}

public enum SpotifyHistoryStore {
    public static var historyURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MediaFetch", isDirectory: true)
            .appendingPathComponent("spotify-history.json")
    }

    public static func load() -> [SpotifyBridgeHistoryRecord] {
        guard let data = try? Data(contentsOf: historyURL),
              let records = try? decoded(data) else { return [] }
        return records
    }

    public static func save(_ records: [SpotifyBridgeHistoryRecord]) throws {
        let directory = historyURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoded(records).write(to: historyURL, options: .atomic)
    }

    public static func encoded(_ records: [SpotifyBridgeHistoryRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(records)
    }

    public static func decoded(_ data: Data) throws -> [SpotifyBridgeHistoryRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([SpotifyBridgeHistoryRecord].self, from: data)
    }
}
