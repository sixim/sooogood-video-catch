import Foundation

/// Where a job sits inside a course or playlist. Optional on `DownloadJob`, so
/// older history decodes unchanged.
public struct CollectionContext: Codable, Equatable, Sendable {
    public let collectionID: String
    public let collectionTitle: String
    public let extractor: String
    /// Folder (relative to the destination) that holds the whole collection.
    public let rootFolderName: String
    public let index: Int
    public let chapterNumber: Int?
    public let chapterTitle: String?

    public init(collectionID: String, collectionTitle: String, extractor: String, rootFolderName: String,
                index: Int, chapterNumber: Int?, chapterTitle: String?) {
        self.collectionID = collectionID
        self.collectionTitle = collectionTitle
        self.extractor = extractor
        self.rootFolderName = rootFolderName
        self.index = index
        self.chapterNumber = chapterNumber
        self.chapterTitle = chapterTitle
    }

    /// `NN 章节名/` when the collection has chapters, else empty.
    public var chapterFolder: String? {
        guard let chapterTitle else { return nil }
        let number = chapterNumber.map { String(format: "%02d ", $0) } ?? ""
        return CollectionPaths.safeComponent(number + chapterTitle)
    }
}

public struct CollectionEntry: Equatable, Sendable, Identifiable {
    public let index: Int
    public let mediaID: String
    public let title: String
    public let url: String
    public let duration: Double?
    public let chapterNumber: Int?
    public let chapterTitle: String?

    public var id: String { "\(index)|\(mediaID)" }
}

/// A course or playlist expanded with `yt-dlp --flat-playlist --dump-single-json`.
public struct CollectionOutline: Equatable, Sendable {
    public let id: String
    public let title: String
    public let extractor: String
    public let entries: [CollectionEntry]
    /// Entries the extractor could not list for this account (e.g. paid lessons).
    public var unavailableCount = 0

    public var isCourse: Bool {
        let key = extractor.lowercased()
        return key.contains("udemy") || key.contains("cheese") || entries.contains { $0.chapterTitle != nil }
    }

    /// Entries grouped by chapter in course order; one unnamed group otherwise.
    public var chapters: [(title: String?, entries: [CollectionEntry])] {
        var groups: [(title: String?, entries: [CollectionEntry])] = []
        for entry in entries {
            if let last = groups.last, last.title == entry.chapterTitle {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append((entry.chapterTitle, [entry]))
            }
        }
        return groups
    }

    public var rootFolderName: String { CollectionPaths.safeComponent(title.isEmpty ? id : title) }

    public func context(for entry: CollectionEntry) -> CollectionContext {
        CollectionContext(collectionID: id, collectionTitle: title, extractor: extractor, rootFolderName: rootFolderName,
                          index: entry.index, chapterNumber: entry.chapterNumber, chapterTitle: entry.chapterTitle)
    }

    public static func parse(_ json: JSONValue) -> CollectionOutline? {
        guard json["_type"]?.stringValue == "playlist" || json["entries"] != nil,
              let raw = json["entries"]?.arrayValue else { return nil }
        let extractor = json["extractor_key"]?.stringValue ?? json["extractor"]?.stringValue ?? "generic"
        var entries: [CollectionEntry] = []
        for (offset, item) in raw.enumerated() {
            guard let id = item["id"]?.stringValue else { continue }
            let key = (item["ie_key"]?.stringValue ?? item["extractor_key"]?.stringValue ?? extractor).lowercased()
            // Flat "url" entries point at a page; fully extracted entries carry a
            // short-lived CDN "url", so their page URL must win.
            let isReference = ["url", "url_transparent"].contains(item["_type"]?.stringValue ?? "")
            let pageURL = item["webpage_url"]?.stringValue
            let listedURL = item["url"]?.stringValue.flatMap { $0.hasPrefix("http") ? $0 : nil }
            let url = (isReference ? listedURL ?? pageURL : pageURL ?? listedURL)
                ?? (key.contains("cheese") ? "https://www.bilibili.com/cheese/play/ep\(id)" : nil)
                ?? (key.contains("youtube") ? "https://www.youtube.com/watch?v=\(id)" : nil)
            guard let url else { continue }
            entries.append(CollectionEntry(
                index: item["playlist_index"]?.intValue ?? item["episode_number"]?.intValue ?? offset + 1,
                mediaID: id,
                title: item["title"]?.stringValue ?? id,
                url: url,
                duration: item["duration"]?.doubleValue,
                chapterNumber: item["chapter_number"]?.intValue,
                chapterTitle: item["chapter"]?.stringValue
            ))
        }
        guard !entries.isEmpty else { return nil }
        var outline = CollectionOutline(id: json["id"]?.stringValue ?? "collection", title: json["title"]?.stringValue ?? "",
                                        extractor: extractor, entries: entries)
        outline.unavailableCount = raw.count - entries.count
        return outline
    }
}

