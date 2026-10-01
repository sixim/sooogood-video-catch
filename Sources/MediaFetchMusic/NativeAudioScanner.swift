import AVFoundation
import Foundation

/// A Store-safe metadata scanner backed by AVFoundation.
///
/// The Local profile keeps the ffprobe implementation for broad codec/tag
/// coverage. The Store profile uses this scanner so the app does not need to
/// embed or launch a third-party executable inside the sandbox.
public struct NativeAudioScanner: Sendable {
    public enum ScannerError: LocalizedError, Equatable {
        case sourceIsNotDirectory(String)
        case enumerationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .sourceIsNotDirectory(let path):
                return "音频来源不是可读取的资料夹：\(path)"
            case .enumerationFailed(let message):
                return "无法扫描音频资料夹：\(message)"
            }
        }
    }

    /// Optional probe cache; unchanged files skip AVFoundation loading.
    public var cache: AudioMetadataCache?

    public init(cache: AudioMetadataCache? = nil) {
        self.cache = cache
    }

    public func scan(
        directory: URL,
        progress: ((Int, URL) -> Void)? = nil
    ) async throws -> [LocalAudioCandidate] {
        let urls = try Self.enumerateAudioURLs(in: directory)
        var candidates: [LocalAudioCandidate] = []
        candidates.reserveCapacity(urls.count)
        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            progress?(index + 1, url)
            if let hit = cache?.cached(for: url) {
                candidates.append(hit)
            } else {
                let fresh = await probeOrFallback(url)
                cache?.store(fresh, for: url)
                candidates.append(fresh)
            }
        }
        cache?.save()
        return candidates
    }

    private static func enumerateAudioURLs(in directory: URL) throws -> [URL] {
        let manager = FileManager.default
        let canonicalRoot = directory.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard directory.isFileURL,
              manager.fileExists(atPath: canonicalRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ScannerError.sourceIsNotDirectory(directory.path)
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
        var urls: [URL] = []
        for case let discoveredURL as URL in enumerator {
            let values = try? discoveredURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isPackageKey,
                .isHiddenKey
            ])
            if values?.isHidden == true || values?.isPackage == true { continue }

            let canonicalURL = discoveredURL.resolvingSymlinksInPath().standardizedFileURL
            if values?.isSymbolicLink == true && !Self.isContained(canonicalURL, by: canonicalRoot) {
                continue
            }
            guard Self.isContained(canonicalURL, by: canonicalRoot) else { continue }

            var targetIsDirectory: ObjCBool = false
            let targetValues = try? canonicalURL.resourceValues(forKeys: [.isRegularFileKey])
            guard manager.fileExists(atPath: canonicalURL.path, isDirectory: &targetIsDirectory),
                  !targetIsDirectory.boolValue,
                  targetValues?.isRegularFile == true,
                  LocalAudioScanner.supportedExtensions.contains(canonicalURL.pathExtension.lowercased()) else {
                continue
            }
            guard seenCanonicalPaths.insert(canonicalURL.path).inserted else { continue }
            urls.append(canonicalURL)
        }

        if let enumerationError, urls.isEmpty {
            throw ScannerError.enumerationFailed(enumerationError.localizedDescription)
        }

        return urls.sorted(by: {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        })
    }

    private func probeOrFallback(_ url: URL) async -> LocalAudioCandidate {
        do {
            return try await probe(url)
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

    private func probe(_ url: URL) async throws -> LocalAudioCandidate {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let metadata = try await asset.load(.commonMetadata)

        let taggedTitle = nonEmpty(await commonValue(.commonKeyTitle, metadata: metadata))
        let title = taggedTitle ?? url.deletingPathExtension().lastPathComponent
        let artistText = nonEmpty(await commonValue(.commonKeyArtist, metadata: metadata))
        let album = nonEmpty(await commonValue(.commonKeyAlbumName, metadata: metadata))
        var isrc: String?
        if let isrcItem = metadata.first(where: { ($0.identifier?.rawValue.lowercased() ?? "").contains("isrc") }) {
            isrc = (try? await isrcItem.load(.stringValue))?.flatMap(nonEmpty(_:))?.uppercased()
        }
        let durationMS = duration.isNumeric && duration.seconds.isFinite
            ? Int((duration.seconds * 1_000).rounded())
            : nil
        let discNumber = await metadataInteger(metadata, containing: ["disc", "disk"])
        let trackNumber = await metadataInteger(metadata, containing: ["track", "tracknumber"])

        return LocalAudioCandidate(
            url: url,
            title: title,
            artists: parseArtists(artistText),
            album: album,
            durationMS: durationMS,
            isrc: isrc,
            discNumber: discNumber,
            trackNumber: trackNumber,
            codec: nil,
            byteSize: fileSize(url),
            titleWasFilenameFallback: taggedTitle == nil,
            probeWarning: nil
        )
    }

    private func commonValue(
        _ key: AVMetadataKey,
        metadata: [AVMetadataItem]
    ) async -> String? {
        guard let item = metadata.first(where: { $0.commonKey == key }) else { return nil }
        return try? await item.load(.stringValue)
    }

    private func metadataInteger(
        _ metadata: [AVMetadataItem],
        containing fragments: [String]
    ) async -> Int? {
        for item in metadata {
            let identifier = item.identifier?.rawValue.lowercased() ?? ""
            guard fragments.contains(where: identifier.contains) else { continue }
            if let number = try? await item.load(.numberValue) {
                let value = number.intValue
                return value
            }
            if let string = try? await item.load(.stringValue), let value = Int(string) {
                return value
            }
        }
        return nil
    }

    private func parseArtists(_ value: String?) -> [String] {
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

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
}
