import AppKit
import Combine
import MediaFetchCore

/// Preferences contain no secrets. InAppSiteSession owns platform-isolated
/// WebKit credentials; the engine receives an explicitly enabled session only.
@MainActor
final class StreamingSiteLoginStore: ObservableObject {
    static let defaultsKey = "MediaFetch.streamingSiteLogins.v1"

    @Published private(set) var configurations: [StreamingSiteLoginConfiguration]
#if !MEDIAFETCH_STORE_PROFILE
    @Published var requestedLogin: StreamingPlatform?
    private var sessions: [StreamingPlatform: InAppSiteSession] = [:]

    func session(for platform: StreamingPlatform) -> InAppSiteSession {
        if let session = sessions[platform] { return session }
        let session = InAppSiteSession(platform: platform)
        sessions[platform] = session
        return session
    }

    func beginInAppLogin(for platform: StreamingPlatform) {
        guard StreamingPlatform.browserLoginPlatforms.contains(platform) else { return }
        requestedLogin = platform
    }

    func exportSession(for url: URL) async throws -> Data {
        let platform = StreamingPlatform.detect(url)
        guard isEnabled(for: platform), method(for: platform) == .inApp else {
            throw InAppSiteSession.SessionError.empty
        }
        return try await session(for: platform).exportCookies()
    }

    func clearSession(for platform: StreamingPlatform) async {
        setEnabled(false, for: platform)
        await session(for: platform).clear()
    }
#endif

    private let defaults: UserDefaults
    private let fallbackBrowser: BrowserCookieSource

    init(
        defaults: UserDefaults = .standard,
        fallbackBrowser: BrowserCookieSource = .recommendedDefault
    ) {
        self.defaults = defaults
        self.fallbackBrowser = fallbackBrowser

        var savedByPlatform: [StreamingPlatform: StreamingSiteLoginConfiguration] = [:]
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([StreamingSiteLoginConfiguration].self, from: data) {
            for configuration in saved where StreamingPlatform.browserLoginPlatforms.contains(configuration.platform) {
                savedByPlatform[configuration.platform] = configuration
            }
        }

        configurations = StreamingPlatform.browserLoginPlatforms.map { platform in
            savedByPlatform[platform] ?? StreamingSiteLoginConfiguration(
                platform: platform,
                browser: fallbackBrowser
            )
        }
    }

    var enabledCount: Int {
        configurations.filter(\.isEnabled).count
    }

    func configuration(for platform: StreamingPlatform) -> StreamingSiteLoginConfiguration? {
        configurations.first { $0.platform == platform }
    }

    func browser(for platform: StreamingPlatform) -> BrowserCookieSource {
        configuration(for: platform)?.browser ?? fallbackBrowser
    }

    func isEnabled(for platform: StreamingPlatform) -> Bool {
        configuration(for: platform)?.isEnabled == true
    }

    func cookieSource(for platform: StreamingPlatform) -> BrowserCookieSource? {
        guard isEnabled(for: platform), method(for: platform) == .browser else { return nil }
        return browser(for: platform)
    }

    /// Which session a download of `url` should use: a browser's cookies, the
    /// in-app WebKit session, or none. Single source for every entry point.
    func routing(for url: URL) -> (cookieSource: BrowserCookieSource?, inApp: Bool) {
        let platform = StreamingPlatform.detect(url)
        guard StreamingPlatform.browserLoginPlatforms.contains(platform), isEnabled(for: platform) else { return (nil, false) }
        if method(for: platform) == .inApp { return (nil, true) }
        return (cookieSource(for: platform), false)
    }

    func method(for platform: StreamingPlatform) -> SiteLoginMethod {
        configuration(for: platform)?.resolvedMethod ?? .inApp
    }

    func setMethod(_ method: SiteLoginMethod, for platform: StreamingPlatform) {
        update(platform) { $0.loginMethod = method }
    }

    func setEnabled(_ isEnabled: Bool, for platform: StreamingPlatform) {
        update(platform) { $0.isEnabled = isEnabled }
    }

    func setBrowser(_ browser: BrowserCookieSource, for platform: StreamingPlatform) {
        update(platform) { $0.browser = browser }
    }

    func isBrowserInstalled(_ browser: BrowserCookieSource) -> Bool {
        browserApplicationURL(for: browser) != nil
    }

    /// Opens the platform's official login page in the same browser whose
    /// cookies will later be used. Never silently switch to a different browser.
    @discardableResult
    func openLoginPage(for platform: StreamingPlatform) -> Bool {
        guard let loginURL = platform.browserLoginURL else { return false }
        let browser = browser(for: platform)
        guard let applicationURL = browserApplicationURL(for: browser) else {
            return false
        }

        NSWorkspace.shared.open(
            [loginURL],
            withApplicationAt: applicationURL,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
        return true
    }

    private func update(
        _ platform: StreamingPlatform,
        mutation: (inout StreamingSiteLoginConfiguration) -> Void
    ) {
        guard let index = configurations.firstIndex(where: { $0.platform == platform }) else { return }
        var updated = configurations
        mutation(&updated[index])
        configurations = updated
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(configurations) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private func browserApplicationURL(for browser: BrowserCookieSource) -> URL? {
        let candidates: [String]
        switch browser {
        case .safari:
            candidates = ["/System/Applications/Safari.app", "/Applications/Safari.app"]
        case .chrome:
            candidates = ["/Applications/Google Chrome.app"]
        case .firefox:
            candidates = ["/Applications/Firefox.app"]
        }
        return candidates
            .first(where: FileManager.default.fileExists(atPath:))
            .map(URL.init(fileURLWithPath:))
    }
}
