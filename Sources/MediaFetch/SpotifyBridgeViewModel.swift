import Foundation
import SwiftUI
import UniformTypeIdentifiers
import MediaFetchCore
import MediaFetchMusic

enum SpotifyConnectionState: Equatable {
    case checking
    case disconnected
    case connecting
    case connected
    case demo

    var displayName: String {
        switch self {
        case .checking: return "正在检查连接"
        case .disconnected: return "Spotify 未连接"
        case .connecting: return "等待 Spotify 授权"
        case .connected: return "Spotify 已连接"
        case .demo: return "演示模式"
        }
    }

    var systemImage: String {
        switch self {
        case .checking: return "ellipsis.circle.fill"
        case .disconnected: return "link.badge.plus"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .connected: return "checkmark.circle.fill"
        case .demo: return "play.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .checking, .disconnected: return MediaFetchTheme.secondaryText
        case .connecting: return MediaFetchTheme.warning
        case .connected: return MediaFetchTheme.success
        case .demo: return MediaFetchTheme.musicPurple
        }
    }

    var isConnected: Bool { self == .connected || self == .demo }
    var isBusy: Bool { self == .checking || self == .connecting }
}

enum SpotifyMusicPhase: Equatable {
    case waitingForLink
    case loadingCollection
    case chooseSource
    case scanning
    case review
    case saving
    case completed

    var isBusy: Bool {
        switch self {
        case .loadingCollection, .scanning, .saving: return true
        default: return false
        }
    }
}

enum SpotifyBridgeFilter: String, CaseIterable, Identifiable {
    case all
    case ready
    case ambiguous
    case unmatched

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "全部"
        case .ready: return "已匹配"
        case .ambiguous: return "待确认"
        case .unmatched: return "未匹配"
        }
    }
}

@MainActor
final class SpotifyBridgeViewModel: ObservableObject {
    @Published var clientID: String {
        didSet {
            let normalized = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            if allowsPersistence {
                UserDefaults.standard.set(normalized, forKey: Self.clientIDDefaultsKey)
            }
            guard normalized != oldValue.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            authClient = nil
            apiClient = nil
            if connectionState == .connected {
                connectionState = .disconnected
                inlineError = "Client ID 已更改，请重新连接 Spotify。旧凭据仍可通过“断开并删除本地凭据”清除。"
            }
        }
    }

    @Published private(set) var connectionState: SpotifyConnectionState = .checking
    @Published private(set) var hasStoredCredentials = false
    @Published var spotifyURLText = ""
    @Published private(set) var collection: SpotifyCollection?
    @Published private(set) var items: [SpotifyBridgeItem] = []
    @Published private(set) var sourceFolder: URL? {
        didSet {
            if let oldValue, oldValue != sourceFolder {
                releaseSecurityScopedAccess(to: oldValue)
            }
            guard let sourceFolder else { return }
            retainSecurityScopedAccess(to: sourceFolder)
            if allowsPersistence { try? sourceBookmarkStore.save(sourceFolder) }
        }
    }
    @Published var destination: URL {
        didSet {
            if oldValue != destination {
                releaseSecurityScopedAccess(to: oldValue)
            }
            retainSecurityScopedAccess(to: destination)
            if allowsPersistence { try? destinationBookmarkStore.save(destination) }
        }
    }
    @Published var filter: SpotifyBridgeFilter = .all
    @Published private(set) var phase: SpotifyMusicPhase = .waitingForLink
    @Published var inlineError: String?
    @Published private(set) var scanProgressText = "等待扫描"
    @Published private(set) var saveProgressText = "正在保存…"
    @Published private(set) var completedPackageURL: URL?
    @Published private(set) var history: [SpotifyBridgeHistoryRecord] = []

    private static let clientIDDefaultsKey = "MediaFetch.spotify.clientID"
    private let matcher = SpotifyMatcher()
    private let bridgeService = SpotifyBridgeService()
    private let audioToolchain = AudioToolchain.applicationDefault
    private let sourceBookmarkStore = SecurityScopedBookmarkStore(key: "MediaFetch.music.source")
    private let destinationBookmarkStore = SecurityScopedBookmarkStore(key: "MediaFetch.music.destination")
    private let allowsPersistence: Bool
    private var activeSecurityScopedURLs: Set<URL> = []
    private var localCandidates: [LocalAudioCandidate] = []
    private var authClient: SpotifyAuthClient?
    private var apiClient: SpotifyAPIClient?

