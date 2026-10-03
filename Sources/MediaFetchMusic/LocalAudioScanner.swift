import Foundation
import MediaFetchCore

#if !MEDIAFETCH_STORE_PROFILE
public struct LocalAudioScanner: Sendable {
    public enum ScannerError: LocalizedError, Equatable {
        case sourceIsNotDirectory(String)
        case ffprobeUnavailable(String)
        case enumerationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .sourceIsNotDirectory(let path):
                return String(localized: "音频来源不是可读取的资料夹：\(path)")
            case .ffprobeUnavailable(let path):
                return String(localized: "找不到可执行的 ffprobe：\(path)")
            case .enumerationFailed(let message):
                return String(localized: "无法扫描音频资料夹：\(message)")
            }
        }
    }

    public static let supportedExtensions: Set<String> = [
        "m4a", "mp3", "flac", "wav", "aiff", "alac", "ogg", "opus"
    ]

    public let ffprobePath: String
    public let processEnvironment: [String: String]
    /// Optional probe cache; unchanged files skip ffprobe.
    public var cache: AudioMetadataCache?

    public init(
        ffprobePath: String? = nil,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        if let ffprobePath {
            self.ffprobePath = ffprobePath
        } else {
            self.ffprobePath = Self.defaultFFprobePath()
        }
        self.processEnvironment = processEnvironment
    }

    /// Creates a scanner from the selected audio toolchain. This is the
    /// preferred entry point for the app so the Store build cannot silently
    /// fall back to a developer machine's Homebrew installation.
    public init(toolchain: AudioToolchain) {
        self.ffprobePath = toolchain.ffprobeURL?.path ?? "<ffprobe helper unavailable>"
        self.processEnvironment = toolchain.processEnvironment
    }

    public func scan(
        directory: URL,
        progress: ((Int, URL) -> Void)? = nil
    ) throws -> [LocalAudioCandidate] {
        let manager = FileManager.default
        let canonicalRoot = directory.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard directory.isFileURL,
              manager.fileExists(atPath: canonicalRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ScannerError.sourceIsNotDirectory(directory.path)
        }
        guard manager.isExecutableFile(atPath: ffprobePath) else {
            throw ScannerError.ffprobeUnavailable(ffprobePath)
        }

        var enumerationError: Error?
        guard let enumerator = manager.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isPackageKey,
                .isHiddenKey,
                .fileSizeKey
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return true
            }
        ) else {
            throw ScannerError.enumerationFailed(canonicalRoot.path)
        }

        var seenCanonicalPaths = Set<String>()
        var candidates: [LocalAudioCandidate] = []
        var scannedCount = 0

        for case let discoveredURL as URL in enumerator {
            let values = try? discoveredURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isPackageKey,
                .isHiddenKey
            ])
            if values?.isHidden == true || values?.isPackage == true { continue }

            let isSymbolicLink = values?.isSymbolicLink == true
            let canonicalURL = discoveredURL.resolvingSymlinksInPath().standardizedFileURL
            if isSymbolicLink && !Self.isContained(canonicalURL, by: canonicalRoot) { continue }
            guard Self.isContained(canonicalURL, by: canonicalRoot) else { continue }

            var targetIsDirectory: ObjCBool = false
            let targetValues = try? canonicalURL.resourceValues(forKeys: [.isRegularFileKey])
            guard manager.fileExists(atPath: canonicalURL.path, isDirectory: &targetIsDirectory),
                  !targetIsDirectory.boolValue,
                  targetValues?.isRegularFile == true,
                  Self.supportedExtensions.contains(canonicalURL.pathExtension.lowercased()) else {
                continue
            }
            guard seenCanonicalPaths.insert(canonicalURL.path).inserted else { continue }

            scannedCount += 1
            progress?(scannedCount, canonicalURL)
            if let cache {
                candidates.append(cache.candidate(for: canonicalURL) { probeOrFallback(canonicalURL) })
            } else {
                candidates.append(probeOrFallback(canonicalURL))
            }
        }

        if let enumerationError, candidates.isEmpty {
            throw ScannerError.enumerationFailed(enumerationError.localizedDescription)
        }
        cache?.save()
        return candidates.sorted {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }

    private func probeOrFallback(_ url: URL) -> LocalAudioCandidate {
        do {
            return try probe(url)
        } catch {
            return LocalAudioCandidate(
                url: url,
                title: url.deletingPathExtension().lastPathComponent,
                byteSize: fileSize(url),
                titleWasFilenameFallback: true,
                probeWarning: error.localizedDescription
            )
        }
    }

    private func probe(_ url: URL) throws -> LocalAudioCandidate {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.environment = processEnvironment
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=duration:format_tags:stream=codec_name",
            "-of", "json",
            url.path
        ]
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProbeError.failed(message?.isEmpty == false ? message! : String(localized: "ffprobe 退出码 \(process.terminationStatus)"))
        }

        guard let root = try JSONSerialization.jsonObject(with: outputData) as? [String: Any] else {
            throw ProbeError.invalidOutput
        }
        let format = root["format"] as? [String: Any] ?? [:]
        let rawTags = format["tags"] as? [String: Any] ?? [:]
        var tags: [String: String] = [:]
        for (key, value) in rawTags {
            if let string = value as? String {
                tags[key.lowercased()] = string.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let number = value as? NSNumber {
                tags[key.lowercased()] = number.stringValue
            }
        }

        let taggedTitle = Self.nonEmpty(tags["title"])
        let title = taggedTitle ?? url.deletingPathExtension().lastPathComponent
        let artistText = Self.nonEmpty(tags["artist"] ?? tags["album_artist"] ?? tags["albumartist"])
        let streams = root["streams"] as? [[String: Any]] ?? []
        let codec = streams.compactMap { $0["codec_name"] as? String }.first
        let durationSeconds = Self.doubleValue(format["duration"])
        let durationMS = durationSeconds.map { Int(($0 * 1_000).rounded()) }

        return LocalAudioCandidate(
            url: url,
            title: title,
            artists: Self.parseArtists(artistText),
            album: Self.nonEmpty(tags["album"]),
            durationMS: durationMS,
            isrc: Self.nonEmpty(tags["isrc"] ?? tags["tsrc"])?.uppercased(),
            isExplicit: Self.explicitFlag(tags),
            discNumber: Self.leadingInteger(tags["disc"] ?? tags["discnumber"]),
            trackNumber: Self.leadingInteger(tags["track"] ?? tags["tracknumber"]),
            codec: codec,
            byteSize: fileSize(url),
            titleWasFilenameFallback: taggedTitle == nil,
            probeWarning: nil
        )
    }

    private func fileSize(_ url: URL) -> Int64 {
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return Int64(size ?? 0)
    }

    private static func isContained(_ candidate: URL, by root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseArtists(_ value: String?) -> [String] {
        guard let value = nonEmpty(value) else { return [] }
        let separators = [";", " / ", " feat. ", " ft. "]
        var values = [value]
        for separator in separators {
            values = values.flatMap { $0.components(separatedBy: separator) }
        }
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func leadingInteger(_ value: String?) -> Int? {
        guard let value = nonEmpty(value) else { return nil }
        let prefix = value.prefix { $0.isNumber }
        return Int(prefix)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let string = value as? String { return Double(string) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    private static func explicitFlag(_ tags: [String: String]) -> Bool? {
        let value = nonEmpty(
            tags["itunesadvisory"] ?? tags["rtng"] ?? tags["explicit"] ?? tags["advisory"]
        )?.lowercased()
        switch value {
        case "1", "explicit", "yes", "true": return true
        case "0", "2", "clean", "no", "false": return false
        default: return nil
        }
    }

    private static func defaultFFprobePath() -> String {
        let manager = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe"
        ]
        return candidates.first(where: manager.isExecutableFile(atPath:)) ?? "/opt/homebrew/bin/ffprobe"
    }
}

private enum ProbeError: LocalizedError {
    case failed(String)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        case .invalidOutput: return String(localized: "ffprobe 没有返回有效 JSON")
        }
    }
}
#else
/// Store profile keeps only the shared file-type contract. The ffprobe-backed
/// scanner is intentionally not compiled into the App Store target; callers
/// use `NativeAudioScanner` instead.
public enum LocalAudioScanner {
    public static let supportedExtensions: Set<String> = [
        "m4a", "mp3", "flac", "wav", "aiff", "alac", "ogg", "opus"
    ]
}
#endif