public enum CollectionDetector {
    /// URLs that point at a list rather than one video. Cheap and offline; the
    /// expander confirms with yt-dlp.
    public static func looksLikeCollection(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if host.hasSuffix("youtube.com") {
            return path.hasPrefix("/playlist") || (query.contains { $0.name == "list" } && !path.hasPrefix("/watch"))
        }
        if host.hasSuffix("udemy.com") {
            return path.hasPrefix("/course/") && !path.contains("/lecture/")
        }
        if host.hasSuffix("bilibili.com") {
            return path.hasPrefix("/cheese/play/ss") || path.contains("/lists/") || path.contains("/favlist")
                || path.contains("/channel/collectiondetail") || path.contains("/channel/seriesdetail")
        }
        return false
    }

    /// A YouTube watch URL that also carries `list=`: offer the list as an option.
    public static func hasPlaylistContext(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return host.hasSuffix("youtube.com") && url.path.lowercased().hasPrefix("/watch") && query.contains { $0.name == "list" }
    }
}

public enum CollectionPaths {
    /// One safe path component: no separators, no leading dots, bounded length.
    public static func safeComponent(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(of: "/", with: "／").replacingOccurrences(of: ":", with: "：")
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.isEmpty { cleaned = "Untitled" }
        return String(cleaned.prefix(120))
    }

    /// yt-dlp output template for one entry. `%` in titles is escaped so the
    /// template engine cannot interpret it.
    public static func outputTemplate(for context: CollectionContext, separateStreams: Bool) -> String {
        func escape(_ s: String) -> String { s.replacingOccurrences(of: "%", with: "%%") }
        var folders = [escape(context.rootFolderName)]
        if let chapter = context.chapterFolder { folders.append(escape(chapter)) }
        let package = String(format: "%03d", context.index) + " - %(title).150B [%(id)s]"
        folders.append(package)
        let file = separateStreams ? "\(package).f%(format_id)s.%(ext)s" : "\(package).%(ext)s"
        return (folders + [file]).joined(separator: "/")
    }
}

/// `collection-manifest.json` at the collection root: every selected entry
/// with its outcome and a pointer to its own package manifest.
public enum CollectionManifestWriter {
    public static let fileName = "collection-manifest.json"
    /// Courses (Udemy, Bilibili 课堂, anything with chapters) use this name.
    public static let courseFileName = "course-manifest.json"
    public static let schemaVersion = 1

    public static func fileName(for context: CollectionContext) -> String {
        let key = context.extractor.lowercased()
        return key.contains("udemy") || key.contains("cheese") || context.chapterTitle != nil ? courseFileName : fileName
    }

    public enum EntryStatus: String, Codable, Sendable {
        case completed
        case drmSkipped = "drm_skipped"
        case failed
    }

    struct Entry: Codable, Equatable {
        let index: Int
        let chapterNumber: Int?
        let chapter: String?
        let title: String?
        let sourceURL: String
        var status: EntryStatus
        var packageManifest: String?
        var note: String?
        var updatedAt: Date
    }

    struct Document: Codable {
        let schemaVersion: Int
        let kind: String
        let collectionID: String
        let title: String
        let extractor: String
        var entries: [Entry]
    }

    /// Upserts one entry by index; safe to call as each job finishes.
    public static func record(
        destination: URL, context: CollectionContext, sourceURL: String, title: String?,
        status: EntryStatus, packageManifest: URL?, note: String? = nil
    ) throws {
        let root = destination.appendingPathComponent(context.rootFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(fileName(for: context))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var document = (try? decoder.decode(Document.self, from: Data(contentsOf: url)))
            ?? Document(schemaVersion: schemaVersion, kind: fileName(for: context) == courseFileName ? "course" : "collection",
                        collectionID: context.collectionID,
                        title: context.collectionTitle, extractor: context.extractor, entries: [])
        let relative = packageManifest.map { manifest -> String in
            let rootPath = root.standardizedFileURL.path + "/"
            let path = manifest.standardizedFileURL.path
            return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
        }
        let entry = Entry(index: context.index, chapterNumber: context.chapterNumber, chapter: context.chapterTitle,
                          title: title, sourceURL: sourceURL, status: status, packageManifest: relative, note: note,
                          updatedAt: Date())
        document.entries.removeAll { $0.index == context.index }
        document.entries.append(entry)
        document.entries.sort { $0.index < $1.index }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: url, options: .atomic)
    }
}
