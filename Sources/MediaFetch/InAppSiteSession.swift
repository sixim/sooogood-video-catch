#if !MEDIAFETCH_STORE_PROFILE
import WebKit
import SwiftUI
import MediaFetchCore

/// Owns platform-isolated WebKit stores. No JavaScript is injected into login
/// forms and no password fields are observed by the application.
@MainActor
final class InAppSiteSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    let platform: StreamingPlatform
    let dataStore: WKWebsiteDataStore
    @Published var host = ""
    @Published var message: String?
    @Published var isLoading = false
    @Published var hasCookies = false
    @Published var isClearing = false
    @Published var providerBlocked = false
    private var generation = 0
    private(set) lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        return view
    }()

    init(platform: StreamingPlatform, dataStore: WKWebsiteDataStore? = nil) {
        self.platform = platform
        // Stable IDs are part of the local session storage contract.
        let suffix: String
        switch platform {
        case .youtube: suffix = "000000000001"
        case .vimeo: suffix = "000000000002"
        case .bilibili: suffix = "000000000003"
        case .youku: suffix = "000000000004"
        case .udemy: suffix = "000000000005"
        case .netease: suffix = "000000000006"
        case .qqmusic: suffix = "000000000007"
        default: preconditionFailure("Unsupported in-app login platform")
        }
        self.dataStore = dataStore ?? WKWebsiteDataStore(forIdentifier: UUID(uuidString: "EC3BB55D-5920-45DE-A438-" + suffix)!)
        super.init()
        self.dataStore.httpCookieStore.add(self)
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { await refreshSession() }
    }

    func open() {
        guard !isClearing else { return }
        if platform == .youtube {
            providerBlocked = true
            message = "YouTube 使用 Google 登录。Google 不允许在应用内嵌网页中完成账号登录；请使用下方兼容登录。"
            return
        }
        if webView.url == nil || webView.url?.absoluteString == "about:blank" { reloadLogin() }
        Task { await refreshSession() }
    }

    func reloadLogin() {
        guard !isClearing, platform != .youtube, let url = platform.browserLoginURL else { return }
        message = nil
        providerBlocked = false
        isLoading = true
        webView.load(URLRequest(url: url))
    }

    func refreshSession() async {
        let stamp = generation
        let cookies = await dataStore.httpCookieStore.allCookies()
        guard stamp == generation, !isClearing else { return }
        hasCookies = SiteSessionCookies.export(cookies, for: platform) != nil
    }

    func exportCookies() async throws -> Data {
        guard !isClearing else { throw SessionError.clearing }
        let stamp = generation
        let cookies = await dataStore.httpCookieStore.allCookies()
        guard stamp == generation, !isClearing else { throw SessionError.clearing }
        guard let data = SiteSessionCookies.export(cookies, for: platform) else { throw SessionError.empty }
        return data
    }

    func clear() async {
        guard !isClearing else { return }
        isClearing = true
        generation += 1
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        hasCookies = false
        isLoading = false
        isClearing = false
        message = "此网站在 \(MediaFetchRelease.displayName) 中的会话已清除。"
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        let host = url.host?.lowercased() ?? ""
        guard url.scheme == "https" else {
            message = "此登录窗口只打开 HTTPS 网页。"
            decisionHandler(.cancel); return
        }
        if host == "accounts.google.com" || host.hasSuffix(".accounts.google.com") {
            providerBlocked = true
            message = "Google 限制应用内嵌登录。可返回使用该网站的邮箱登录，或选择兼容登录。"
            isLoading = false
            decisionHandler(.cancel); return
        }
        if navigationAction.targetFrame?.isMainFrame != false {
            let allowed = SiteSessionCookies.domains(for: platform) + (platform == .youku ? ["taobao.com", "alipay.com", "aliyun.com"] : [])
            guard allowed.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
                message = "该网站要求转到另一登录服务（" + host + "）。可选择兼容登录继续。"
                decisionHandler(.cancel); return
            }
            self.host = host
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
                decisionHandler(.cancel); return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        Task { await refreshSession() }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showLoadError(error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showLoadError(error)
    }
    private func showLoadError(_ error: Error) {
        isLoading = false
        if (error as NSError).code != NSURLErrorCancelled {
            message = "登录页加载失败，请检查网络后重试，或选择兼容登录。"
        }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoading = false
        message = "登录网页已停止，请点击重新载入。"
    }

    enum SessionError: LocalizedError {
        case empty, clearing
        var errorDescription: String? {
            switch self {
            case .empty: return "尚无可用的应用内会话。请在网站登录窗口完成登录，再解析视频。"
            case .clearing: return "应用内登录会话正在清除，请重新登录后再试。"
            }
        }
    }
}

private struct SiteWebView: NSViewRepresentable {
    let session: InAppSiteSession
    func makeNSView(context: Context) -> WKWebView { session.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct InAppSiteLoginView: View {
    @ObservedObject var session: InAppSiteSession
    @ObservedObject var store: StreamingSiteLoginStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title).foregroundStyle(MediaFetchTheme.videoAccent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("登录 " + session.platform.displayName).font(.title3.bold())
                    Label(session.host.isEmpty ? "应用内独立会话" : session.host, systemImage: "lock")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if session.isLoading { ProgressView().controlSize(.small) }
                if session.platform != .youtube {
                    Button("重新载入", systemImage: "arrow.clockwise") { session.reloadLogin() }
                        .disabled(session.isClearing)
                }
                Button("关闭") { dismiss() }
            }
            .padding(20)
            Divider()
            if let message = session.message {
                InlineMessage(text: message, kind: .warning).padding(12)
            }
            if session.platform == .youtube {
                VStack(spacing: 18) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark").font(.system(size: 54))
                    Text("Google 登录需要受支持的浏览器").font(.title2.bold())
                    Text("应用内仍可管理 YouTube 的登录设置。\n完成兼容登录后，使用相同浏览器的登录状态解析视频。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Link("查看 Google 登录规则", destination: URL(string: "https://developers.google.com/identity/protocols/oauth2/policies")!)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SiteWebView(session: session).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.platform == .youtube ? "请使用兼容登录连接 Google 账号" : (session.hasCookies ? "检测到网站会话 · 登录有效性以视频解析结果为准" : "请在上方官网完成登录"))
                        .font(.caption)
                    Text("登录会话保存在本机，可随时清除。").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("兼容登录…") {
                    if store.openLoginPage(for: session.platform) {
                        store.setMethod(.browser, for: session.platform)
                        store.setEnabled(true, for: session.platform)
                        dismiss()
                    } else {
                        session.message = "没有找到所选浏览器，请关闭此窗口，在兼容登录设置中选择已安装的浏览器。"
                    }
                }
                if session.platform != .youtube {
                    Button("保存会话并返回") {
                        Task {
                            await session.refreshSession()
                            guard session.hasCookies else { return }
                            store.setMethod(.inApp, for: session.platform)
                            store.setEnabled(true, for: session.platform)
                            dismiss()
                        }
                    }.buttonStyle(.borderedProminent)
                        .disabled(!session.hasCookies || session.isClearing)
                }
            }.padding(18)
        }
        .background(MediaFetchTheme.background)
        .frame(minWidth: 760, idealWidth: 860, minHeight: 580, idealHeight: 700)
        .onAppear { session.open() }
    }
}
#endif
