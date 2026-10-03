import Foundation
import MediaFetchCore

public struct SpotifyDirectDownload: Sendable {
    public let temporaryURL: URL
    public let finalURL: URL
    public let suggestedFilename: String?
    public let mimeType: String?
    public let shouldRemoveWhenDone: Bool

    public init(
        temporaryURL: URL,
        finalURL: URL,
        suggestedFilename: String? = nil,
        mimeType: String? = nil,
        shouldRemoveWhenDone: Bool = false
    ) {
        self.temporaryURL = temporaryURL
        self.finalURL = finalURL
        self.suggestedFilename = suggestedFilename
        self.mimeType = mimeType
        self.shouldRemoveWhenDone = shouldRemoveWhenDone
    }
}

public struct SpotifyBridgeService {
    public typealias DirectDownloader = (URL) async throws -> SpotifyDirectDownload

    public enum BridgeError: LocalizedError, Equatable {
        case noReadyItems
        case invalidLocalFile(String)
        case unsupportedAudioExtension(String)
        case directURLMustUseHTTPS
        case spotifyAudioSourceForbidden(String)
        case directDownloadFailed(Int)
        case redirectedToInsecureURL
        case redirectedToForbiddenSource(String)
        case checksumMismatch(String)

        public var errorDescription: String? {
            switch self {
            case .noReadyItems:
                return String(localized: "没有已确认的音频可以保存")
            case .invalidLocalFile(let path):
                return String(localized: "本地音频不存在或不是普通文件：\(path)")
            case .unsupportedAudioExtension(let value):
                return String(localized: "不支持此音频格式：\(value)")
            case .directURLMustUseHTTPS:
                return String(localized: "授权音频直链必须使用 HTTPS")
            case .spotifyAudioSourceForbidden(let host):
                return String(localized: "不能把 Spotify 或 Spotify CDN 当作音频来源：\(host)")
            case .directDownloadFailed(let status):
                return String(localized: "授权音频直链下载失败，HTTP 状态码：\(status)")
            case .redirectedToInsecureURL:
                return String(localized: "授权音频直链重定向到了非 HTTPS 地址")
            case .redirectedToForbiddenSource(let host):
                return String(localized: "授权音频直链重定向到了被禁止的 Spotify 来源：\(host)")
            case .checksumMismatch(let file):
                return String(localized: "复制校验失败，源文件和目标文件 SHA-256 不一致：\(file)")
            }
        }
    }

    private let directDownloader: DirectDownloader
    private let manager: FileManager

    public init(
        fileManager: FileManager = .default,
        directDownloader: @escaping DirectDownloader = SpotifyBridgeService.downloadAuthorizedDirectURL
    ) {
        manager = fileManager
        self.directDownloader = directDownloader
    }

    public func save(
        collection: SpotifyCollection,
        items originalItems: [SpotifyBridgeItem],
        packageDirectory: URL,
        progress: ((SpotifyBridgeItem) -> Void)? = nil
    ) async throws -> SpotifyBridgeSaveResult {
        var items = originalItems
        // Every invocation creates a new package. Previously completed items may point at
        // another package, so re-copy every confirmed source instead of carrying dangling
        // outputRelativePath values into the new M3U and manifest.
        for index in items.indices where items[index].status == .completed {
            items[index].outputRelativePath = nil
            items[index].sourceSHA256 = nil
            items[index].outputSHA256 = nil
            if items[index].source != nil {
                items[index].status = .ready
                items[index].failureReason = nil
            } else {
                items[index].status = .failed
                items[index].failureReason = String(localized: "旧素材包记录缺少可重新复制的音频来源")
            }
        }

        guard items.contains(where: { $0.status == .ready && $0.source != nil }) else {
            throw BridgeError.noReadyItems
        }

        let audioDirectory = packageDirectory.appendingPathComponent("audio", isDirectory: true)
        try manager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)

        var sourceFileNames: [UUID: String] = [:]
        var byteSizes: [UUID: Int64] = [:]

