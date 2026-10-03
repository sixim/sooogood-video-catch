#if !MEDIAFETCH_STORE_PROFILE
import AppKit
import SwiftUI
import MediaFetchCore
import MediaFetchVideo

/// "移动到…": pick finished packages, pick a folder, confirm, move.
/// Same disk: rename. Other disk: copy → verify SHA-256 → remove original.
struct MovePackagesSheet: View {
    @ObservedObject var downloader: DownloaderService
    let musicOnly: Bool
    let onClose: () -> Void

    @State private var packages: [DownloaderService.RelocatablePackage] = []
    @State private var selected: Set<String> = []
    @State private var target: URL?
    @State private var confirming = false
    @State private var running = false
    @State private var done = 0
    @State private var report: DownloaderService.RelocationReport?
    @State private var sizes: [String: Int64] = [:]

    private var chosen: [DownloaderService.RelocatablePackage] { packages.filter { selected.contains($0.id) } }
    private var chosenBytes: Int64 { chosen.reduce(0) { $0 + (sizes[$1.id] ?? 0) } }
    private var sentToResolve: Int { chosen.filter { PackageRelocation.wasSentToResolve($0.package) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(musicOnly ? String(localized: "移动音乐到…") : String(localized: "移动素材包到…")).font(.title3.bold())
                Spacer()
                Text("已选 \(selected.count) / \(packages.count) · \(Self.format(chosenBytes))")
                    .font(.caption).foregroundStyle(.secondary)
                Button("全选") { selected = Set(packages.map(\.id)) }.buttonStyle(.link)
                Button("全不选") { selected = [] }.buttonStyle(.link)
            }
            Text("整个素材包一起移动（音频 / 视频、封面、歌词、清单），保留「歌手 / 专辑」层级。同一块磁盘直接移动；换磁盘时先复制并按清单校验 SHA-256，通过后才删除原文件。目标位置已有同名文件夹的不会覆盖。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            List(packages) { item in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { selected.contains(item.id) },
                                             set: { if $0 { selected.insert(item.id) } else { selected.remove(item.id) } }))
                        .toggleStyle(.checkbox).labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.job.title ?? item.package.lastPathComponent).lineLimit(1)
                        Text((item.package.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if PackageRelocation.wasSentToResolve(item.package) {
                        Image(systemName: "film.stack").foregroundStyle(.secondary).help("已发送到达芬奇")
                    }
                    Text(Self.format(sizes[item.id] ?? 0)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 260)

            HStack(spacing: 10) {
                Button("选择目标文件夹…") { chooseTarget() }
                Text(target.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? String(localized: "未选择"))
                    .font(.callout).foregroundStyle(target == nil ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
                Spacer()
            }

            if running {
                ProgressView(value: Double(done), total: Double(max(chosen.count, 1))) {
                    Text("正在移动 \(min(done + 1, chosen.count)) / \(chosen.count)…").font(.caption)
                }
            }
            if let report { reportView(report) }

            HStack {
                Spacer()
                Button(report == nil ? String(localized: "取消") : String(localized: "关闭"), action: onClose).keyboardShortcut(.cancelAction).disabled(running)
                if report == nil {
                    Button("移动") { confirming = true }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(chosen.isEmpty || target == nil || running)
                }
            }
        }
        .padding(22)
        .frame(width: 720, height: 600)
        .onAppear(perform: load)
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button("移动 \(chosen.count) 个") { run() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private var confirmTitle: String {
        let folder = target?.lastPathComponent ?? ""
        return String(localized: "把 \(chosen.count) 个素材包（\(Self.format(chosenBytes))）移动到「\(folder)」？")
    }

    private var confirmMessage: String {
        var lines = [(target?.path as NSString?)?.abbreviatingWithTildeInPath ?? ""]
        if sentToResolve > 0 {
            lines.append(String(localized: "其中 \(sentToResolve) 个已发送到达芬奇：移动后达芬奇里对应片段会变成离线，需要在达芬奇里重新链接（Relink）。"))
        }
        lines.append(String(localized: "任务记录会更新到新位置。"))
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func reportView(_ report: DownloaderService.RelocationReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(String(localized: "已移动 \(report.moved.count) 个") + (report.copiedAcrossVolumes > 0 ? String(localized: "（其中 \(report.copiedAcrossVolumes) 个跨磁盘复制并校验）") : ""),
                  systemImage: "checkmark.circle.fill").foregroundStyle(MediaFetchTheme.success)
            ForEach(Array(report.skipped.enumerated()), id: \.offset) { _, item in
                Text("跳过 · \(item.title)：\(item.reason)").font(.caption).foregroundStyle(MediaFetchTheme.warning).lineLimit(2)
            }
            ForEach(Array(report.failed.enumerated()), id: \.offset) { _, item in
                Text("失败 · \(item.title)：\(item.reason)").font(.caption).foregroundStyle(MediaFetchTheme.danger).lineLimit(2)
            }
        }
        .font(.callout)
    }

    private func load() {
        packages = downloader.relocatablePackages(musicOnly: musicOnly)
        let folders = packages.map(\.package)
        Task.detached(priority: .utility) {
            let result = Dictionary(uniqueKeysWithValues: folders.map { ($0.path, Self.folderSize($0)) })
            await MainActor.run { sizes = result }
        }
    }

    private func chooseTarget() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "选择")
        panel.message = String(localized: "选择要移动到的文件夹")
        if panel.runModal() == .OK { target = panel.url }
    }

    private func run() {
        guard let target else { return }
        let items = chosen
        running = true
        done = 0
        Task {
            let result = await downloader.relocatePackages(items, to: target) { count in
                Task { @MainActor in done = count }
            }
            running = false
            report = result
            load()
            selected = []
        }
    }

    nonisolated static func folderSize(_ folder: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
#endif
