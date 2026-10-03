#if !MEDIAFETCH_STORE_PROFILE
import SwiftUI
import MediaFetchCore

/// Site-specific browser session controls shared by Settings and the video
/// workflow. The view never asks for, displays or persists account secrets.
struct WebsiteLoginSettingsView: View {
    @ObservedObject var loginStore: StreamingSiteLoginStore

    private let columns = [
        GridItem(.adaptive(minimum: 330, maximum: 420), spacing: 14, alignment: .top)
    ]

    var body: some View {
        MediaFetchPanel {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(MediaFetchTheme.videoAccent, in: RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("流媒体网站登录")
                            .font(.title3.bold())
                            .foregroundStyle(MediaFetchTheme.primaryText)
                        Text("在 \(MediaFetchRelease.displayName) 内打开官网登录，分别保存各网站会话")
                            .font(.caption)
                            .foregroundStyle(MediaFetchTheme.secondaryText)
                    }

                    Spacer()

                    StatusPill(
                        text: loginStore.enabledCount == 0 ? String(localized: "尚未启用") : String(localized: "已配置 \(loginStore.enabledCount) 个网站"),
                        systemImage: loginStore.enabledCount == 0 ? "person.crop.circle.badge.questionmark" : "checkmark.shield.fill",
                        color: loginStore.enabledCount == 0 ? MediaFetchTheme.secondaryText : MediaFetchTheme.success
                    )
                }

                Divider().overlay(MediaFetchTheme.border)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(StreamingPlatform.browserLoginPlatforms) { platform in
                        WebsiteLoginCard(platform: platform, loginStore: loginStore)
                    }
                }

                Label(
                    String(localized: "会话只用于对应平台的解析与下载。Google 等第三方登录服务可能要求兼容登录。"),
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(MediaFetchTheme.secondaryText)
            }
        }
    }
}

private struct WebsiteLoginCard: View {
    let platform: StreamingPlatform
    @ObservedObject var loginStore: StreamingSiteLoginStore

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Image(systemName: platform.systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 34, height: 34)
                    .background(accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 2) {
                    Text(platform.displayName)
                        .font(.headline)
                        .foregroundStyle(MediaFetchTheme.primaryText)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(loginStore.isEnabled(for: platform) ? MediaFetchTheme.success : MediaFetchTheme.secondaryText)
                }

                Spacer()

                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel("为 \(platform.displayName) 启用登录会话")
            }

            Text(platform.browserLoginPurpose)
                .font(.caption)
                .foregroundStyle(MediaFetchTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    loginStore.beginInAppLogin(for: platform)
                } label: {
                    Label(platform == .youtube ? String(localized: "登录 YouTube") : String(localized: "在 App 内登录"), systemImage: "person.crop.rectangle")
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("清除会话") {
                    Task { await loginStore.clearSession(for: platform) }
                }.buttonStyle(.bordered)
            }

            DisclosureGroup("兼容登录设置") {
                Picker("登录方式", selection: Binding(
                    get: { loginStore.method(for: platform) },
                    set: { loginStore.setMethod($0, for: platform) }
                )) {
                    Text("应用内会话").tag(SiteLoginMethod.inApp)
                    Text("外部浏览器").tag(SiteLoginMethod.browser)
                }
                HStack(spacing: 10) {
                Picker("登录浏览器", selection: browserBinding) {
                    ForEach(BrowserCookieSource.allCases) { browser in
                        Text(browser.displayName).tag(browser)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    loginStore.openLoginPage(for: platform)
                } label: {
                    Label("打开登录页", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                }
            }

            if loginStore.method(for: platform) == .browser && !loginStore.isBrowserInstalled(loginStore.browser(for: platform)) {
                InlineMessage(
                    text: String(localized: "没有检测到所选浏览器，请先选择本机已安装并完成登录的浏览器。"),
                    kind: .warning
                )
            } else if loginStore.method(for: platform) == .browser && loginStore.browser(for: platform) == .safari {
                Text("Safari Cookie 受 macOS 保护，使用前可能需要为 \(MediaFetchRelease.displayName) 开启完整磁盘访问。")
                    .font(.caption2)
                    .foregroundStyle(MediaFetchTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(15)
        .background(MediaFetchTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(loginStore.isEnabled(for: platform) ? accent.opacity(0.5) : MediaFetchTheme.border, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { loginStore.isEnabled(for: platform) },
            set: { loginStore.setEnabled($0, for: platform) }
        )
    }

    private var browserBinding: Binding<BrowserCookieSource> {
        Binding(
            get: { loginStore.browser(for: platform) },
            set: { loginStore.setBrowser($0, for: platform) }
        )
    }

    private var statusText: String {
        guard loginStore.isEnabled(for: platform) else { return String(localized: "未启用") }
        if loginStore.method(for: platform) == .inApp { return String(localized: "使用应用内会话 · 待解析验证") }
        return String(localized: "下载时使用 \(loginStore.browser(for: platform).displayName)")
    }

    private var accent: Color {
        switch platform {
        case .youtube: return Color(red: 1.0, green: 0.25, blue: 0.30)
        case .vimeo: return Color(red: 0.18, green: 0.68, blue: 1.0)
        case .bilibili: return Color(red: 0.96, green: 0.45, blue: 0.65)
        case .youku: return Color(red: 0.55, green: 0.48, blue: 1.0)
        case .udemy: return Color(red: 0.64, green: 0.36, blue: 0.96)
        case .netease: return Color(red: 0.89, green: 0.16, blue: 0.19)
        case .qqmusic: return Color(red: 0.19, green: 0.76, blue: 0.49)
        default: return MediaFetchTheme.videoAccent
        }
    }
}
#endif
