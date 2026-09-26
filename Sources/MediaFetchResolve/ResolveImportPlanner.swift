import Foundation
import MediaFetchCore

#if !MEDIAFETCH_STORE_PROFILE
/// Turns a finished package folder (video package, torrent folder, tool output)
/// into a Resolve import request. Pure apart from reading the folder listing,
/// file headers and an optional manifest, so it is unit-testable offline.
public enum ResolveImportPlanner {
    public static let rootBin = "Sooogood"
    static let mediaSignatures: Set<MediaSignature> = [.isoBMFF, .matroska, .mpegTS, .mpegAudio, .flac, .ogg, .wave]
    static let subtitleExtensions: Set<String> = ["srt"]

    public struct Provenance: Equatable, Sendable {
        public var sourceURL: String?
        public var title: String?
        public var platform: String?
        public var mediaID: String?
        public var sha256ByFileName: [String: String]

        public init(sourceURL: String? = nil, title: String? = nil, platform: String? = nil,
                    mediaID: String? = nil, sha256ByFileName: [String: String] = [:]) {
            self.sourceURL = sourceURL
            self.title = title
            self.platform = platform
            self.mediaID = mediaID
            self.sha256ByFileName = sha256ByFileName
        }

        /// Reads the fields both video `manifest.json` and `torrent-manifest.json` carry.
        public static func load(from manifestURL: URL) -> Provenance? {
            guard let data = try? Data(contentsOf: manifestURL),
                  let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
            var hashes: [String: String] = [:]
            for file in json["files"]?.arrayValue ?? [] {
                if let path = file["relativePath"]?.stringValue, let hash = file["sha256"]?.stringValue {
                    hashes[(path as NSString).lastPathComponent] = hash
                }
            }
            return Provenance(
                sourceURL: json["sourceURL"]?.stringValue ?? json["magnetLink"]?.stringValue,
                title: json["title"]?.stringValue ?? json["name"]?.stringValue,
                platform: json["platform"]?.stringValue ?? (json["kind"]?.stringValue == "torrent" ? "BitTorrent" : nil),
                mediaID: json["mediaID"]?.stringValue ?? json["infoHash"]?.stringValue,
                sha256ByFileName: hashes
            )
        }
    }

    /// - Parameters:
    ///   - proxies: original file path → proxy file path (from the tools module).
    public static func plan(
        packageDirectory: URL,
        provenance: Provenance? = nil,
        proxies: [String: String] = [:],
        timelineName: String? = nil
    ) throws -> ResolveImportRequest {
        plan(
            files: try regularFiles(in: packageDirectory),
            binName: binName(for: packageDirectory),
            provenance: provenance ?? manifestProvenance(in: packageDirectory),
            // Proxies made by the toolbox are linked automatically.
            proxies: DerivativeLog.proxies(in: packageDirectory).merging(proxies) { _, explicit in explicit },
            timelineName: timelineName
        )
    }

    /// Explicit file list, e.g. a single-file torrent that sits directly in
    /// the Downloads folder (importing the whole folder would be wrong).
    public static func plan(
        files: [URL],
        binName: String,
        provenance: Provenance?,
        proxies: [String: String] = [:],
        timelineName: String? = nil
    ) -> ResolveImportRequest {
        // Compare canonical paths: /var vs /private/var and similar aliases.
        func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let proxyByOriginal = Dictionary(proxies.map { (canonical($0.key), $0.value) }, uniquingKeysWith: { $1 })
        let proxyPaths = Set(proxies.values.map(canonical))
        var clips: [ResolveClipSpec] = []
        var subtitles: [String] = []
        for file in files where !proxyPaths.contains(canonical(file.path)) {
            if subtitleExtensions.contains(file.pathExtension.lowercased()) {
                subtitles.append(file.path)
                continue
            }
            guard mediaSignatures.contains(MediaSignature.detect(fileAt: file)) else { continue }
            clips.append(ResolveClipSpec(
                path: file.path,
                metadata: metadata(for: provenance),
                thirdParty: thirdParty(for: file, packageName: binName, provenance: provenance),
                proxy: proxyByOriginal[canonical(file.path)]
            ))
        }
        return ResolveImportRequest(binPath: [rootBin, binName], clips: clips, subtitles: subtitles, timelineName: timelineName)
    }

    /// Resolve bin names: keep them readable but free of path separators.
    public static func binName(for directory: URL) -> String {
        let name = directory.lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return String((name.isEmpty ? "Import" : name).prefix(120))
    }

    static func metadata(for provenance: Provenance?) -> [String: String] {
        guard let provenance else { return ["Comments": "Imported by \(MediaFetchRelease.displayName)"] }
        var result: [String: String] = [:]
        if let url = provenance.sourceURL { result["Comments"] = "Source: \(url)" }
        if let title = provenance.title { result["Description"] = title }
        let keywords = [provenance.platform, MediaFetchRelease.shortDisplayName].compactMap { $0 }
        if !keywords.isEmpty { result["Keywords"] = keywords.joined(separator: ",") }
        return result
    }

    static func thirdParty(for file: URL, packageName: String, provenance: Provenance?) -> [String: String] {
        var result = ["Sooogood Package": packageName]
        if let hash = provenance?.sha256ByFileName[file.lastPathComponent] { result["Sooogood SHA-256"] = hash }
        if let id = provenance?.mediaID { result["Sooogood Media ID"] = id }
        if let url = provenance?.sourceURL { result["Sooogood Source"] = url }
        return result
    }

    static func manifestProvenance(in directory: URL) -> Provenance? {
        for name in ["manifest.json", "torrent-manifest.json"] {
            if let provenance = Provenance.load(from: directory.appendingPathComponent(name)) { return provenance }
        }
        return nil
    }

    /// Files directly inside the package plus one level of subfolders
    /// (torrent folders often nest media one level down).
    static func regularFiles(in directory: URL) throws -> [URL] {
        let manager = FileManager.default
        var result: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        for url in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isRegularFile == true {
                result.append(url)
            } else if values.isDirectory == true {
                let nested = try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
                result += nested.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
#endif
