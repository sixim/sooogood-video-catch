#if !MEDIAFETCH_STORE_PROFILE
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MediaFetchCore
import MediaFetchTorrent

/// BitTorrent page: add magnet / .torrent, pick files, watch progress, seed policy.
struct TorrentView: View {
    @ObservedObject var service: TorrentService
    let onBack: () -> Void
    var intake: IntakeCoordinator? = nil

    @State private var input = ""
    @State private var sequential = false
    @State private var seedPolicy: SeedPolicy = .default
    @State private var isAdding = false
    @State private var selectionHash: String?
    @State private var isDropTargeted = false
    @AppStorage("MediaFetch.torrent.noticeAccepted") private var noticeAccepted = false
    @AppStorage("MediaFetch.torrent.selectFiles") private var selectFiles = true

    var body: some View {
        ZStack {
            CinematicBackground(accent: MediaFetchTheme.torrentAccent)
            VStack(alignment: .leading, spacing: 18) {
                header
                if !service.engineInstalled {
                    engineMissing
                } else if !noticeAccepted {
                    notice
                } else {
                    addPanel
                    list
                }
            }
            .frame(maxWidth: 1180)
            .padding(.horizontal, 36)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: intake?.pendingTorrentInputs.count) { _, _ in consumePendingInputs() }
        .onAppear {
            consumePendingInputs()
            service.isObserved = true
            if service.engineInstalled && noticeAccepted { Task { try? await service.ensureEngine() } }
        }
        .onDisappear { service.isObserved = false }
        .sheet(item: Binding(
            // Opens once metadata exists; for magnets that is a few seconds after adding.
            get: { selectionHash.flatMap { hash in service.torrents.first { $0.hash == hash && $0.hasMetadata } } },
            set: { selectionHash = $0?.hash }
        )) { snapshot in
            TorrentFileSelectionSheet(snapshot: snapshot) { wanted, high in
                Task { try? await service.confirmSelection(hash: snapshot.hash, wantedIndices: wanted, highPriority: high) }
                selectionHash = nil
            } onCancel: {
                selectionHash = nil
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 16) {
            PageBackButton(action: onBack)
            VStack(alignment: .leading, spacing: 3) {
                Text("Torrent")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(MediaFetchTheme.primaryText)
                Text("磁力链接与 .torrent 文件 · 由本机 Transmission 引擎下载")
                    .font(.caption)
                    .foregroundStyle(MediaFetchTheme.secondaryText)
            }
            Spacer()
            StatusPill(text: engineText, systemImage: engineSymbol, color: engineColor)
        }
    }

    private var engineMissing: some View {
        MediaFetchPanel {
            VStack(alignment: .leading, spacing: 12) {
                Label("需要安装 Transmission 引擎", systemImage: "shippingbox")
                    .font(.headline)
                    .foregroundStyle(MediaFetchTheme.primaryText)
                Text("Torrent 下载使用 Homebrew 提供的 transmission-daemon。在终端执行下面的命令后回到本页：")
                    .font(.subheadline)
                    .foregroundStyle(MediaFetchTheme.secondaryText)
                CopyableCommand(command: "brew install transmission-cli")
            }
        }
    }

    private var notice: some View {
        MediaFetchPanel {
            VStack(alignment: .leading, spacing: 12) {
                Label("使用前请确认", systemImage: "hand.raised.fill")
                    .font(.headline)
                    .foregroundStyle(MediaFetchTheme.primaryText)
                Text("BitTorrent 下载的同时会把已下载的部分分享给其他用户。请只下载你有权获取和分享的内容，例如开源软件、公有领域作品或权利人授权分发的素材。\(MediaFetchRelease.displayName) 不提供种子搜索或索引功能。")
                    .font(.subheadline)
                    .foregroundStyle(MediaFetchTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("我了解，开始使用") {
                    noticeAccepted = true
                    Task { try? await service.ensureEngine() }
                }
                .buttonStyle(.borderedProminent)
                .tint(MediaFetchTheme.torrentAccent)
            }
        }
    }

    private var addPanel: some View {
        MediaFetchPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    TextField("粘贴 magnet: 链接，或把 .torrent 文件拖到这里", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addFromInput)
                    Button("添加", action: addFromInput)
                        .buttonStyle(.borderedProminent)
                        .tint(MediaFetchTheme.torrentAccent)
                        .disabled(isAdding || input.isEmpty)
                    Button("选择 .torrent…", action: chooseTorrentFile)
                        .buttonStyle(.bordered)
                        .disabled(isAdding)
                }
                HStack(spacing: 18) {
                    Toggle("添加后先选择文件", isOn: $selectFiles)
                    Toggle("顺序下载", isOn: $sequential)
                        .help("按文件顺序下载，便于先预览开头；整体速度可能略慢")
                    Picker("做种", selection: $seedPolicy) {
                        Text(SeedPolicy.stopWhenDone.displayName).tag(SeedPolicy.stopWhenDone)
                        Text(SeedPolicy.ratio(1.0).displayName).tag(SeedPolicy.ratio(1.0))
                        Text(SeedPolicy.ratio(2.0).displayName).tag(SeedPolicy.ratio(2.0))
                        Text(SeedPolicy.idleMinutes(30).displayName).tag(SeedPolicy.idleMinutes(30))
                    }
                    .frame(maxWidth: 280)
                    Spacer()
                    Label(service.defaultDownloadDirectory.path, systemImage: "folder")
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 260, alignment: .trailing)
                    Button("更改…", action: chooseDirectory).buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(MediaFetchTheme.secondaryText)
                if let error = service.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(MediaFetchTheme.danger)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(MediaFetchTheme.torrentAccent, lineWidth: isDropTargeted ? 2 : 0)
        )
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if service.torrents.isEmpty {
                    Text("还没有 Torrent 任务")
                        .foregroundStyle(MediaFetchTheme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 160)
                }
                ForEach(service.torrents) { snapshot in
                    TorrentRow(
                        snapshot: snapshot,
                        record: service.record(for: snapshot.hash),
                        onSelectFiles: { selectionHash = snapshot.hash },
                        onPause: { Task { await service.pause(snapshot.hash) } },
                        onResume: { Task { await service.resume(snapshot.hash) } },
                        onSequential: { value in Task { await service.setSequential(snapshot.hash, value) } },
                        onReveal: { reveal(service.contentURL(for: snapshot)) },
                        onRemove: { Task { await service.removeKeepingFiles(snapshot.hash) } }
                    )
                }
            }
        }
    }

    // MARK: Actions

    /// Magnets / .torrent files routed from elsewhere. Added only after the
    /// first-use notice was accepted; otherwise they wait in the box.
    private func consumePendingInputs() {
        guard let intake, !intake.pendingTorrentInputs.isEmpty else { return }
        let items = intake.pendingTorrentInputs
        intake.pendingTorrentInputs = []
        for item in items {
            switch item {
            case .magnet(let link):
                if noticeAccepted, let source = TorrentSource.magnet(from: link) { add(source) } else { input = link }
            case .torrentFile(let url) where url.isFileURL:
                if noticeAccepted { addFile(url) }
            default:
                break
            }
        }
    }

    private func addFromInput() {
        guard let source = TorrentSource.magnet(from: input) else {
            service.errorMessage = TorrentError.invalidMagnet.localizedDescription
            return
        }
        add(source)
        input = ""
    }

    private func add(_ source: TorrentSource) {
        service.errorMessage = nil
        isAdding = true
        Task {
            defer { isAdding = false }
            do {
                let record = try await service.add(source, sequential: sequential,
                                                   seedPolicy: seedPolicy, selectFiles: selectFiles)
                if record.awaitingFileSelection { selectionHash = record.hash }
            } catch {
                service.errorMessage = error.localizedDescription
            }
        }
    }

    private func chooseTorrentFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addFile(url) }
    }

    private func addFile(_ url: URL) {
        do { add(try TorrentSource.metainfo(fileAt: url)) }
        catch { service.errorMessage = error.localizedDescription }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "torrent" else { return }
                Task { @MainActor in addFile(url) }
            }
        }
        return accepted
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = service.defaultDownloadDirectory
        if panel.runModal() == .OK, let url = panel.url {
            service.defaultDownloadDirectory = url
            UserDefaults.standard.set(url.path, forKey: "MediaFetch.torrent.directory")
        }
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private var engineText: String {
        switch service.engineStatus {
        case .idle: return String(localized: "引擎未启动")
        case .starting: return String(localized: "引擎启动中")
        case .running(let version): return "Transmission \(version.split(separator: " ").first ?? "")"
        case .unavailable: return String(localized: "引擎不可用")
        }
    }

    private var engineSymbol: String {
        if case .running = service.engineStatus { return "checkmark.circle.fill" }
        if case .unavailable = service.engineStatus { return "exclamationmark.triangle.fill" }
        return "circle.dotted"
    }

    private var engineColor: Color {
        if case .running = service.engineStatus { return MediaFetchTheme.success }
        if case .unavailable = service.engineStatus { return MediaFetchTheme.warning }
        return MediaFetchTheme.secondaryText
    }
}

