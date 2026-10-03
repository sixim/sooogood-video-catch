import Foundation
import MediaFetchCore

#if !MEDIAFETCH_STORE_PROFILE
/// Turns a finished package folder (video package, torrent folder, tool output)
/// into a Resolve import request. Pure apart from reading the folder listing,
/// file headers and an optional manifest, so it is unit-testable offline.
public enum ResolveImportPlanner {
    public static let rootBin = "Sooogood"
    public static let musicBin = String(localized: "音乐")
    static let mediaSignatures: Set<MediaSignature> = [.isoBMFF, .matroska, .mpegTS, .mpegAudio, .flac, .ogg, .wave]
    static let subtitleExtensions: Set<String> = ["srt"]
    /// Audio containers/codecs DaVinci Resolve cannot read (verified on Resolve 21:
    /// `.ogg` Opus is rejected, Opus inside MKV imports as video-only).
    static let unsupportedExtensions: Set<String> = ["ogg", "opus", "mka", "oga"]
    static let unsupportedAudioCodecs: Set<String> = ["opus", "vorbis"]

    public struct Provenance: Equatable, Sendable {
        public var sourceURL: String?
        public var title: String?
        public var platform: String?
        public var mediaID: String?
        public var sha256ByFileName: [String: String]
        /// Audio codecs of the downloaded streams (from the manifest's selected formats).
        public var audioCodecs: [String] = []
        /// Music packages (schema 4 `music` block or measured `audio`).
        public var isMusic = false
        public var artist: String?
        public var album: String?
        public var measuredQuality: String?

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
            var provenance = Provenance(
                sourceURL: json["sourceURL"]?.stringValue ?? json["magnetLink"]?.stringValue,
                title: json["title"]?.stringValue ?? json["name"]?.stringValue,
                platform: json["platform"]?.stringValue ?? (json["kind"]?.stringValue == "torrent" ? "BitTorrent" : nil),
                mediaID: json["mediaID"]?.stringValue ?? json["infoHash"]?.stringValue,
                sha256ByFileName: hashes
            )
            if let music = json["music"], music != .null {
                provenance.isMusic = true
                provenance.artist = music["artist"]?.stringValue
                provenance.album = music["album"]?.stringValue
            }
            if let audio = json["audio"], audio != .null {
                provenance.isMusic = provenance.isMusic || json["musicQualityPreference"]?.stringValue != nil
                let codec = audio["codec"]?.stringValue?.uppercased() ?? ""
                let rate = audio["sampleRate"]?.doubleValue.map { String(format: "%.1f kHz", $0 / 1000) }
                let bits = audio["bitsPerSample"]?.intValue.map { "\($0)-bit" }
                let kbps = audio["bitrate"]?.doubleValue.map { "\(Int($0 / 1000)) kbps" }
                provenance.measuredQuality = [codec, rate, bits ?? kbps].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            }
            provenance.audioCodecs = (json["selectedFormats"]?.arrayValue ?? [])
                .compactMap { $0["audioCodec"]?.stringValue?.lowercased() }
                .filter { !$0.isEmpty && $0 != "none" }
            return provenance
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
        // Every proxy the toolbox made is excluded from import; only the preferred one is linked.
        let allProxies = DerivativeLog.outputs(role: .proxy, in: packageDirectory)
        func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let excluded = Set(allProxies.map(canonical))
        let provenance = provenance ?? manifestProvenance(in: packageDirectory)
        var request = plan(
            files: try regularFiles(in: packageDirectory).filter { !excluded.contains(canonical($0.path)) },
            binName: binName(for: packageDirectory),
            provenance: provenance,
            // Proxies made by the toolbox are linked automatically.
            proxies: DerivativeLog.proxies(in: packageDirectory).merging(proxies) { _, explicit in explicit },
            timelineName: timelineName
        )
        // Music goes to Sooogood › 音乐 › <album> so a soundtrack stays together.
        if provenance?.isMusic == true {
            let album = provenance?.album.map { CollectionPaths.safeComponent($0) }
            request.binPath = [rootBin, musicBin, album ?? binName(for: packageDirectory)]
        }
        return request
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
            if unsupportedExtensions.contains(file.pathExtension.lowercased()) { continue }
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

    /// Human-readable problems Resolve will have with this package, if any.
    public static func compatibilityWarnings(packageDirectory: URL) -> [String] {
        var warnings: [String] = []
        let provenance = manifestProvenance(in: packageDirectory)
        let codecs = Set((provenance?.audioCodecs ?? []).map { $0.split(separator: ".").first.map(String.init) ?? $0 })
        let hasEditAudio = DerivativeLog.load(in: packageDirectory).contains {
            ($0.preset == "wavForEdit" || $0.preset == "prores422" || $0.preset == "proresLT")
        }
        if !codecs.isDisjoint(with: unsupportedAudioCodecs) && !hasEditAudio {
            let names = codecs.intersection(unsupportedAudioCodecs).sorted().joined(separator: "/")
            warnings.append(String(localized: "音轨是 \(names)，达芬奇无法读取，片段会没有声音。可在工具箱用「WAV 24-bit / 48 kHz」或「达芬奇友好 · ProRes 422」生成可用版本后再发送。"))
        }
        return warnings
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
        if provenance.isMusic {
            var description = provenance.title ?? ""
            if let artist = provenance.artist { description = "\(artist) - \(description)" }
            if !description.isEmpty { result["Description"] = description }
        }
        let keywords = [provenance.platform, provenance.isMusic ? "Music" : nil, MediaFetchRelease.shortDisplayName].compactMap { $0 }
        if !keywords.isEmpty { result["Keywords"] = keywords.joined(separator: ",") }
        return result
    }

    static func thirdParty(for file: URL, packageName: String, provenance: Provenance?) -> [String: String] {
        var result = ["Sooogood Package": packageName]
        if let hash = provenance?.sha256ByFileName[file.lastPathComponent] { result["Sooogood SHA-256"] = hash }
        if let id = provenance?.mediaID { result["Sooogood Media ID"] = id }
        if let url = provenance?.sourceURL { result["Sooogood Source"] = url }
        if let artist = provenance?.artist { result["Sooogood Artist"] = artist }
        if let album = provenance?.album { result["Sooogood Album"] = album }
        if let quality = provenance?.measuredQuality, !quality.isEmpty { result["Sooogood Audio Quality"] = quality }
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
