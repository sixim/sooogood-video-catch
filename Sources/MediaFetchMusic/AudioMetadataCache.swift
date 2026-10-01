import Foundation

/// Remembers probe results per file, keyed by canonical path + size +
/// modification time. Unchanged files skip ffprobe / AVFoundation entirely, so
/// rescanning a large library is near-instant. Any change to a file misses.
public final class AudioMetadataCache: @unchecked Sendable {
    struct Entry: Codable {
        let size: Int64
        let modified: TimeInterval
        let candidate: LocalAudioCandidate
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MediaFetch/audio-metadata-cache.json")
    }

    private let url: URL?
    private let lock = NSLock()
    private var entries: [String: Entry]
    private var dirty = false
    public private(set) var hits = 0
    public private(set) var misses = 0

    /// `url: nil` keeps the cache in memory only (tests, previews).
    public init(url: URL? = AudioMetadataCache.defaultURL) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    static func signature(of file: URL) -> (key: String, size: Int64, modified: TimeInterval)? {
        // URL instances cache resource values; a reused URL would report stale size/mtime.
        var fresh = file
        fresh.removeAllCachedResourceValues()
        guard let values = try? fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        return (file.resolvingSymlinksInPath().standardizedFileURL.path, Int64(size), modified.timeIntervalSince1970)
    }

    public func cached(for file: URL) -> LocalAudioCandidate? {
        guard let signature = Self.signature(of: file) else { return nil }
        return lock.withLock {
            guard let entry = entries[signature.key], entry.size == signature.size, entry.modified == signature.modified else {
                misses += 1
                return nil
            }
            hits += 1
            return entry.candidate
        }
    }

    public func store(_ candidate: LocalAudioCandidate, for file: URL) {
        guard candidate.probeWarning == nil, let signature = Self.signature(of: file) else { return }
        lock.withLock {
            entries[signature.key] = Entry(size: signature.size, modified: signature.modified, candidate: candidate)
            dirty = true
        }
    }

    /// Drops entries for files that no longer exist and writes to disk.
    public func save() {
        guard let url else { return }
        let snapshot: [String: Entry]? = lock.withLock {
            guard dirty else { return nil }
            entries = entries.filter { FileManager.default.fileExists(atPath: $0.key) }
            dirty = false
            return entries
        }
        guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Probe through the cache.
    public func candidate(for file: URL, probe: () -> LocalAudioCandidate) -> LocalAudioCandidate {
        if let hit = cached(for: file) { return hit }
        let fresh = probe()
        store(fresh, for: file)
        return fresh
    }
}