        for index in items.indices {
            guard items[index].status == .ready, let source = items[index].source else { continue }
            try Task.checkCancellation()
            items[index].status = .copying
            items[index].failureReason = nil
            progress?(items[index])

            do {
                let materialized = try await materialize(source: source)
                defer {
                    if materialized.shouldRemoveWhenDone {
                        try? manager.removeItem(at: materialized.url)
                    }
                }

                let outputURL = try availableOutputURL(
                    for: items[index].track,
                    sourceExtension: materialized.fileExtension,
                    audioDirectory: audioDirectory
                )
                let partialURL = audioDirectory.appendingPathComponent(".\(UUID().uuidString).partial")
                defer { try? manager.removeItem(at: partialURL) }

                let sourceHash = try ManifestWriter.sha256(materialized.url)
                try manager.copyItem(at: materialized.url, to: partialURL)
                let outputHash = try ManifestWriter.sha256(partialURL)
                guard sourceHash == outputHash else {
                    throw BridgeError.checksumMismatch(materialized.originalFileName)
                }
                try manager.moveItem(at: partialURL, to: outputURL)

                let size = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                items[index].status = .completed
                items[index].outputRelativePath = "audio/\(outputURL.lastPathComponent)"
                items[index].sourceSHA256 = sourceHash
                items[index].outputSHA256 = outputHash
                sourceFileNames[items[index].id] = materialized.originalFileName
                byteSizes[items[index].id] = Int64(size)
                progress?(items[index])
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                items[index].status = .failed
                items[index].failureReason = error.localizedDescription
                progress?(items[index])
            }
        }

        let playlistURL = packageDirectory.appendingPathComponent("playlist.m3u8")
        try playlistContents(items: items).write(to: playlistURL, atomically: true, encoding: .utf8)

