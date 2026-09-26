#if !MEDIAFETCH_STORE_PROFILE
import SwiftUI
import MediaFetchCore
import MediaFetchResolve

enum ResolvePreferences {
    static let autoSendKey = "MediaFetch.resolve.autoSend"
    static let createTimelineKey = "MediaFetch.resolve.createTimeline"
}

/// "发送到达芬奇" for one finished package. Reads the shared service from the
/// environment so task lists stay unaware of the Resolve module otherwise.
struct ResolveSendButton: View {
    enum Target {
        case package(URL)
        case files([URL], binName: String, manifest: URL?)

        var key: String {
            switch self {
            case .package(let url): return url.path
            case .files(let files, let bin, _): return bin + "|" + (files.first?.path ?? "")
            }
        }
    }

    let target: Target
    @EnvironmentObject private var resolve: ResolveService
    @AppStorage(ResolvePreferences.createTimelineKey) private var createTimeline = false

    var body: some View {
        HStack(spacing: 6) {
            if resolve.sendingPackages.contains(target.key) {
                ProgressView().controlSize(.mini)
                Text("正在发送到达芬奇…")
            } else if let result = resolve.lastResults[target.key] {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(MediaFetchTheme.success)
                Text("已导入达芬奇「\(result.project)」· \(result.clips.count) 个片段")
                    .help("媒体夹：" + result.bin.joined(separator: " › "))
            } else {
                Button {
                    Task { await send() }
                } label: {
                    Label("发送到达芬奇", systemImage: "film.stack")
                }
                .buttonStyle(.link)
            }
        }
    }

    private func send() async {
        switch target {
        case .package(let url):
            await resolve.send(packageDirectory: url, timelineName: createTimeline ? url.lastPathComponent : nil)
        case .files(let files, let bin, let manifest):
            await resolve.send(files: files, binName: bin, manifestURL: manifest, key: target.key)
        }
    }
}

/// Settings card: connection state, launch, and automation toggles.
struct ResolveSettingsPanel: View {
    @EnvironmentObject private var resolve: ResolveService
    @AppStorage(ResolvePreferences.autoSendKey) private var autoSend = false
    @AppStorage(ResolvePreferences.createTimelineKey) private var createTimeline = false

    var body: some View {
        MediaFetchPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(MediaFetchTheme.toolsAccent, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("DaVinci Resolve")
                            .font(.title3.bold())
                            .foregroundStyle(MediaFetchTheme.primaryText)
                        Text("把素材包导入当前项目的媒体池「Sooogood › 素材包名」，并写入来源和校验信息")
                            .font(.caption)
                            .foregroundStyle(MediaFetchTheme.secondaryText)
                    }
                    Spacer()
                    Button("检测连接") { Task { await resolve.refreshStatus() } }
                        .buttonStyle(.bordered)
                }
                statusLine
                Toggle("下载完成后自动发送到达芬奇", isOn: $autoSend)
                Toggle("发送时同时用这些片段建立时间线", isOn: $createTimeline)
            }
            .font(.subheadline)
            .foregroundStyle(MediaFetchTheme.primaryText)
        }
        .task { if resolve.connection == .unknown && resolve.isInstalled { await resolve.refreshStatus() } }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch resolve.connection {
        case .unknown:
            Text(resolve.isInstalled ? "尚未检测" : "没有找到 DaVinci Resolve")
                .font(.caption).foregroundStyle(MediaFetchTheme.secondaryText)
        case .checking:
            HStack { ProgressView().controlSize(.small); Text("正在连接达芬奇…").font(.caption) }
        case .connected(let status):
            Label("\(status.product) \(status.version) · 当前项目：\(status.project ?? "无")",
                  systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(MediaFetchTheme.success)
        case .failed(let message, let canLaunch):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(MediaFetchTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                if canLaunch {
                    Button("打开达芬奇") { Task { await resolve.launchResolve() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
    }
}
#endif