struct TorrentRow: View {
    let snapshot: TorrentSnapshot
    let record: TorrentRecord?
    let onSelectFiles: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onSequential: (Bool) -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void

    var body: some View {
        MediaFetchPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(MediaFetchTheme.torrentAccent)
                        .frame(width: 34, height: 34)
                        .background(MediaFetchTheme.torrentAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(snapshot.name).font(.headline).foregroundStyle(MediaFetchTheme.primaryText).lineLimit(1)
                        Text(detailLine).font(.caption.monospacedDigit()).foregroundStyle(MediaFetchTheme.secondaryText)
                    }
                    Spacer()
                    StatusPill(text: statusText, systemImage: symbol, color: MediaFetchTheme.torrentAccent)
                }
                ProgressView(value: snapshot.hasMetadata ? snapshot.percentDone : snapshot.metadataPercentComplete)
                    .tint(MediaFetchTheme.torrentAccent)
                HStack(spacing: 12) {
                    if awaitingSelection {
                        Button("选择文件…", action: onSelectFiles)
                            .buttonStyle(.borderedProminent)
                            .tint(MediaFetchTheme.torrentAccent)
                            .disabled(!snapshot.hasMetadata)
                    } else if snapshot.state == .stopped {
                        Button("继续", action: onResume).buttonStyle(.bordered)
                    } else {
                        Button("暂停", action: onPause).buttonStyle(.bordered)
                    }
                    Toggle("顺序下载", isOn: Binding(get: { snapshot.sequential }, set: onSequential))
                        .toggleStyle(.checkbox)
                    if let policy = record?.seedPolicy {
                        Text(policy.displayName)
                    }
                    Spacer()
                    if let manifest = record?.manifestPath {
                        ResolveSendButton(target: resolveTarget(manifest: URL(fileURLWithPath: manifest)))
                        Button("显示清单") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: manifest)])
                        }
                        .buttonStyle(.link)
                    }
                    Button("在 Finder 中显示", action: onReveal).buttonStyle(.link)
                    Button("移出列表", role: .destructive, action: onRemove)
                        .buttonStyle(.link)
                        .help("只从列表移除，已下载的文件保留在磁盘上")
                }
                .font(.caption)
                .foregroundStyle(MediaFetchTheme.secondaryText)
                if let error = record?.lastError ?? (snapshot.errorString.isEmpty ? nil : snapshot.errorString) {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(MediaFetchTheme.danger)
                }
            }
        }
    }

    /// Folder torrents import their folder; single-file torrents only their file.
    private func resolveTarget(manifest: URL) -> ResolveSendButton.Target {
        if manifest.lastPathComponent == "torrent-manifest.json" {
            return .package(manifest.deletingLastPathComponent())
        }
        let files = snapshot.files.filter(\.wanted).map {
            URL(fileURLWithPath: snapshot.downloadDirectory).appendingPathComponent($0.name)
        }
        return .files(files, binName: snapshot.name, manifest: manifest)
    }

    private var awaitingSelection: Bool { record?.awaitingFileSelection == true && snapshot.state == .stopped }

    private var statusText: String {
        if !snapshot.hasMetadata { return String(localized: "获取元数据") }
        if awaitingSelection { return String(localized: "等待选择文件") }
        if snapshot.isComplete && snapshot.state == .stopped { return String(localized: "已完成") }
        return snapshot.state.displayName
    }

    private var symbol: String {
        if snapshot.isComplete { return "checkmark.circle.fill" }
        switch snapshot.state {
        case .downloading: return "arrow.down.circle.fill"
        case .seeding, .queuedToSeed: return "arrow.up.circle.fill"
        case .verifying, .queuedToVerify: return "checkmark.shield"
        default: return "pause.circle.fill"
        }
    }

    private var detailLine: String {
        let size = ByteCountFormatter.string(fromByteCount: snapshot.sizeWhenDone, countStyle: .file)
        var parts = [String(format: "%.1f%%", snapshot.percentDone * 100), size]
        if snapshot.downloadRate > 0 { parts.append("↓ " + ByteCountFormatter.string(fromByteCount: snapshot.downloadRate, countStyle: .file) + "/s") }
        if snapshot.uploadRate > 0 { parts.append("↑ " + ByteCountFormatter.string(fromByteCount: snapshot.uploadRate, countStyle: .file) + "/s") }
        if snapshot.eta > 0 { parts.append(String(localized: "剩余 ") + Self.duration(snapshot.eta)) }
        parts.append(String(localized: "\(snapshot.peersConnected) 个连接"))
        parts.append(String(format: String(localized: "分享率 %.2f"), max(snapshot.uploadRatio, 0)))
        return parts.joined(separator: " · ")
    }

    static func duration(_ seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)s"
    }
}

