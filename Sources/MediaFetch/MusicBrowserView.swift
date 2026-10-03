#if !MEDIAFETCH_STORE_PROFILE
import AppKit
import SwiftUI
import WebKit
import MediaFetchCore

/// Browse NetEase Cloud Music / QQ Music inside the app with the same WebKit
/// session as in-app login, and send the current page to the music downloader.
/// Replaces cross-platform search without any unofficial search API.
@MainActor
final class MusicBrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var platform: StreamingPlatform
    @Published private(set) var currentURL: URL?
    @Published private(set) var title = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published var message: String?

    private(set) var webViews: [StreamingPlatform: WKWebView] = [:]
    private var observations: [NSKeyValueObservation] = []
    private let logins: StreamingSiteLoginStore
    /// Tests inject a throwaway store so they never touch real sessions.
    private let dataStoreProvider: (StreamingPlatform) -> WKWebsiteDataStore

    static let platforms: [StreamingPlatform] = [.netease, .qqmusic]

    init(logins: StreamingSiteLoginStore, platform: StreamingPlatform = .netease,
         dataStoreProvider: ((StreamingPlatform) -> WKWebsiteDataStore)? = nil) {
        self.logins = logins
        self.platform = platform
        self.dataStoreProvider = dataStoreProvider ?? { logins.session(for: $0).dataStore }
        super.init()
    }

    var musicLink: MusicLink? { currentURL.flatMap(MusicLink.parse) }

    /// One web view per platform, sharing that platform's in-app login store.
    func webView(for platform: StreamingPlatform) -> WKWebView {
        if let existing = webViews[platform] { return existing }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStoreProvider(platform)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        webViews[platform] = view
        if let home = platform.browserLoginURL { view.load(URLRequest(url: home)) }
        return view
    }

    func activate(_ platform: StreamingPlatform) {
        self.platform = platform
        let view = webView(for: platform)
        observations = [
            view.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in Task { @MainActor in self?.currentURL = view.url } },
            view.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in Task { @MainActor in self?.title = view.title ?? "" } },
            view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in Task { @MainActor in self?.canGoBack = view.canGoBack } },
            view.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in Task { @MainActor in self?.canGoForward = view.canGoForward } },
            view.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in Task { @MainActor in self?.isLoading = view.isLoading } }
        ]
    }

    var activeWebView: WKWebView { webView(for: platform) }

    func goHome() {
        if let home = platform.browserLoginURL { activeWebView.load(URLRequest(url: home)) }
    }

    // MARK: Session

    var hasSession: Bool { logins.session(for: platform).hasCookies }
    var sessionInUse: Bool { logins.isEnabled(for: platform) && logins.method(for: platform) == .inApp }

    /// Downloads use this browser's login (the in-app session) from now on.
    func useThisSessionForDownloads() {
        logins.setMethod(.inApp, for: platform)
        logins.setEnabled(true, for: platform)
    }

    func refreshSession() async { await logins.session(for: platform).refreshSession() }

    // MARK: Navigation policy

    nonisolated static func isAllowedHost(_ host: String, for platform: StreamingPlatform) -> Bool {
        let allowed: [String]
        switch platform {
        case .netease: allowed = ["music.163.com", "163.com", "126.net", "127.net", "netease.com"]
        case .qqmusic: allowed = ["qq.com", "gtimg.cn", "qpic.cn", "tencentmusic.com", "weixin.qq.com"]
        default: allowed = []
        }
        return allowed.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" { decisionHandler(.allow); return }
        let host = url.host?.lowercased() ?? ""
        let isMainFrame = navigationAction.targetFrame?.isMainFrame != false
        guard isMainFrame else { decisionHandler(.allow); return }
        // Upgrade plain-http pages on the platform (NetEase still links some).
        if url.scheme == "http", Self.isAllowedHost(host, for: platform), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = "https"
            if let secure = components.url { webView.load(URLRequest(url: secure)) }
            decisionHandler(.cancel); return
        }
        guard url.scheme == "https", Self.isAllowedHost(host, for: platform) else {
            // Anything else opens in the user's browser, never inside the app.
            if url.scheme == "https" || url.scheme == "http" { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel); return
        }
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await refreshSession() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let code = (error as NSError).code
        if code != NSURLErrorCancelled { message = error.localizedDescription }
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        if webView.superview !== nsView {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            attach(to: nsView)
        }
    }
    private func attach(to container: NSView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}

struct MusicBrowserView: View {
    @StateObject private var model: MusicBrowserModel
    let onBack: () -> Void
    let download: (URL) -> Void

    init(logins: StreamingSiteLoginStore, platform: StreamingPlatform = .netease, onBack: @escaping () -> Void, download: @escaping (URL) -> Void) {
        _model = StateObject(wrappedValue: MusicBrowserModel(logins: logins, platform: platform))
        self.onBack = onBack
        self.download = download
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            WebViewHost(webView: model.activeWebView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MediaFetchTheme.background)
        .onAppear { model.activate(model.platform) }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PageBackButton(action: onBack)
                Picker("平台", selection: Binding(get: { model.platform }, set: { model.activate($0) })) {
                    ForEach(MusicBrowserModel.platforms, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Button { model.activeWebView.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!model.canGoBack)
                Button { model.activeWebView.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!model.canGoForward)
                Button { model.activeWebView.reload() } label: { Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise") }
                Button { model.goHome() } label: { Image(systemName: "house") }
                Text(model.currentURL?.absoluteString ?? "")
                    .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(MediaFetchTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let link = model.musicLink {
                    Text(Self.kindName(link.kind)).font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(MediaFetchTheme.success.opacity(0.18), in: Capsule())
                }
                Button {
                    if let link = model.musicLink { download(link.canonicalURL) }
                } label: {
                    Label("下载当前页面", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.89, green: 0.16, blue: 0.19))
                .disabled(model.musicLink == nil)
                .help("打开单曲、专辑、歌单、歌手或排行榜页面后可用")
            }
            HStack(spacing: 10) {
                if model.hasSession {
                    if model.sessionInUse {
                        Label("已登录 · 下载会使用此登录", systemImage: "checkmark.seal.fill").foregroundStyle(MediaFetchTheme.success)
                    } else {
                        Label("已在此登录", systemImage: "person.crop.circle.badge.checkmark").foregroundStyle(MediaFetchTheme.secondaryText)
                        Button("下载时使用此登录") { model.useThisSessionForDownloads() }.buttonStyle(.link)
                    }
                } else {
                    Label("未登录 · 在网页右上角登录（扫码），网易云会员可下载无损，QQ 音乐需登录才能下载", systemImage: "person.crop.circle.badge.questionmark")
                        .foregroundStyle(MediaFetchTheme.secondaryText)
                }
                if let message = model.message { Text(message).foregroundStyle(MediaFetchTheme.warning).lineLimit(1) }
                Spacer()
            }
            .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    static func kindName(_ kind: MusicLink.Kind) -> String {
        switch kind {
        case .song: return String(localized: "单曲")
        case .album: return String(localized: "专辑")
        case .playlist: return String(localized: "歌单")
        case .artist: return String(localized: "歌手")
        case .toplist: return String(localized: "排行榜")
        case .radio: return String(localized: "电台")
        case .program: return String(localized: "节目")
        case .mv: return "MV"
        }
    }
}
#endif
