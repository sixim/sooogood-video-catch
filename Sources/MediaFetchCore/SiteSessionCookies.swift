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
        default: return []
        }
    }

    public static func export(_ cookies: [HTTPCookie], for platform: StreamingPlatform, now: Date = Date()) -> Data? {
        let lines = cookies.compactMap { cookie -> String? in
            let domain = cookie.domain.lowercased()
            let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            guard domains(for: platform).contains(where: { host == $0 || host.hasSuffix("." + $0) }),
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
