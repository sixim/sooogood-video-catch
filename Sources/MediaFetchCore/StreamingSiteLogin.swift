import Foundation

public enum SiteLoginMethod: String, Codable, Sendable {
    case inApp
    case browser
}

/// A persisted, non-secret preference that tells the local download engine
/// which session source to use for one streaming platform. Credential bytes
/// are never part of this model; nil method preserves legacy browser opt-ins.
public struct StreamingSiteLoginConfiguration: Codable, Equatable, Sendable, Identifiable {
    public let platform: StreamingPlatform
    public var browser: BrowserCookieSource
    public var isEnabled: Bool
    public var loginMethod: SiteLoginMethod?
    public var resolvedMethod: SiteLoginMethod { loginMethod ?? .browser }

    public var id: String { platform.rawValue }

    public init(
        platform: StreamingPlatform,
        browser: BrowserCookieSource,
        isEnabled: Bool = false,
        loginMethod: SiteLoginMethod = .inApp
    ) {
        self.platform = platform
        self.browser = browser
        self.isEnabled = isEnabled
        self.loginMethod = loginMethod
    }
}
