#if !MEDIAFETCH_STORE_PROFILE
import SwiftUI
import MediaFetchCore

/// Shows what a batch will do before it starts: ready items, problems, and
/// whether the estimated size fits on the destination disk.
struct BatchPreflightSheet: View {
    let report: BatchPreflight.Report?
    let onEnqueue: (_ urls: [String]) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("批量预检").font(.title2.bold())
            if let report {
                summary(report)
                List(report.items) { item in row(item) }
                    .frame(minHeight: 240)
                HStack {
                    Spacer()
                    Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                    if report.verdict == .goWithSkips {
                        Button("全部加入（\(report.items.count)）") { onEnqueue(report.items.map(\.url)) }
                    }
                    Button(report.verdict == .go ? String(localized: "加入队列（\(report.readyCount)）") : String(localized: "只加入可下载的 \(report.readyCount) 条")) {
                        onEnqueue(report.readyURLs)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(report.readyCount == 0)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在逐条解析链接（每次 3 条）…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
                HStack { Spacer(); Button("取消", action: onCancel) }
            }
        }
        .padding(22)
        .frame(width: 680, height: 520)
    }

    private func summary(_ report: BatchPreflight.Report) -> some View {
        let size = ByteCountFormatter.string(fromByteCount: report.estimatedBytes, countStyle: .file)
        let free = report.availableBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? String(localized: "未知")
        return VStack(alignment: .leading, spacing: 4) {
            Label(String(localized: "\(report.readyCount)/\(report.items.count) 条可以下载 · 预计 \(size)") +
                  (report.unknownSizeCount > 0 ? String(localized: "（另有 \(report.unknownSizeCount) 条大小未知）") : "") +
                  String(localized: " · 目标磁盘剩余 \(free)"),
                  systemImage: report.verdict == .stop ? "xmark.octagon.fill" : "checkmark.seal.fill")
                .foregroundStyle(report.verdict == .stop ? MediaFetchTheme.danger : MediaFetchTheme.success)
            if !report.fitsOnDisk {
                Text("预计大小（含 10% 余量）超过剩余空间，请换一个保存位置或减少链接。")
                    .font(.caption).foregroundStyle(MediaFetchTheme.danger)
            }
            if report.problems.contains(where: { $0.problem?.isActionable == true }) {
                Text("部分链接需要登录：在「设置 › 流媒体网站登录」启用对应网站后可重新预检。")
                    .font(.caption).foregroundStyle(MediaFetchTheme.warning)
            }
        }
        .font(.subheadline)
    }

    private func row(_ item: BatchPreflight.Item) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.problem == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(item.problem == nil ? MediaFetchTheme.success : MediaFetchTheme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title ?? item.url).lineLimit(1)
                Text(item.problem?.displayName ?? item.detail ?? item.url)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if let bytes = item.estimatedBytes {
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

struct ShortcutSettingsPanel: View {
    @AppStorage(GlobalHotKey.preferenceKey) private var hotKeyEnabled = false

    var body: some View {
        MediaFetchPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text("快捷操作").font(.title3.bold()).foregroundStyle(MediaFetchTheme.primaryText)
                Toggle("⌘⇧D：把剪贴板里的链接送进 \(MediaFetchRelease.shortDisplayName)", isOn: $hotKeyEnabled)
                    .onChange(of: hotKeyEnabled) { _, enabled in GlobalHotKey.shared.setEnabled(enabled) }
                Text("在任何应用里复制视频链接或磁力链接后按 ⌘⇧D，会自动打开对应页面并开始解析。只在按下快捷键时读取剪贴板。")
                    .font(.caption).foregroundStyle(MediaFetchTheme.secondaryText)
            }
            .foregroundStyle(MediaFetchTheme.primaryText)
        }
    }
}
#endif
