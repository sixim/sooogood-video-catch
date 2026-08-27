import Foundation

enum PlatformSupportLevel {
    case supported
    case loginRecommended
    case generic
    case drmBlocked
}

enum StreamingPlatform: String, CaseIterable, Identifiable {
    case youtube
    case vimeo
    case bilibili
    case youku
    case directStream
    case netflix
    case spotify
    case generic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .youtube: return "YouTube"
        case .vimeo: return "Vimeo"
        case .bilibili: return "哔哩哔哩"
        case .youku: return "优酷"
        case .directStream: return "HLS / DASH 直链"
        case .netflix: return "Netflix"
        case .spotify: return "Spotify"
        case .generic: return "通用网页媒体"
        }
    }

    var systemImage: String {
        switch self {
        case .youtube, .vimeo, .bilibili, .youku: return "play.rectangle.fill"
        case .directStream: return "waveform.path.ecg.rectangle"
        case .netflix, .spotify: return "lock.fill"
        case .generic: return "globe"
        }
    }

    var supportLevel: PlatformSupportLevel {
        switch self {
        case .youtube, .directStream: return .supported
        case .vimeo, .bilibili, .youku: return .loginRecommended
        case .netflix, .spotify: return .drmBlocked
        case .generic: return .generic
        }
    }

    var downloadAllowed: Bool { supportLevel != .drmBlocked }

    var loginHint: String? {
        switch self {
        case .vimeo: return "Vimeo 经常要求登录；私有或登录可见内容请启用浏览器登录状态。"
        case .bilibili: return "哔哩哔哩的高画质、番剧或账户内容可能需要登录。"
        case .youku: return "优酷的高画质、会员或地区限制内容可能需要登录。"
        default: return nil
        }
    }

    var restrictionMessage: String? {
        switch self {
        case .netflix:
            return "Netflix 正片使用 DRM 保护。MediaFetch 不绕过 DRM，也不会把网页预告片误报成正片下载。"
        case .spotify:
            return "Spotify 音乐曲目使用受保护的流，无法作为平台原始音频下载。MediaFetch 不会用 YouTube 替代音频冒充 Spotify 原文件。播客请使用发布者公开 RSS 或直接音频链接。"
        default:
            return nil
        }
    }

    static let featuredDownloadable: [StreamingPlatform] = [
        .youtube, .vimeo, .bilibili, .youku, .directStream, .generic
    ]

    static func detect(_ url: URL) -> StreamingPlatform {
        let host = url.host?.lowercased() ?? ""
        if matches(host, domains: ["youtube.com", "youtu.be", "youtube-nocookie.com"]) { return .youtube }
        if matches(host, domains: ["vimeo.com"]) { return .vimeo }
        if matches(host, domains: ["bilibili.com", "bilibili.tv", "biliintl.com", "b23.tv"]) { return .bilibili }
        if matches(host, domains: ["youku.com", "tudou.com"]) { return .youku }
        if matches(host, domains: ["netflix.com"]) { return .netflix }
        if matches(host, domains: ["spotify.com"]) { return .spotify }
        let extensionName = url.pathExtension.lowercased()
        if ["m3u8", "mpd", "m3u", "ism", "isml"].contains(extensionName) { return .directStream }
        return .generic
    }

    private static func matches(_ host: String, domains: [String]) -> Bool {
        domains.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}
