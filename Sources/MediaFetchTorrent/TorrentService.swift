import Combine
import Foundation
import MediaFetchCore

// BitTorrent is Local-profile only; nothing here ships in the Store binary.
#if !MEDIAFETCH_STORE_PROFILE
/// UI-facing façade for BitTorrent downloads. Starts the private engine on
/// first use, polls it, applies seeding policy, and writes manifests when a
/// torrent completes. Never deletes downloaded data.
@MainActor
public final class TorrentService: ObservableObject {
    public enum EngineStatus: Equatable {
        case idle
        case starting
        case running(version: String)
        case unavailable(String)
    }

    @Published public private(set) var engineStatus: EngineStatus = .idle
    @Published public private(set) var torrents: [TorrentSnapshot] = []
    @Published public private(set) var records: [TorrentRecord]
    @Published public var errorMessage: String?

    public var defaultDownloadDirectory: URL
    public var defaultSeedPolicy: SeedPolicy = .default
    /// When true, magnets are added paused and wait for the user to pick files.
    public var selectFilesBeforeDownload = true

    private let daemonFactory: () -> TransmissionDaemon?
    private let historyURL: URL
    private var daemon: TransmissionDaemon?
    private var client: TransmissionRPCClient?
    private var pollTask: Task<Void, Never>?
    private var startTask: Task<TransmissionRPCClient, Error>?
    private var manifestsInFlight: Set<String> = []
    private var engineVersion = "unknown"
    /// Faster polling while a torrent list is on screen.
    public var isObserved = false

