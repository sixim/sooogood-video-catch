import Foundation

/// What is already on disk, for "本地已有" checks before downloading.
/// Built from package manifests (platform + media id: exact) and audio tags
/// (title + artist + duration: likely). Matching is deliberately strict — a
/// live version or a remix must not count as "already have".
public struct LocalMusicIndex: Sendable {
    public struct Item: Equatable, Sendable {
        public let path: String
        public let platform: String?
        public let mediaID: String?
        public let title: String
        public let artists: [String]
        public let durationSeconds: Double?

        public init(path: String, platform: String?, mediaID: String?, title: String, artists: [String], durationSeconds: Double?) {
            self.path = path
            self.platform = platform
            self.mediaID = mediaID
            self.title = title
            self.artists = artists
            self.durationSeconds = durationSeconds
        }
    }

    public enum Match: Equatable, Sendable {
        case sameTrack(path: String)
        case likely(path: String)

        public var path: String {
            switch self { case .sameTrack(let p), .likely(let p): return p }
        }

        public var isExact: Bool { if case .sameTrack = self { return true }; return false }
    }

    public let items: [Item]
    private let byID: [String: Item]

    public init(items: [Item]) {
        self.items = items
        var map: [String: Item] = [:]
        for item in items {
            if let key = Self.idKey(platform: item.platform, mediaID: item.mediaID) { map[key] = item }
        }
        byID = map
    }

    static func idKey(platform: String?, mediaID: String?) -> String? {
        guard let mediaID, !mediaID.isEmpty else { return nil }
        let family = (platform ?? "").lowercased().split(separator: ":").first.map(String.init) ?? ""
        return "\(family)|\(mediaID)"
    }

    /// Lowercased, without whitespace, punctuation or full-width variants.
    public static func normalize(_ text: String) -> String {
        let folded = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        return String(folded.lowercased().unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
        }.map(Character.init))
    }

    public func match(platform: String?, mediaID: String?, title: String, artists: [String], durationSeconds: Double?) -> Match? {
        if let key = Self.idKey(platform: platform, mediaID: mediaID), let hit = byID[key] {
            return .sameTrack(path: hit.path)
        }
        let normalizedTitle = Self.normalize(title)
        guard !normalizedTitle.isEmpty else { return nil }
        let wantedArtists = Set(artists.map(Self.normalize).filter { !$0.isEmpty })
        for item in items where Self.normalize(item.title) == normalizedTitle {
            let haveArtists = Set(item.artists.flatMap { $0.components(separatedBy: CharacterSet(charactersIn: "/,&、")) }.map(Self.normalize).filter { !$0.isEmpty })
            guard !wantedArtists.isEmpty, !haveArtists.isDisjoint(with: wantedArtists) else { continue }
            if let a = durationSeconds, let b = item.durationSeconds, abs(a - b) > 3 { continue }
            return .likely(path: item.path)
        }
        return nil
    }

    /// Exact "already have" for one platform track: a package manifest with the
    /// same platform and id whose file is still on disk. No title guessing.
    public func existingPath(platform: StreamingPlatform, mediaID: String) -> String? {
        guard case .sameTrack(let path)? = match(platform: platform.extractorFamily, mediaID: mediaID,
                                                 title: "", artists: [], durationSeconds: nil),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    /// Package manifests under `root` (video/music packages written by this app).
    public static func manifestItems(under root: URL, maxDepth: Int = 5) -> [Item] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var items: [Item] = []
        for case let url as URL in enumerator {
            if enumerator.level > maxDepth { enumerator.skipDescendants(); continue }
            guard url.lastPathComponent == "manifest.json",
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let mediaID = json["mediaID"]?.stringValue else { continue }
            let audio = json["files"]?.arrayValue?.compactMap { $0["relativePath"]?.stringValue }
                .first { ["mp3", "flac", "m4a", "ogg", "opus", "ape", "wav"].contains(($0 as NSString).pathExtension.lowercased()) }
            items.append(Item(
                path: audio.map { url.deletingLastPathComponent().appendingPathComponent($0).path } ?? url.deletingLastPathComponent().path,
                platform: json["platform"]?.stringValue, mediaID: mediaID,
                title: json["title"]?.stringValue ?? "", artists: [], durationSeconds: json["audio"]?["durationSeconds"]?.doubleValue
            ))
        }
        return items
    }
}
