import Foundation

public enum PlatformSupportLevel {
    case supported
    case loginRecommended
    case generic
    case spotifyBridge
    case drmBlocked
}

public enum PlatformRoute: Equatable {
    case networkDownload
    case spotifyBridge
    case drmBlocked
}

public enum StreamingPlatform: String, CaseIterable, Identifiable, Codable, Sendable, Hashable {
    case youtube
    case vimeo
    case bilibili
    case youku
    case udemy
    case directStream
    case netflix
    case spotify
    case generic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .youtube: return "YouTube"
        case .vimeo: return "Vimeo"
        case .bilibili: return "哔哩哔哩"
        case .youku: return "优酷"
        case .udemy: return "Udemy"
        case .directStream: return "HLS / DASH 直链"
        case .netflix: return "Netflix"
        case .spotify: return "Spotify"
        case .generic: return "通用网页媒体"
        }
    }

    public var systemImage: String {
        switch self {
        case .youtube, .vimeo, .bilibili, .youku: return "play.rectangle.fill"
        case .udemy: return "graduationcap.fill"
        case .directStream: return "waveform.path.ecg.rectangle"
        case .netflix: return "lock.fill"
        case .spotify: return "music.note"
        case .generic: return "globe"
        }
    }

    public var supportLevel: PlatformSupportLevel {
        switch self {
        case .youtube, .directStream: return .supported
        case .vimeo, .bilibili, .youku, .udemy: return .loginRecommended
        case .netflix: return .drmBlocked
        case .spotify: return .spotifyBridge
        case .generic: return .generic
        }
    }

    public var route: PlatformRoute {
        switch self {
        case .spotify: return .spotifyBridge
        case .netflix: return .drmBlocked
        default: return .networkDownload
        }
    }

    public var downloadAllowed: Bool { route == .networkDownload }

    public var loginHint: String? {
        switch self {
        case .vimeo: return "Vimeo 经常要求登录；私有或登录可见内容请启用浏览器登录状态。"
        case .bilibili: return "哔哩哔哩的高画质、番剧或账户内容可能需要登录。"
        case .youku: return "优酷的高画质、会员或地区限制内容可能需要登录。"
        case .udemy: return "Udemy 课程需要登录已购买课程的账号；受 DRM 保护的课时会被跳过。"
        default: return nil
        }
    }

    public var restrictionMessage: String? {
        switch self {
        case .netflix:
            return "Netflix 正片使用 DRM 保护。Sooogood Video Catch 不绕过 DRM，也不会把网页预告片误报成正片下载。"
        case .spotify:
            return "Spotify 受保护音频不会进入视频下载引擎。请使用“音乐”页面，把 Spotify 曲目与自己拥有的本地或 DRM-free 音频进行匹配和整理。"
        default:
            return nil
        }
    }

    public static let featuredDownloadable: [StreamingPlatform] = [
        .youtube, .vimeo, .bilibili, .youku, .udemy, .directStream, .generic
    ]

    /// Platforms whose authenticated web session can be reused by the local
    /// download profile. Credentials remain in the selected browser.
    public static let browserLoginPlatforms: [StreamingPlatform] = [
        .youtube, .vimeo, .bilibili, .youku, .udemy
    ]

    public var browserLoginURL: URL? {
        switch self {
        case .youtube: return URL(string: "https://www.youtube.com/")
        case .vimeo: return URL(string: "https://vimeo.com/log_in")
        case .bilibili: return URL(string: "https://passport.bilibili.com/login")
        case .youku: return URL(string: "https://account.youku.com/")
        case .udemy: return URL(string: "https://www.udemy.com/join/login-popup/")
        case .directStream, .netflix, .spotify, .generic: return nil
        }
    }

    public var browserLoginPurpose: String {
        switch self {
        case .youtube: return "年龄限制、会员可见或高画质内容可能需要登录。"
        case .vimeo: return "私有、未列出或登录可见的视频需要对应账号权限。"
        case .bilibili: return "高画质、番剧及账户可见内容可能需要登录。"
        case .youku: return "高画质、会员及地区限制内容可能需要登录。"
        case .udemy: return "只能下载你已购买课程中没有 DRM 保护的课时，并会放慢请求节奏以免账号受限。"
        default: return ""
        }
    }

    public static func detect(_ url: URL) -> StreamingPlatform {
        let host = url.host?.lowercased() ?? ""
        if matches(host, domains: ["youtube.com", "youtu.be", "youtube-nocookie.com"]) { return .youtube }
        if matches(host, domains: ["vimeo.com"]) { return .vimeo }
        if matches(host, domains: ["bilibili.com", "bilibili.tv", "biliintl.com", "b23.tv"]) { return .bilibili }
        if matches(host, domains: ["youku.com", "tudou.com"]) { return .youku }
        if matches(host, domains: ["udemy.com"]) { return .udemy }
        if matches(host, domains: ["netflix.com"]) { return .netflix }
        if matches(host, domains: ["spotify.com", "spotify.link", "spotify.app.link"]) { return .spotify }
        let extensionName = url.pathExtension.lowercased()
        if ["m3u8", "mpd", "m3u", "ism", "isml"].contains(extensionName) { return .directStream }
        return .generic
    }

    private static func matches(_ host: String, domains: [String]) -> Bool {
        domains.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}
