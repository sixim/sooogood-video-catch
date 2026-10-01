import Foundation

/// Converts only this platform's cookies to the format understood by yt-dlp.
/// Never serialize identity-provider cookies into a media download session.
public enum SiteSessionCookies {
    public static func domains(for platform: StreamingPlatform) -> [String] {
        switch platform {
        case .vimeo: return ["vimeo.com"]
        case .youtube: return ["youtube.com"]
        case .bilibili: return ["bilibili.com", "bilibili.tv"]
        case .youku: return ["youku.com"]
        case .udemy: return ["udemy.com"]
        case .netease: return ["music.163.com"]
        // QQ Music keeps its login on the whole qq.com domain, next to the QQ
        // account's own identity cookies, so only the names below are exported.
        case .qqmusic: return ["qq.com"]
        default: return []
        }
    }

    /// Cookie-name allowlist for platforms whose session shares a domain with
    /// an identity provider. nil means every cookie of the platform domains.
    /// QQ: yt-dlp reads `uin`, `qqmusic_key`, `fqm_pvqid` (qqmusic.py); the rest
    /// are the companion music-session cookies the y.qq.com web player sets.
    public static func allowedNames(for platform: StreamingPlatform) -> Set<String>? {
        switch platform {
        case .qqmusic:
            return ["uin", "euin", "qqmusic_key", "qm_keyst", "fqm_pvqid", "fqm_sessionid", "login_type",
                    "tmeLoginType", "wxuin", "wxopenid", "wxunionid", "psrf_qqopenid", "psrf_qqunionid",
                    "psrf_qqaccess_token", "psrf_qqrefresh_token", "psrf_access_token_expiresAt",
                    "psrf_musickey_createtime", "music_ignore_pskey"]
        default:
            return nil
        }
    }

    public static func export(_ cookies: [HTTPCookie], for platform: StreamingPlatform, now: Date = Date()) -> Data? {
        let lines = cookies.compactMap { cookie -> String? in
            let domain = cookie.domain.lowercased()
            let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            guard domains(for: platform).contains(where: { host == $0 || host.hasSuffix("." + $0) }),
                  allowedNames(for: platform).map({ $0.contains(cookie.name) }) ?? true,
                  cookie.expiresDate.map({ $0 > now }) ?? true,
                  !cookie.value.isEmpty else { return nil }
            let fields = [domain, cookie.path, cookie.name, cookie.value]
            guard fields.allSatisfy({ !$0.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" }) }) else { return nil }
            let prefix = cookie.isHTTPOnly ? "#HttpOnly_" : ""
            let expiry = cookie.expiresDate.map { String(Int64($0.timeIntervalSince1970)) } ?? "0"
            return [prefix + domain, domain.hasPrefix(".") ? "TRUE" : "FALSE",
                    cookie.path, cookie.isSecure ? "TRUE" : "FALSE", expiry,
                    cookie.name, cookie.value].joined(separator: "\t")
        }
        guard !lines.isEmpty else { return nil }
        return Data(("# Netscape HTTP Cookie File\n" + lines.joined(separator: "\n") + "\n").utf8)
    }
}