    public init(
        defaultDownloadDirectory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0],
        historyURL: URL = TorrentHistoryStore.historyURL,
        daemonFactory: (() -> TransmissionDaemon?)? = nil
    ) {
        self.defaultDownloadDirectory = defaultDownloadDirectory
        self.historyURL = historyURL
        records = TorrentHistoryStore.load(from: historyURL)
        self.daemonFactory = daemonFactory ?? {
            guard let executable = TransmissionDaemon.findExecutable() else { return nil }
            return TransmissionDaemon(configuration: .init(
                executable: executable,
                configDirectory: TransmissionDaemon.defaultConfigDirectory,
                downloadDirectory: defaultDownloadDirectory,
                keepRunningAfterAppQuits: UserDefaults.standard.bool(forKey: TorrentService.keepSeedingKey),
                credentials: KeychainTorrentCredentialStore()
            ))
        }
    }

    public nonisolated static let keepSeedingKey = "MediaFetch.torrent.keepSeedingAfterQuit"

    public var engineInstalled: Bool { TransmissionDaemon.findExecutable() != nil }

    public func record(for hash: String) -> TorrentRecord? { records.first { $0.hash == hash } }

    // MARK: Engine lifecycle

    /// Idempotent; concurrent callers share one start.
    @discardableResult
    public func ensureEngine() async throws -> TransmissionRPCClient {
        if let client { return client }
        if let startTask { return try await startTask.value }
        guard let daemon = daemonFactory() else {
            engineStatus = .unavailable(TorrentError.engineMissing.localizedDescription)
            throw TorrentError.engineMissing
        }
        self.daemon = daemon
        engineStatus = .starting
        let task = Task { try await daemon.start() }
        startTask = task
        do {
            let client = try await task.value
            self.client = client
            startTask = nil
            engineVersion = (try? await client.version()) ?? "unknown"
            engineStatus = .running(version: engineVersion)
            await applySessionSettings()
            startPolling()
            return client
        } catch {
            startTask = nil
            self.daemon = nil
            engineStatus = .unavailable(error.localizedDescription)
            throw error
        }
    }

    /// Stops the engine (on app quit). Torrents resume on next launch; with
    /// `keepSeeding` the daemon stays up and is adopted again next time.
    public func shutdown(keepSeeding: Bool = false) {
        pollTask?.cancel()
        pollTask = nil
        client = nil
        daemon?.stopForAppQuit(keepSeeding: keepSeeding)
        daemon = nil
        engineStatus = .idle
    }

    public struct SessionSettings: Equatable, Sendable {
        public var peerPort: Int?
        public var downloadLimitKBps: Int?
        public var uploadLimitKBps: Int?
        public init(peerPort: Int?, downloadLimitKBps: Int?, uploadLimitKBps: Int?) {
            self.peerPort = peerPort
            self.downloadLimitKBps = downloadLimitKBps
            self.uploadLimitKBps = uploadLimitKBps
        }
    }

    /// Applied on every engine start and whenever Settings change.
    public var sessionSettings = SessionSettings(peerPort: nil, downloadLimitKBps: nil, uploadLimitKBps: nil)

    public func applySessionSettings() async {
        guard let client else { return }
        var arguments: [String: JSONValue] = [
            "speed_limit_down_enabled": .bool(sessionSettings.downloadLimitKBps != nil),
            "speed_limit_down": .number(Double(sessionSettings.downloadLimitKBps ?? 0)),
            "speed_limit_up_enabled": .bool(sessionSettings.uploadLimitKBps != nil),
            "speed_limit_up": .number(Double(sessionSettings.uploadLimitKBps ?? 0)),
            "download_dir": .string(defaultDownloadDirectory.path)
        ]
        if let port = sessionSettings.peerPort, (1024...65535).contains(port) { arguments["peer_port"] = .number(Double(port)) }
        do { try await client.setSession(arguments) } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Commands

    @discardableResult
    public func add(
        _ source: TorrentSource,
        downloadDirectory: URL? = nil,
        sequential: Bool = false,
        seedPolicy: SeedPolicy? = nil,
        selectFiles: Bool? = nil
    ) async throws -> TorrentRecord {
        let client = try await ensureEngine()
        let directory = (downloadDirectory ?? defaultDownloadDirectory).path
        let waitForSelection = selectFiles ?? selectFilesBeforeDownload
        let result = try await client.add(source, downloadDirectory: directory,
                                          paused: waitForSelection, sequential: sequential)
        let policy = seedPolicy ?? defaultSeedPolicy
        try? await client.set(result.hash, policy.torrentArguments)
        if let existing = record(for: result.hash) { return existing }
        var magnet: String?
        if case .magnet(let link) = source { magnet = link }
        let record = TorrentRecord(
            hash: result.hash, name: result.name == result.hash ? source.displayHint : result.name,
            downloadDirectory: directory, magnetLink: magnet, seedPolicy: policy,
            awaitingFileSelection: waitForSelection
        )
        records.append(record)
        persist()
        await refresh()
        return record
    }

    /// Confirms file selection and starts the download.
    public func confirmSelection(hash: String, wantedIndices: Set<Int>, highPriority: Set<Int> = []) async throws {
        let client = try await ensureEngine()
        guard let snapshot = torrents.first(where: { $0.hash == hash }) else { return }
        let all = Set(snapshot.files.map(\.index))
        let wanted = wantedIndices.intersection(all)
        guard !wanted.isEmpty else {
            errorMessage = "至少选择一个文件"
            return
        }
        var arguments: [String: JSONValue] = [
            "files_wanted": .array(wanted.sorted().map { .number(Double($0)) })
        ]
        let unwanted = all.subtracting(wanted)
        if !unwanted.isEmpty { arguments["files_unwanted"] = .array(unwanted.sorted().map { .number(Double($0)) }) }
        let high = highPriority.intersection(wanted)
        if !high.isEmpty { arguments["priority_high"] = .array(high.sorted().map { .number(Double($0)) }) }
        try await client.set(hash, arguments)
        try await client.start(hash)
        updateRecord(hash) { $0.awaitingFileSelection = false }
        await refresh()
    }

    public func pause(_ hash: String) async {
        await perform { try await $0.stop(hash) }
    }

    public func resume(_ hash: String) async {
        await perform { try await $0.start(hash) }
    }

    public func setSequential(_ hash: String, _ enabled: Bool) async {
        await perform { try await $0.set(hash, ["sequential_download": .bool(enabled)]) }
    }

    public func setSeedPolicy(_ hash: String, _ policy: SeedPolicy) async {
        await perform { try await $0.set(hash, policy.torrentArguments) }
        updateRecord(hash) { $0.seedPolicy = policy }
    }

    /// Removes the torrent from the list. Files on disk are left untouched.
    public func removeKeepingFiles(_ hash: String) async {
        await perform { try await $0.removeKeepingData(hash) }
        records.removeAll { $0.hash == hash }
        persist()
        await refresh()
    }

    public func contentURL(for snapshot: TorrentSnapshot) -> URL {
        URL(fileURLWithPath: snapshot.downloadDirectory, isDirectory: true).appendingPathComponent(snapshot.name)
    }

    // MARK: Polling

    public func refresh() async {
        guard let client else { return }
        do {
            let snapshots = try await client.torrents()
            torrents = snapshots.sorted { lhs, rhs in
                (record(for: lhs.hash)?.addedAt ?? .distantPast) > (record(for: rhs.hash)?.addedAt ?? .distantPast)
            }
            reconcile(snapshots)
        } catch {
            if daemon?.isRunning == false {
                engineStatus = .unavailable("Torrent 引擎意外退出")
                resetEngineState()
            }
        }
    }

    private func resetEngineState() {
        pollTask?.cancel()
        pollTask = nil
        client = nil
        daemon = nil
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let fast = self?.isObserved == true
                    || self?.torrents.contains { $0.state == .downloading || !$0.hasMetadata } == true
                try? await Task.sleep(nanoseconds: fast ? 1_000_000_000 : 5_000_000_000)
            }
        }
    }

    /// Applies completion side effects exactly once per torrent.
    private func reconcile(_ snapshots: [TorrentSnapshot]) {
        for snapshot in snapshots {
            if record(for: snapshot.hash) == nil {
                // Torrent existed in the engine before this app knew it (e.g. history reset).
                records.append(TorrentRecord(
                    hash: snapshot.hash, name: snapshot.name, downloadDirectory: snapshot.downloadDirectory,
                    magnetLink: nil, seedPolicy: defaultSeedPolicy, awaitingFileSelection: false
                ))
                persist()
            }
            guard let record = record(for: snapshot.hash) else { continue }
            if record.name != snapshot.name && snapshot.hasMetadata {
                updateRecord(snapshot.hash) { $0.name = snapshot.name }
            }
            if !snapshot.errorString.isEmpty && record.lastError != snapshot.errorString {
                updateRecord(snapshot.hash) { $0.lastError = snapshot.errorString }
            }
            guard snapshot.isComplete, record.manifestPath == nil,
                  !manifestsInFlight.contains(snapshot.hash) else { continue }
            manifestsInFlight.insert(snapshot.hash)
            if record.seedPolicy == .stopWhenDone {
                Task { await pause(snapshot.hash) }
            }
            let version = engineVersion
            Task.detached(priority: .utility) { [weak self] in
                let result = Result { try TorrentManifestWriter.write(snapshot: snapshot, record: record, engineVersion: version) }
                await self?.finishManifest(hash: snapshot.hash, result: result)
            }
        }
    }

    private func finishManifest(hash: String, result: Result<URL, Error>) {
        manifestsInFlight.remove(hash)
        switch result {
        case .success(let url):
            updateRecord(hash) { $0.manifestPath = url.path; $0.completedAt = Date(); $0.lastError = nil }
        case .failure(let error):
            updateRecord(hash) { $0.lastError = "清单生成失败：\(error.localizedDescription)" }
        }
    }

    private func perform(_ action: (TransmissionRPCClient) async throws -> Void) async {
        do {
            try await action(try await ensureEngine())
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateRecord(_ hash: String, _ mutation: (inout TorrentRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.hash == hash }) else { return }
        mutation(&records[index])
        persist()
    }

    private func persist() {
        do { try TorrentHistoryStore.save(records, to: historyURL) }
        catch { errorMessage = "Torrent 记录无法保存：\(error.localizedDescription)" }
    }
}
#endif
