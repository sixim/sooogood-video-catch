#if !MEDIAFETCH_STORE_PROFILE
import AppKit
import SwiftUI
import MediaFetchCore
import MediaFetchVideo

/// One external Homebrew tool as shown to the user. Engine modules report their
/// own health; this row type is the only thing the Settings UI needs to know.
struct DependencyItem: Identifiable, Equatable {
    enum Level: Equatable { case ready, attention, missing }

    let id: String
    let name: String
    let purpose: String
    let level: Level
    let detail: String
    let command: String?
}

/// "Is it installed?" at a glance — the most-commented pain point in comparable
/// downloaders. Each row carries the exact brew command to fix it.
struct DependencyStatusPanel: View {
    @State private var items: [DependencyItem] = []
    @State private var copied: String?

    var body: some View {
        MediaFetchPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(MediaFetchTheme.videoAccent, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("本机工具")
                            .font(.title3.bold())
                            .foregroundStyle(MediaFetchTheme.primaryText)
                        Text("全部通过 Homebrew 安装与升级，应用不会自行下载可执行文件")
                            .font(.caption)
                            .foregroundStyle(MediaFetchTheme.secondaryText)
                    }
                    Spacer()
                    Button("重新检测") { Task { await refresh() } }
                        .buttonStyle(.bordered)
                }
                if items.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在检测本机工具…").font(.caption).foregroundStyle(MediaFetchTheme.secondaryText)
                    }
                }
                ForEach(items) { item in row(item) }
                if let copied {
                    Text("已复制：\(copied)，请在终端运行后点“重新检测”")
                        .font(.caption2)
                        .foregroundStyle(MediaFetchTheme.success)
                }
            }
        }
        .task { await refresh() }
    }

    private func row(_ item: DependencyItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(item.level))
                .foregroundStyle(color(item.level))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.subheadline.bold()).foregroundStyle(MediaFetchTheme.primaryText)
                Text("\(item.purpose) · \(item.detail)")
                    .font(.caption)
                    .foregroundStyle(MediaFetchTheme.secondaryText)
            }
            Spacer()
            if let command = item.command, item.level != .ready {
                Button(command) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = command
                }
                .font(.caption.monospaced())
                .buttonStyle(.bordered)
            }
        }
    }

    @MainActor
    private func refresh() async {
        var result: [DependencyItem] = []
        let toolchain = VideoToolchain.applicationDefault
        let health = await VideoEngineHealth.probe(toolchain: toolchain)
        let ytLevel: DependencyItem.Level = {
            switch health.ytDLP {
            case .missing: return .missing
            case .current: return .ready
            default: return .attention
            }
        }()
        result.append(.init(
            id: "yt-dlp", name: "yt-dlp", purpose: String(localized: "视频解析与下载"), level: ytLevel,
            detail: health.ytDLP.summary,
            command: health.ytDLP == .missing ? "brew install yt-dlp" : "brew upgrade yt-dlp"
        ))
        result.append(.init(
            id: "ffmpeg", name: "FFmpeg", purpose: String(localized: "无损封装与转码"),
            level: health.ffmpegInstalled ? .ready : .missing,
            detail: toolchain.ffmpegURL?.path ?? String(localized: "未找到"),
            command: "brew install ffmpeg"
        ))
        result.append(.init(
            id: "deno", name: "deno", purpose: String(localized: "YouTube 签名解析所需的 JS 运行时"),
            level: health.jsRuntimePath == nil ? .attention : .ready,
            detail: health.jsRuntimePath ?? String(localized: "未找到，YouTube 可能缺少高画质格式"),
            command: "brew install deno"
        ))
        items = result + DependencyRegistry.additionalItems()
    }

    private func symbol(_ level: DependencyItem.Level) -> String {
        switch level {
        case .ready: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .missing: return "xmark.circle.fill"
        }
    }

    private func color(_ level: DependencyItem.Level) -> Color {
        switch level {
        case .ready: return MediaFetchTheme.success
        case .attention: return MediaFetchTheme.warning
        case .missing: return MediaFetchTheme.danger
        }
    }
}

/// Extension point: later engines (Torrent, Tools) register their rows here so
/// the panel never grows engine-specific code.
enum DependencyRegistry {
    @MainActor static var providers: [() -> DependencyItem] = []
    @MainActor static func additionalItems() -> [DependencyItem] { providers.map { $0() } }
}
#endif
