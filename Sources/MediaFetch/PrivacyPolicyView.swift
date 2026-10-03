import SwiftUI
import MediaFetchCore

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            CinematicBackground(accent: MediaFetchTheme.musicPurple)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("隐私政策")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(MediaFetchTheme.primaryText)
                            Text("\(MediaFetchRelease.displayName) · 版本 \(MediaFetchRelease.version)")
                                .font(.caption)
                                .foregroundStyle(MediaFetchTheme.secondaryText)
                        }
                        Spacer()
                        Button("关闭") { dismiss() }
                            .buttonStyle(.bordered)
                    }

                    policySection(String(localized: "我们处理什么"), String(localized: "Sooogood Video Catch 是本地优先的 macOS 工具。除非你主动发起 Spotify 连接或加载网络媒体页面，应用不会向 Sooogood Video Catch 自有服务器上传文件、Cookie、播放输出或素材内容。应用不包含广告、跨 App 跟踪或遥测服务。"))

                    policySection(String(localized: "Spotify 连接"), String(localized: "Spotify OAuth 使用 PKCE。Client ID 保存在本机设置；access token 和 refresh token 只保存在 macOS 钥匙串。应用仅读取曲目身份、专辑、歌单顺序和必要的封面/外部链接元数据，不请求 Spotify 音频，不读取 Spotify Cookie，也不抓取客户端缓存。元数据缓存最多保留 24 小时；在“断开并删除本地凭据”后，令牌和缓存会被删除。"))

                    policySection(String(localized: "本地文件与素材包"), String(localized: "你选择的音频资料夹只以 security-scoped bookmark 形式保存访问授权。扫描过程只读；应用读取标签、时长、编码、ISRC 和文件大小，用于匹配 Spotify 曲目。保存时只复制你确认的文件，并在复制前后计算 SHA-256；原件不移动、不改名、不修改标签。输出目录、文件名、哈希和匹配依据会写入你选择的素材包 manifest。"))

                    policySection(String(localized: "视频与网站登录状态"), String(localized: "Local profile 的应用内登录由 WebKit 在本机按平台独立保存会话，不读取官网密码表单。你明确启用后，对应网站 Cookie 会写入权限受限的临时文件供本机引擎使用，操作结束或取消完成后删除；强制退出可能留下临时文件。在设置中可清除应用内会话。兼容登录会读取你指定的浏览器 Cookie 库；Safari 仍受 macOS 权限保护。历史和清单不保存 Cookie 内容。Mac App Store profile 不提供这些登录及第三方站点下载功能。"))

                    policySection(String(localized: "你的控制权"), String(localized: "你可以在设置中断开 Spotify 并删除本地凭据，也可以删除应用支持目录中的历史和缓存文件。删除你选择的输出目录或本地音频原件不会由 Sooogood Video Catch 自动执行；应用不移动、重命名或删除原始媒体。"))

                    Text("这份应用内说明不能替代 App Store Connect 所需的公网隐私政策网址。发布前请在商店元数据和支持页面提供与你的法律主体、地区和联系方式一致的正式政策。")
                        .font(.caption)
                        .foregroundStyle(MediaFetchTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 820)
                .padding(34)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
    }

    private func policySection(_ title: String, _ text: String) -> some View {
        MediaFetchPanel {
            VStack(alignment: .leading, spacing: 9) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(MediaFetchTheme.primaryText)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(MediaFetchTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