/// A shell command the user copies into Terminal; never executed by the app.
struct CopyableCommand: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text(command).font(.body.monospaced()).textSelection(.enabled)
            Spacer()
            Button(copied ? String(localized: "已复制") : String(localized: "复制")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            }
        }
        .padding(10)
        .background(MediaFetchTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
    }
}
#endif

#if !MEDIAFETCH_STORE_PROFILE
/// Torrent section of the task page: the same rows as the Torrent page.
struct TorrentTaskList: View {
    @EnvironmentObject private var service: TorrentService
    let openTorrent: () -> Void

    var body: some View {
        LazyVStack(spacing: 12) {
            if service.torrents.isEmpty {
                VStack(spacing: 10) {
                    Text(service.engineStatus == .idle ? String(localized: "Torrent 引擎尚未启动") : String(localized: "还没有 Torrent 任务"))
                        .foregroundStyle(MediaFetchTheme.secondaryText)
                    Button("打开 Torrent 页", action: openTorrent).buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            }
            ForEach(service.torrents) { snapshot in
                TorrentRow(
                    snapshot: snapshot,
                    record: service.record(for: snapshot.hash),
                    onSelectFiles: openTorrent,
                    onPause: { Task { await service.pause(snapshot.hash) } },
                    onResume: { Task { await service.resume(snapshot.hash) } },
                    onSequential: { value in Task { await service.setSequential(snapshot.hash, value) } },
                    onReveal: { NSWorkspace.shared.activateFileViewerSelecting([service.contentURL(for: snapshot)]) },
                    onRemove: { Task { await service.removeKeepingFiles(snapshot.hash) } }
                )
            }
        }
        .onAppear { service.isObserved = true }
        .onDisappear { service.isObserved = false }
    }

    static func activeCount(_ service: TorrentService) -> Int {
        service.torrents.filter { $0.state == .downloading || !$0.hasMetadata }.count
    }
}
#endif
