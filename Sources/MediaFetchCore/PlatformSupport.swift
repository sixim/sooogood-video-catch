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
    case netease
    case qqmusic
    case directStream
    case netflix
    case spotify
    case generic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .youtube: return "YouTube"
        case .vimeo: return "Vimeo"
        case .bilibili: return String(localized: "哔哩哔哩")
        case .youku: return String(localized: "优酷")
        case .udemy: return "Udemy"
        case .netease: return String(localized: "网易云音乐")
        case .qqmusic: return String(localized: "QQ 音乐")
        case .directStream: return String(localized: "HLS / DASH 直链")
        case .netflix: return "Netflix"
        case .spotify: return "Spotify"
        case .generic: return String(localized: "通用网页媒体")
        }
    }

    public var systemImage: String {
        switch self {
        case .youtube, .vimeo, .bilibili, .youku: return "play.rectangle.fill"
        case .udemy: return "graduationcap.fill"
        case .netease, .qqmusic: return "music.note"
        case .directStream: return "waveform.path.ecg.rectangle"
        case .netflix: return "lock.fill"
        case .spotify: return "music.note"
        case .generic: return "globe"
        }
    }

    public var supportLevel: PlatformSupportLevel {
        switch self {
        case .youtube, .directStream: return .supported
        case .vimeo, .bilibili, .youku, .udemy, .netease, .qqmusic: return .loginRecommended
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
        case .vimeo: return String(localized: "Vimeo 经常要求登录；私有或登录可见内容请启用浏览器登录状态。")
        case .bilibili: return String(localized: "哔哩哔哩的高画质、番剧或账户内容可能需要登录。")
        case .youku: return String(localized: "优酷的高画质、会员或地区限制内容可能需要登录。")
        case .udemy: return String(localized: "Udemy 课程需要登录已购买课程的账号；受 DRM 保护的课时会被跳过。")
        case .netease: return String(localized: "未登录时最高 320k；登录会员账号后可获得平台提供的无损音质。")
        case .qqmusic: return String(localized: "QQ 音乐需要登录账号才能下载；音质取决于账号权益。")
        default: return nil
        }
    }

    public var restrictionMessage: String? {
        switch self {
        case .netflix:
            return String(localized: "Netflix 正片使用 DRM 保护。Sooogood Media Catch 不绕过 DRM，也不会把网页预告片误报成正片下载。")
        case .spotify:
            return String(localized: "Spotify 受保护音频不会进入视频下载引擎。请使用“音乐”页面，把 Spotify 曲目与自己拥有的本地或 DRM-free 音频进行匹配和整理。")
        default:
            return nil
        }
    }

    public static let featuredDownloadable: [StreamingPlatform] = [
        .youtube, .vimeo, .bilibili, .youku, .udemy, .netease, .qqmusic, .directStream, .generic
    ]

    /// Platforms whose authenticated web session can be reused by the local
    /// download profile. Credentials remain in the selected browser.
    public static let browserLoginPlatforms: [StreamingPlatform] = [
        .youtube, .vimeo, .bilibili, .youku, .udemy, .netease, .qqmusic
    ]

    /// yt-dlp extractor family, as recorded in package manifests (`netease:song` → `netease`).
    public var extractorFamily: String? {
        switch self {
        case .netease: return "netease"
        case .qqmusic: return "qqmusic"
        case .youtube: return "youtube"
        case .bilibili: return "bilibili"
        case .vimeo: return "vimeo"
        default: return nil
        }
    }

    /// Music services whose items are audio tracks rather than videos.
    public var isMusicService: Bool { self == .netease || self == .qqmusic }

    public var browserLoginURL: URL? {
        switch self {
        case .youtube: return URL(string: "https://www.youtube.com/")
        case .vimeo: return URL(string: "https://vimeo.com/log_in")
        case .bilibili: return URL(string: "https://passport.bilibili.com/login")
        case .youku: return URL(string: "https://account.youku.com/")
        case .udemy: return URL(string: "https://www.udemy.com/join/login-popup/")
        case .netease: return URL(string: "https://music.163.com/")
        case .qqmusic: return URL(string: "https://y.qq.com/")
        case .directStream, .netflix, .spotify, .generic: return nil
        }
    }

    public var browserLoginPurpose: String {
        switch self {
        case .youtube: return String(localized: "年龄限制、会员可见或高画质内容可能需要登录。")
        case .vimeo: return String(localized: "私有、未列出或登录可见的视频需要对应账号权限。")
        case .bilibili: return String(localized: "高画质、番剧及账户可见内容可能需要登录。")
        case .youku: return String(localized: "高画质、会员及地区限制内容可能需要登录。")
        case .udemy: return String(localized: "只能下载你已购买课程中没有 DRM 保护的课时，并会放慢请求节奏以免账号受限。")
        case .netease: return String(localized: "在官网右上角登录（扫码或手机号）；会员账号可获得无损音质。")
        case .qqmusic: return String(localized: "在官网右上角用 QQ 或微信扫码登录；未登录无法下载。")
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
        if matches(host, domains: ["music.163.com", "163cn.tv"]) { return .netease }
        if matches(host, domains: ["y.qq.com"]) { return .qqmusic }
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