        let manifest = makeManifest(
            collection: collection,
            items: items,
            sourceFileNames: sourceFileNames,
            byteSizes: byteSizes
        )
        let manifestURL = packageDirectory.appendingPathComponent("manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        return SpotifyBridgeSaveResult(
            packageDirectory: packageDirectory,
            playlistURL: playlistURL,
            manifestURL: manifestURL,
            items: items
        )
    }

    public static func validateAuthorizedDirectURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            throw BridgeError.directURLMustUseHTTPS
        }
        guard !isForbiddenSpotifyHost(host) else {
            throw BridgeError.spotifyAudioSourceForbidden(host)
        }
    }

    public static func validateRedirectDestination(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw BridgeError.redirectedToInsecureURL
        }
        guard let host = url.host?.lowercased(), !isForbiddenSpotifyHost(host) else {
            throw BridgeError.redirectedToForbiddenSource(url.host ?? "unknown")
        }
    }

    public static func isForbiddenSpotifyHost(_ host: String) -> Bool {
        let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let forbiddenRoots = ["spotify.com", "scdn.co", "spotifycdn.com", "spotifycdn.net"]
        return forbiddenRoots.contains { root in
            normalizedHost == root || normalizedHost.hasSuffix("." + root)
        }
    }

    private func materialize(source: AudioSource) async throws -> MaterializedAudio {
        switch source {
        case .localFile(let sourceURL):
            let resolvedURL = sourceURL.resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            let values = try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey])
            guard sourceURL.isFileURL,
                  manager.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  values?.isRegularFile == true else {
                throw BridgeError.invalidLocalFile(sourceURL.path)
            }
            let fileExtension = try validatedExtension(resolvedURL.pathExtension)
            return MaterializedAudio(
                url: resolvedURL,
                originalFileName: sourceURL.lastPathComponent,
                fileExtension: fileExtension,
                shouldRemoveWhenDone: false
            )

        case .authorizedDirectURL(let sourceURL):
            try Self.validateAuthorizedDirectURL(sourceURL)
            let download = try await directDownloader(sourceURL)
            var acceptedDownload = false
            defer {
                if !acceptedDownload && download.shouldRemoveWhenDone {
                    try? manager.removeItem(at: download.temporaryURL)
                }
            }
            try Self.validateRedirectDestination(download.finalURL)
            let fileExtension = try directAudioExtension(download: download, originalURL: sourceURL)
            let originalName = Self.safeSourceFileName(
                download.suggestedFilename ?? download.finalURL.lastPathComponent,
                fallbackExtension: fileExtension
            )
            acceptedDownload = true
            return MaterializedAudio(
                url: download.temporaryURL,
                originalFileName: originalName,
                fileExtension: fileExtension,
                shouldRemoveWhenDone: download.shouldRemoveWhenDone
            )
        }
    }

    private func validatedExtension(_ value: String) throws -> String {
        let normalized = value.lowercased()
        guard LocalAudioScanner.supportedExtensions.contains(normalized) else {
            throw BridgeError.unsupportedAudioExtension(value.isEmpty ? String(localized: "未知") : value)
        }
        return normalized
    }

    private func directAudioExtension(
        download: SpotifyDirectDownload,
        originalURL: URL
    ) throws -> String {
        let candidates = [
            download.suggestedFilename.map { URL(fileURLWithPath: $0).pathExtension },
            download.finalURL.pathExtension,
            originalURL.pathExtension
        ].compactMap { $0 }.filter { !$0.isEmpty }
        if let supported = candidates
            .map({ $0.lowercased() })
            .first(where: LocalAudioScanner.supportedExtensions.contains) {
            return supported
        }
        let mimeMap = [
            "audio/mpeg": "mp3",
            "audio/mp4": "m4a",
            "audio/x-m4a": "m4a",
            "audio/flac": "flac",
            "audio/x-flac": "flac",
            "audio/wav": "wav",
            "audio/x-wav": "wav",
            "audio/aiff": "aiff",
            "audio/alac": "alac",
            "audio/ogg": "ogg",
            "audio/opus": "opus"
        ]
        if let mimeType = download.mimeType?.lowercased(), let mapped = mimeMap[mimeType] {
            return mapped
        }
        throw BridgeError.unsupportedAudioExtension(candidates.first ?? download.mimeType ?? String(localized: "未知"))
    }

    private func availableOutputURL(
        for track: SpotifyTrackReference,
        sourceExtension: String,
        audioDirectory: URL
    ) throws -> URL {
        let disc = max(track.discNumber, 1)
        let number = max(track.trackNumber, 1)
        let artist = track.artists.isEmpty ? "Unknown Artist" : track.artists.joined(separator: ", ")
        let baseName = Self.sanitizedFilename(
            String(format: "%02d-%02d %@ - %@", disc, number, artist, track.title)
        )
        var candidate = audioDirectory.appendingPathComponent("\(baseName).\(sourceExtension)")
        if !manager.fileExists(atPath: candidate.path) { return candidate }

        let trackID = Self.sanitizedFilename(track.id)
        candidate = audioDirectory.appendingPathComponent("\(baseName) [\(trackID)].\(sourceExtension)")
        if !manager.fileExists(atPath: candidate.path) { return candidate }

        var suffix = 2
        while manager.fileExists(atPath: candidate.path) {
            candidate = audioDirectory.appendingPathComponent(
                "\(baseName) [\(trackID)] \(suffix).\(sourceExtension)"
            )
            suffix += 1
        }
        return candidate
    }

    private func playlistContents(items: [SpotifyBridgeItem]) -> String {
        var lines = ["#EXTM3U"]
        for item in items where item.status == .completed {
            guard let relativePath = item.outputRelativePath else { continue }
            let durationSeconds = max(0, Int((Double(item.track.durationMS) / 1_000).rounded()))
            let artist = item.track.artists.joined(separator: ", ")
            let displayName = Self.singleLine("\(artist) - \(item.track.title)")
            lines.append("#EXTINF:\(durationSeconds),\(displayName)")
            lines.append(Self.singleLine(relativePath))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func makeManifest(
        collection: SpotifyCollection,
        items: [SpotifyBridgeItem],
        sourceFileNames: [UUID: String],
        byteSizes: [UUID: Int64]
    ) -> SpotifyBridgeManifestV2 {
        SpotifyBridgeManifestV2(
            schemaVersion: MediaFetchRelease.musicManifestSchema,
            createdAt: Date(),
            collection: .init(
                id: collection.id,
                kind: collection.kind,
                uri: collection.uri,
                externalURL: collection.externalURL,
                title: collection.title
            ),
            items: items.map { item in
                .init(
                    itemID: item.id,
                    spotifyTrackID: item.track.id,
                    spotifyURI: item.track.uri,
                    spotifyURL: item.track.externalURL,
                    title: item.track.title,
                    artists: item.track.artists,
                    album: item.track.album,
                    sourceType: item.source?.typeDescription,
                    sourceFileName: sourceFileNames[item.id] ?? Self.sourceFileName(item.source),
                    outputRelativePath: item.outputRelativePath,
                    byteSize: byteSizes[item.id],
                    sourceSHA256: item.sourceSHA256,
                    outputSHA256: item.outputSHA256,
                    matchEvidence: item.evidence,
                    status: item.status,
                    failureReason: item.failureReason
                )
            }
        )
    }

    private static func sourceFileName(_ source: AudioSource?) -> String? {
        switch source {
        case .localFile(let url):
            return url.lastPathComponent
        case .authorizedDirectURL(let url):
            return safeSourceFileName(url.lastPathComponent, fallbackExtension: nil)
        case nil:
            return nil
        }
    }

    private static func safeSourceFileName(_ value: String, fallbackExtension: String?) -> String {
        let withoutQuery = value.components(separatedBy: "?").first ?? value
        let cleaned = sanitizedFilename(withoutQuery)
        if !cleaned.isEmpty { return cleaned }
        if let fallbackExtension { return "authorized-audio.\(fallbackExtension)" }
        return "authorized-audio"
    }

    private static func sanitizedFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        var components = value.components(separatedBy: invalid)
        components = components.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var result = components.filter { !$0.isEmpty }.joined(separator: "-")
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if result.count > 180 { result = String(result.prefix(180)) }
        return result.isEmpty ? "Untitled" : result
    }

    private static func singleLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    public static func downloadAuthorizedDirectURL(_ url: URL) async throws -> SpotifyDirectDownload {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 120
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let redirectDelegate = SpotifyAuthorizedRedirectDelegate()
        let session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(for: request)
        } catch {
            if let blockedError = redirectDelegate.blockedError { throw blockedError }
            throw error
        }
        if let blockedError = redirectDelegate.blockedError {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw blockedError
        }
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw BridgeError.directDownloadFailed(httpResponse.statusCode)
        }
        return SpotifyDirectDownload(
            temporaryURL: temporaryURL,
            finalURL: response.url ?? url,
            suggestedFilename: response.suggestedFilename,
            mimeType: response.mimeType,
            shouldRemoveWhenDone: true
        )
    }
}

private final class SpotifyAuthorizedRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var storedBlockedError: SpotifyBridgeService.BridgeError?

    var blockedError: SpotifyBridgeService.BridgeError? {
        lock.lock()
        defer { lock.unlock() }
        return storedBlockedError
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let destination = request.url else {
            store(.redirectedToInsecureURL)
            completionHandler(nil)
            return
        }
        do {
            try SpotifyBridgeService.validateRedirectDestination(destination)
            completionHandler(request)
        } catch let error as SpotifyBridgeService.BridgeError {
            store(error)
            completionHandler(nil)
        } catch {
            store(.redirectedToInsecureURL)
            completionHandler(nil)
        }
    }

    private func store(_ error: SpotifyBridgeService.BridgeError) {
        lock.lock()
        storedBlockedError = error
        lock.unlock()
    }
}

private struct MaterializedAudio {
    let url: URL
    let originalFileName: String
    let fileExtension: String
    let shouldRemoveWhenDone: Bool
}
