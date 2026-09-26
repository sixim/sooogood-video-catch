import AppKit
import SwiftUI
import MediaFetchCore
import MediaFetchMusic

struct SettingsView: View {
    @ObservedObject var viewModel: SpotifyBridgeViewModel
    @ObservedObject var loginStore: StreamingSiteLoginStore
    let onBack: () -> Void

    @State private var copiedCallback = false
    @State private var showPrivacyPolicy = false

    var body: some View {
        ZStack {
            CinematicBackground(accent: MediaFetchTheme.musicPurple)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
#if !MEDIAFETCH_STORE_PROFILE
                    WebsiteLoginSettingsView(loginStore: loginStore)
#endif
                    spotifySettings
                    privacyPanel
                }
                .frame(maxWidth: 880)
                .padding(.horizontal, 38)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showPrivacyPolicy) {
            PrivacyPolicyView()
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            PageBackButton(action: onBack)
            VStack(alignment: .leading, spacing: 3) {
                Text("设置")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(MediaFetchTheme.primaryText)
                Text(settingsSubtitle)
                    .font(.caption)
                    .foregroundStyle(MediaFetchTheme.secondaryText)
            }
            Spacer()
        }
    }

    private var settingsSubtitle: String {
#if MEDIAFETCH_STORE_PROFILE
        return "Spotify 连接、隐私与本地音频工具"
#else
        return "账号连接、隐私与本机工具"
#endif
    }

    private var spotifySettings: some View {
        MediaFetchPanel {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "music.note")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(MediaFetchTheme.musicGradient, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Spotify 连接")
                            .font(.title3.bold())
                            .foregroundStyle(MediaFetchTheme.primaryText)
                        Text("只读取曲目身份、专辑与歌单顺序")
                            .font(.caption)
                            .foregroundStyle(MediaFetchTheme.secondaryText)
                    }
                    Spacer()
                    StatusPill(
                        text: viewModel.connectionState.displayName,
                        systemImage: viewModel.connectionState.systemImage,
                        color: viewModel.connectionState.color
                    )
                }

                Divider().overlay(MediaFetchTheme.border)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Spotify Developer App Client ID")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MediaFetchTheme.primaryText)
                    TextField("粘贴 Client ID（不需要 Client Secret）", text: $viewModel.clientID)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 13)
                        .frame(height: 42)
                        .background(MediaFetchTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 11))
                        .overlay {
                            RoundedRectangle(cornerRadius: 11)
                                .stroke(MediaFetchTheme.border, lineWidth: 1)
                        }
                        .accessibilityLabel("Spotify Client ID")

                    Text("Client ID 只保存在这台 Mac 的本机设置中；授权令牌保存在 macOS 钥匙串。")
                        .font(.caption)
                        .foregroundStyle(MediaFetchTheme.secondaryText)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("回调地址")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MediaFetchTheme.primaryText)
                    HStack(spacing: 10) {
                        Text(viewModel.callbackDisplayURL)
                            .font(.caption.monospaced())
                            .foregroundStyle(MediaFetchTheme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            copyCallback()
                        } label: {
                            Label(copiedCallback ? "已复制" : "复制", systemImage: copiedCallback ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(12)
                    .background(MediaFetchTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 11))

                    Text("请在 Spotify Developer Dashboard 注册上面的无端口地址；连接时 \(MediaFetchRelease.displayName) 只监听 127.0.0.1，并自动生成临时端口，不会从局域网接收登录回调。")
                        .font(.caption)
                        .foregroundStyle(MediaFetchTheme.secondaryText)
                }

                if let error = viewModel.inlineError {
                    InlineMessage(text: error, kind: .error)
                }

                HStack(spacing: 12) {
                    Button {
                        openDashboard()
                    } label: {
                        Label("打开 Developer Dashboard", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    if viewModel.hasStoredCredentials {
                        Button(role: .destructive) {
                            Task { await viewModel.disconnect() }
                        } label: {
                            Label("断开并删除本地凭据", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.connectionState.isBusy)
                    } else {
                        Button {
                            Task { await viewModel.connect() }
                        } label: {
                            if viewModel.connectionState.isBusy {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("连接 Spotify", systemImage: "link")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.connectionState.isBusy)
                    }
                }
            }
        }
    }

    private var privacyPanel: some View {
        MediaFetchPanel {
            VStack(alignment: .leading, spacing: 14) {
                Label("音乐页的边界", systemImage: "lock.shield.fill")
                    .font(.headline)
                    .foregroundStyle(MediaFetchTheme.primaryText)
                Text("Spotify 只提供曲目身份与排序。\(MediaFetchRelease.displayName) 不请求 Spotify 音频、不读取浏览器 Cookie、不录制播放输出，也不会用其他网站的音频冒充 Spotify 文件。")
                    .font(.subheadline)
                    .foregroundStyle(MediaFetchTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Label("本地音频扫描为只读；保存时复制到新素材包并验证 SHA-256。", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(MediaFetchTheme.success)

                Divider().overlay(MediaFetchTheme.border)

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("隐私政策")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MediaFetchTheme.primaryText)
                        Text("说明凭据、元数据、本地文件与可选浏览器登录状态如何处理")
                            .font(.caption)
                            .foregroundStyle(MediaFetchTheme.secondaryText)
                    }
                    Spacer()
                    Button {
                        showPrivacyPolicy = true
                    } label: {
                        Label("查看", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func copyCallback() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(viewModel.callbackDisplayURL, forType: .string)
        copiedCallback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            copiedCallback = false
        }
    }

    private func openDashboard() {
        guard let url = URL(string: "https://developer.spotify.com/dashboard") else { return }
        NSWorkspace.shared.open(url)
    }
}

enum InlineMessageKind {
    case info
    case warning
    case error

    var color: Color {
        switch self {
        case .info: return MediaFetchTheme.videoAccent
        case .warning: return MediaFetchTheme.warning
        case .error: return MediaFetchTheme.danger
        }
    }

    var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

struct InlineMessage: View {
    let text: String
    let kind: InlineMessageKind

    var body: some View {
        Label(text, systemImage: kind.icon)
            .font(.caption)
            .foregroundStyle(kind.color)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(kind.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(kind.color.opacity(0.18), lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
    }
}