    init(restoresConnection: Bool = true, allowsPersistence: Bool = true) {
        self.allowsPersistence = allowsPersistence
        clientID = restoresConnection
            ? UserDefaults.standard.string(forKey: Self.clientIDDefaultsKey) ?? ""
            : ""
        let defaultDestination: URL = {
            #if MEDIAFETCH_STORE_PROFILE
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            #else
            let musicDirectory = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
                ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            return musicDirectory.appendingPathComponent("Music Packages", isDirectory: true)
            #endif
        }()
        destination = allowsPersistence
            ? destinationBookmarkStore.resolve() ?? defaultDestination
            : defaultDestination
        sourceFolder = allowsPersistence ? sourceBookmarkStore.resolve() : nil
        history = restoresConnection ? SpotifyHistoryStore.load() : []

        if let sourceFolder { retainSecurityScopedAccess(to: sourceFolder) }
        retainSecurityScopedAccess(to: destination)

        if restoresConnection {
            Task { [weak self] in
                await self?.restoreConnectionState()
            }
        } else {
            connectionState = .disconnected
        }
    }

    deinit {
        activeSecurityScopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    var callbackDisplayURL: String {
        "http://127.0.0.1/oauth/spotify/callback"
    }

    var homeSummary: String {
        switch connectionState {
        case .checking: return "正在检查 Spotify 连接"
        case .disconnected: return "连接 Spotify 后开始匹配"
        case .connecting: return "正在等待账号授权"
        case .connected:
            let pendingCount = ambiguousCount + unmatchedCount
            if pendingCount > 0 { return "\(pendingCount) 首音乐等待匹配" }
            if readyCount > 0 { return "\(readyCount) 首音乐可以保存" }
            return "Spotify 已连接 · 等待链接"
        case .demo:
            return "演示模式 · 可载入本地音频"
        }
    }

    var readyCount: Int {
        items.filter { $0.status == .ready }.count
    }

    var ambiguousCount: Int {
        items.filter { $0.status == .ambiguous }.count
    }

    var unmatchedCount: Int {
        items.filter { $0.status == .unmatched || $0.status == .failed }.count
    }

    var canSave: Bool {
        collection != nil && readyCount > 0
    }

    /// Exposed to the shell so Store builds can report whether their signed
    /// metadata probe is actually present, without exposing the toolchain
    /// implementation to SwiftUI. Store uses AVFoundation; Local uses ffprobe.
    var audioToolReady: Bool {
#if MEDIAFETCH_STORE_PROFILE
        return audioToolchain.usesNativeProbe
#else
        audioToolchain.usesNativeProbe || audioToolchain.ffprobeURL != nil
#endif
    }

    var filteredItems: [SpotifyBridgeItem] {
        switch filter {
        case .all:
            return items
        case .ready:
            return items.filter { [.ready, .copying, .completed].contains($0.status) }
        case .ambiguous:
            return items.filter { $0.status == .ambiguous }
        case .unmatched:
            return items.filter { $0.status == .unmatched || $0.status == .failed }
        }
    }

    var supportedAudioContentTypes: [UTType] {
        LocalAudioScanner.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    func displayIndex(for item: SpotifyBridgeItem, fallback: Int) -> Int {
        items.firstIndex(where: { $0.id == item.id }).map { $0 + 1 } ?? fallback
    }

    func connect() async {
        let normalizedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedClientID.isEmpty else {
            inlineError = SpotifyAuthError.missingClientID.localizedDescription
            connectionState = .disconnected
            return
        }

        inlineError = nil
        connectionState = .connecting
        collection = nil
        items = []
        phase = .waitingForLink
        do {
            let clients = makeClients(clientID: normalizedClientID)
            authClient = clients.auth
            apiClient = clients.api
            _ = try await clients.auth.connect()
            hasStoredCredentials = true
            connectionState = .connected
        } catch {
            connectionState = .disconnected
            hasStoredCredentials = (try? SpotifyKeychainCredentialStore().load()) != nil
            inlineError = error.localizedDescription
        }
    }

    /// Loads deterministic synthetic metadata for App Review and UI capture.
    /// No Spotify request, credential, cover bytes, or audio bytes are used;
    /// the user can still choose a local folder to test matching afterward.
    func loadDemoCollection(demoDirectory: URL? = nil) {
        inlineError = nil
        completedPackageURL = nil
        collection = SpotifyDemoFixture.collection
        var demoItems = SpotifyDemoFixture.emptyItems
        let directory = demoDirectory ?? Self.defaultDemoAudioDirectory()
        if let demoURLs = try? SpotifyDemoAudioFactory.prepare(
            in: directory,
            tracks: SpotifyDemoFixture.tracks
        ) {
            for (index, url) in demoURLs.enumerated() where index < demoItems.count {
                demoItems[index].confirm(source: .localFile(url))
                demoItems[index].evidence = MatchEvidence(
                    score: 100,
                    matchedFields: [.artist, .title, .duration],
                    reasons: ["应用生成的无版权演示 WAV"],
                    userConfirmed: true
                )
            }
        }
        items = demoItems
        localCandidates = []
        sourceFolder = nil
        scanProgressText = "演示音频已准备，可直接保存或选择自己的资料夹"
        saveProgressText = "准备保存演示音频"
        filter = .all
        phase = .chooseSource
        connectionState = .demo
    }

    private static func defaultDemoAudioDirectory() -> URL {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return supportDirectory
            .appendingPathComponent("MediaFetch", isDirectory: true)
            .appendingPathComponent("Demo Audio", isDirectory: true)
    }

    func disconnect() async {
        inlineError = nil
        do {
            if let apiClient {
                try await apiClient.disconnect()
            } else {
                try SpotifyKeychainCredentialStore().delete()
            }
        } catch SpotifyAuthError.noStoredCredentials {
            // The intended end state is already disconnected.
        } catch {
            inlineError = error.localizedDescription
            return
        }

        connectionState = .disconnected
        hasStoredCredentials = false
        authClient = nil
        apiClient = nil
        collection = nil
        items = []
        localCandidates = []
        sourceFolder = nil
        completedPackageURL = nil
        phase = .waitingForLink
    }

    func loadCollection() async {
        inlineError = nil
        completedPackageURL = nil
        let trimmed = spotifyURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resourceURL = URL(string: trimmed) else {
            inlineError = SpotifyAPIError.invalidResourceURL.localizedDescription
            return
        }
        guard SpotifyResourceReference.parse(resourceURL) != nil else {
            if StreamingPlatform.detect(resourceURL) == .spotify {
                inlineError = "这是 Spotify 短链接。请先在浏览器中打开它，再粘贴展开后的 open.spotify.com 单曲、专辑或歌单链接。"
            } else {
                inlineError = SpotifyAPIError.invalidResourceURL.localizedDescription
            }
            return
        }

        phase = .loadingCollection
        do {
            let clients = try activeClients()
            let fetched = try await clients.api.fetch(resourceURL: resourceURL)
            collection = fetched
            items = localCandidates.isEmpty
                ? fetched.tracks.map { SpotifyBridgeItem(track: $0) }
                : matcher.match(tracks: fetched.tracks, candidates: localCandidates)
            filter = .all
            phase = sourceFolder == nil ? .chooseSource : .review
        } catch {
            phase = collection == nil ? .waitingForLink : .review
            inlineError = error.localizedDescription
            if error is SpotifyAuthError || isReauthorizationRequired(error) {
                connectionState = .disconnected
            }
        }
    }

    func scanSourceFolder(_ directory: URL) async {
        guard let collection else {
            inlineError = "请先载入 Spotify 曲目、专辑或歌单。"
            return
        }

        inlineError = nil
        completedPackageURL = nil
        sourceFolder = directory
        phase = .scanning
        scanProgressText = "正在读取 \(directory.lastPathComponent)…"

        do {
#if MEDIAFETCH_STORE_PROFILE
            let scanner = NativeAudioScanner()
            let candidates = try await Task.detached(priority: .userInitiated) {
                try await scanner.scan(directory: directory)
            }.value
#else
            let scanner = LocalAudioScanner(toolchain: audioToolchain)
            let candidates = try await Task.detached(priority: .userInitiated) {
                try scanner.scan(directory: directory)
            }.value
#endif
            localCandidates = candidates
            scanProgressText = "已检查 \(candidates.count) 个音频文件"
            items = matcher.match(tracks: collection.tracks, candidates: candidates)
            filter = .all
            phase = .review
        } catch {
            phase = .chooseSource
            inlineError = error.localizedDescription
            scanProgressText = "扫描未完成"
        }
    }

    func confirm(candidate: LocalAudioCandidate, for itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].confirm(candidate: candidate)
        completedPackageURL = nil
        phase = .review
    }

    func assignLocalFile(_ url: URL, to itemID: UUID) {
        guard LocalAudioScanner.supportedExtensions.contains(url.pathExtension.lowercased()) else {
            inlineError = "请选择 m4a、mp3、flac、wav、aiff、alac、ogg 或 opus 音频文件。"
            return
        }
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        retainSecurityScopedAccess(to: url)
        items[index].confirm(source: .localFile(url))
        inlineError = nil
        completedPackageURL = nil
        phase = .review
    }

    func assignAuthorizedDirectURL(_ url: URL, to itemID: UUID) {
        do {
            try SpotifyBridgeService.validateAuthorizedDirectURL(url)
            guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
            items[index].confirm(source: .authorizedDirectURL(url))
            inlineError = nil
            completedPackageURL = nil
            phase = .review
        } catch {
            inlineError = error.localizedDescription
        }
    }

    func saveReadyItems() async {
        guard let collection else {
            inlineError = "请先载入 Spotify 音乐信息。"
            return
        }
        guard readyCount > 0 else {
            inlineError = SpotifyBridgeService.BridgeError.noReadyItems.localizedDescription
            return
        }

        inlineError = nil
        phase = .saving
        saveProgressText = "正在准备素材包…"
        let packageDirectory = availablePackageDirectory(for: collection)

        do {
            let result = try await bridgeService.save(
                collection: collection,
                items: items,
                packageDirectory: packageDirectory,
                progress: { [weak self] updatedItem in
                    Task { @MainActor [weak self] in
                        guard let self,
                              let index = self.items.firstIndex(where: { $0.id == updatedItem.id }) else { return }
                        self.items[index] = updatedItem
                        let completed = self.items.filter { $0.status == .completed }.count
                        self.saveProgressText = "已保存 \(completed) 首"
                    }
                }
            )
            items = result.items
            completedPackageURL = result.packageDirectory
            saveProgressText = "已保存 \(result.completedCount) 首"
            let historyRecord = SpotifyBridgeHistoryRecord(
                collectionID: collection.id,
                collectionKind: collection.kind,
                collectionTitle: collection.title,
                packagePath: result.packageDirectory.path,
                manifestPath: result.manifestURL.path,
                savedCount: result.completedCount
            )
            history.removeAll { $0.packagePath == historyRecord.packagePath }
            history.append(historyRecord)
            if allowsPersistence {
                do {
                    try SpotifyHistoryStore.save(history)
                } catch {
                    inlineError = "素材包已保存，但 Spotify 音乐历史写入失败：\(error.localizedDescription)"
                }
            }
            let failureCount = result.items.filter { $0.status == .failed }.count
            if failureCount > 0 {
                let failureMessage = "素材包已生成，其中 \(failureCount) 首保存失败。请查看曲目状态后重试。"
                inlineError = [inlineError, failureMessage].compactMap { $0 }.joined(separator: "\n")
            }
            phase = .completed
        } catch {
            phase = .review
            inlineError = error.localizedDescription
            saveProgressText = "保存未完成"
        }
    }

    private func restoreConnectionState() async {
        hasStoredCredentials = (try? SpotifyKeychainCredentialStore().load()) != nil
        let normalizedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedClientID.isEmpty else {
            connectionState = .disconnected
            return
        }
        let clients = makeClients(clientID: normalizedClientID)
        authClient = clients.auth
        apiClient = clients.api
        connectionState = hasStoredCredentials ? .connected : .disconnected
    }

    private func makeClients(clientID: String) -> (auth: SpotifyAuthClient, api: SpotifyAPIClient) {
        let auth = SpotifyAuthClient(configuration: SpotifyOAuthConfiguration(clientID: clientID))
        let api = SpotifyAPIClient(auth: auth)
        return (auth, api)
    }

    private func activeClients() throws -> (auth: SpotifyAuthClient, api: SpotifyAPIClient) {
        if let authClient, let apiClient { return (authClient, apiClient) }
        let normalizedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedClientID.isEmpty else { throw SpotifyAuthError.missingClientID }
        let clients = makeClients(clientID: normalizedClientID)
        authClient = clients.auth
        apiClient = clients.api
        return clients
    }

    private func availablePackageDirectory(for collection: SpotifyCollection) -> URL {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleanedTitle = collection.title
            .components(separatedBy: invalidCharacters)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let safeTitle = String((cleanedTitle.isEmpty ? "Spotify Music" : cleanedTitle).prefix(120))
        let baseName = "\(safeTitle) [\(collection.id)]"
        var candidate = destination.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = destination.appendingPathComponent("\(baseName) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private func isReauthorizationRequired(_ error: Error) -> Bool {
        guard let apiError = error as? SpotifyAPIError else { return false }
        if case .reauthorizationRequired = apiError { return true }
        return false
    }

    private func retainSecurityScopedAccess(to url: URL) {
        guard url.isFileURL, !activeSecurityScopedURLs.contains(url) else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        activeSecurityScopedURLs.insert(url)
    }

    private func releaseSecurityScopedAccess(to url: URL) {
        guard activeSecurityScopedURLs.remove(url) != nil else { return }
        url.stopAccessingSecurityScopedResource()
    }
}

#if DEBUG
enum SpotifyBridgePreviewScenario {
    case disconnected
    case loaded
    case review
    case saving
    case completed
}

extension SpotifyBridgeViewModel {
    static func preview(_ scenario: SpotifyBridgePreviewScenario) -> SpotifyBridgeViewModel {
        let model = SpotifyBridgeViewModel(restoresConnection: false, allowsPersistence: false)
        model.destination = URL(
            fileURLWithPath: "/Users/preview/Music/Music Packages",
            isDirectory: true
        )
        guard scenario != .disconnected else { return model }

        let tracks = previewTracks
        let collection = SpotifyCollection(
            id: "37i9dQZF1DX-preview",
            kind: .playlist,
            uri: "spotify:playlist:37i9dQZF1DX-preview",
            externalURL: URL(string: "https://open.spotify.com/playlist/37i9dQZF1DX-preview"),
            title: "夜行剪辑室 · Night Drive Selects",
            subtitle: "Simon 的个人歌单 · 多语言与长标题布局预览",
            tracks: tracks
        )

        model.connectionState = .connected
        model.hasStoredCredentials = true
        model.spotifyURLText = collection.externalURL?.absoluteString ?? ""
        model.collection = collection
        model.items = tracks.map { SpotifyBridgeItem(track: $0) }
        model.phase = .chooseSource

        guard scenario != .loaded else { return model }

        let sourceFolder = URL(fileURLWithPath: "/Users/preview/Music/Owned Masters", isDirectory: true)
        let northernLights = LocalAudioCandidate(
            url: sourceFolder.appendingPathComponent("01 Northern Lights.flac"),
            title: tracks[0].title,
            artists: tracks[0].artists,
            album: tracks[0].album,
            durationMS: tracks[0].durationMS,
            isrc: tracks[0].isrc,
            discNumber: 1,
            trackNumber: 1,
            codec: "flac",
            byteSize: 41_238_416
        )
        let liveCandidate = LocalAudioCandidate(
            url: sourceFolder.appendingPathComponent("02 城市边缘 (Live).m4a"),
            title: "城市边缘 (Live)",
            artists: tracks[1].artists,
            album: tracks[1].album,
            durationMS: tracks[1].durationMS + 1_100,
            codec: "alac",
            byteSize: 35_991_204
        )
        let studioCandidate = LocalAudioCandidate(
            url: sourceFolder.appendingPathComponent("02 城市边缘.m4a"),
            title: tracks[1].title,
            artists: tracks[1].artists,
            album: tracks[1].album,
            durationMS: tracks[1].durationMS,
            codec: "alac",
            byteSize: 33_840_112
        )
        let northernEvidence = MatchEvidence(
            score: 100,
            matchedFields: [.isrc, .artist, .title, .album, .duration],
            reasons: ["ISRC 完全一致"]
        )
        let studioEvidence = MatchEvidence(
            score: 95,
            matchedFields: [.artist, .title, .album, .duration],
            reasons: ["歌手、标题、专辑和时长一致"]
        )
        let liveEvidence = MatchEvidence(
            score: 82,
            matchedFields: [.artist, .album, .duration],
            reasons: ["检测到 Live 版本差异"],
            versionConflict: true
        )

        model.sourceFolder = sourceFolder
        model.scanProgressText = "已检查 126 个音频文件"
        model.items = [
            SpotifyBridgeItem(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
                track: tracks[0],
                matches: [SpotifyCandidateMatch(candidate: northernLights, evidence: northernEvidence)],
                source: .localFile(northernLights.url),
                evidence: northernEvidence,
                status: .ready
            ),
            SpotifyBridgeItem(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
                track: tracks[1],
                matches: [
                    SpotifyCandidateMatch(candidate: studioCandidate, evidence: studioEvidence),
                    SpotifyCandidateMatch(candidate: liveCandidate, evidence: liveEvidence)
                ],
                status: .ambiguous
            ),
            SpotifyBridgeItem(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
                track: tracks[2],
                status: .unmatched
            ),
            SpotifyBridgeItem(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!,
                track: tracks[3],
                source: .authorizedDirectURL(URL(string: "https://media.example.test/owned/afterglow.opus")!),
                evidence: MatchEvidence(
                    score: 0,
                    matchedFields: [],
                    reasons: ["用户手动授权音频来源"],
                    userConfirmed: true
                ),
                status: .ready
            )
        ]
        model.phase = .review

        switch scenario {
        case .disconnected, .loaded, .review:
            break
        case .saving:
            model.items[0].status = .completed
            model.items[0].outputRelativePath = "audio/01-01 Aria North - Northern Lights.flac"
            model.items[3].status = .copying
            model.phase = .saving
            model.saveProgressText = "已保存 1 首"
        case .completed:
            model.items[0].status = .completed
            model.items[0].outputRelativePath = "audio/01-01 Aria North - Northern Lights.flac"
            model.items[3].status = .completed
            model.items[3].outputRelativePath = "audio/01-04 Glass Harbor - Afterglow.opus"
            model.phase = .completed
            model.saveProgressText = "已保存 2 首"
            model.completedPackageURL = URL(
                fileURLWithPath: "/Users/preview/Music/Music Packages/Night Drive Selects",
                isDirectory: true
            )
        }

        return model
    }

    private static var previewTracks: [SpotifyTrackReference] {
        [
            SpotifyTrackReference(
                id: "preview-track-01",
                uri: "spotify:track:preview-track-01",
                externalURL: URL(string: "https://open.spotify.com/track/preview-track-01"),
                title: "Northern Lights",
                artists: ["Aria North"],
                album: "Midnight Atlas",
                discNumber: 1,
                trackNumber: 1,
                durationMS: 228_000,
                isrc: "USPRV2600001"
            ),
            SpotifyTrackReference(
                id: "preview-track-02",
                uri: "spotify:track:preview-track-02",
                externalURL: URL(string: "https://open.spotify.com/track/preview-track-02"),
                title: "城市边缘",
                artists: ["林屿", "Mira Chen"],
                album: "夜航",
                discNumber: 1,
                trackNumber: 2,
                durationMS: 247_000,
                isrc: "CNPRV2600002"
            ),
            SpotifyTrackReference(
                id: "preview-track-03",
                uri: "spotify:track:preview-track-03",
                externalURL: URL(string: "https://open.spotify.com/track/preview-track-03"),
                title: "A Very Long Track Title for Multilingual Layout Verification — 未匹配版本",
                artists: ["The Reference Ensemble"],
                album: "Layout Stress Test",
                discNumber: 1,
                trackNumber: 3,
                durationMS: 314_000,
                isrc: nil
            ),
            SpotifyTrackReference(
                id: "preview-track-04",
                uri: "spotify:track:preview-track-04",
                externalURL: URL(string: "https://open.spotify.com/track/preview-track-04"),
                title: "Afterglow",
                artists: ["Glass Harbor"],
                album: "Night Drive Selects",
                discNumber: 1,
                trackNumber: 4,
                durationMS: 201_000,
                isrc: "GBPRV2600004"
            )
        ]
    }
}
#endif
