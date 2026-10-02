import Foundation

/// What the user can do about a failed engine run. The UI turns each case into
/// exactly one button; a cause without an action is only a better error text.
public enum EngineRemedy: String, Codable, Sendable {
    case signIn
    case updateEngine
    case waitAndRetry
    case freeDiskSpace
    case installJSRuntime
    case none
}

public enum EngineFailureCause: String, Codable, Sendable {
    case botCheck
    case sabrOnly
    case rateLimited
    case diskFull
    case needsLogin
    case tlsFingerprint
    case extractorOutdated
    case drmProtected
    case unavailable
    case unsupportedURL
    case networkTimeout
}

public struct EngineDiagnosis: Codable, Equatable, Sendable {
    public let cause: EngineFailureCause
    public let remedy: EngineRemedy

    public init(cause: EngineFailureCause, remedy: EngineRemedy) {
        self.cause = cause
        self.remedy = remedy
    }

    public var title: String {
        switch cause {
        case .botCheck: return "YouTube 要求人机验证"
        case .sabrOnly: return "YouTube 只提供受限的 SABR 流"
        case .rateLimited: return "请求过于频繁（429）"
        case .diskFull: return "磁盘空间不足"
        case .needsLogin: return "需要登录才能访问"
        case .tlsFingerprint: return "网站拒绝了非浏览器连接"
        case .extractorOutdated: return "下载引擎的网站解析已过期"
        case .drmProtected: return "媒体受 DRM 保护"
        case .unavailable: return "媒体不存在、已删除或为私有"
        case .unsupportedURL: return "不支持的链接"
        case .networkTimeout: return "网络连接超时"
        }
    }

    public var actionTitle: String? {
        switch remedy {
        case .signIn: return "登录网站后重试"
        case .updateEngine: return "更新 yt-dlp"
        case .waitAndRetry: return "稍后重试"
        case .freeDiskSpace: return "查看磁盘空间"
        case .installJSRuntime: return "安装 deno"
        case .none: return nil
        }
    }

    public var guidance: String {
        switch cause {
        case .botCheck: return "登录 YouTube 账号（应用内登录或浏览器登录状态）通常可以通过验证；也可以稍后再试。"
        case .sabrOnly: return "已自动切换备用播放客户端重试；如果仍失败，请更新 yt-dlp。"
        case .rateLimited: return "平台暂时限制了请求频率，等待几分钟后再试，或减少同时下载的数量。"
        case .diskFull: return "目标磁盘剩余空间不足，请清理后重试，或改用其他保存位置。"
        case .needsLogin: return "该内容仅对已登录账号可见，请在设置中启用对应网站的登录方式。"
        case .tlsFingerprint: return "网站识别到非浏览器客户端。请确认 yt-dlp 为最新版本，或使用网站登录状态重试。"
        case .extractorOutdated: return "网站结构已变化，请在终端执行 brew upgrade yt-dlp 后重试。"
        case .drmProtected: return "Sooogood Video Catch 不会尝试绕过 DRM。"
        case .unavailable: return "请确认链接仍然有效，且当前账号有观看权限。"
        case .unsupportedURL: return "请检查链接是否完整，或该网站是否在 yt-dlp 支持列表内。"
        case .networkTimeout: return "请检查网络或代理设置后重试。"
        }
    }
}

/// Maps engine stderr to a named cause. Order matters: the most specific
/// signatures come first, because several of them also end in "403" or
/// "unavailable". Unknown output returns nil — a wrong diagnosis sends the
/// user after the wrong fix, which is worse than none.
public enum EngineDiagnostics {
    /// yt-dlp's QQ Music extractor only understands QQ-number sessions (`uin`);
    /// a WeChat login looks "logged out" to it. Users who are logged in with
    /// WeChat must be told that instead of a bare "needs login".
    public static let qqMusicLoginHint = "QQ 音乐目前只支持 QQ 号登录，暂不支持微信登录（下载引擎的限制）。用微信登录的话，建议改用网易云音乐下载；有 QQ 号可以用手机 QQ 扫码登录后重试。"

    /// Platform-specific replacement for a diagnosis, when the generic text would mislead.
    public static func platformHint(for diagnosis: EngineDiagnosis?, platform: StreamingPlatform) -> String? {
        guard platform == .qqmusic, diagnosis?.cause == .needsLogin else { return nil }
        return qqMusicLoginHint
    }

    public static func diagnose(_ output: String) -> EngineDiagnosis? {
        let s = output.lowercased()
        if EngineErrorClassifier.isDRMError(output) {
            return .init(cause: .drmProtected, remedy: .none)
        }
        if containsAny(s, [
            "confirm you're not a bot", "confirm you’re not a bot", "po token is required",
            "a po token is required", "po token is missing", "missing a po token"
        ]) {
            return .init(cause: .botCheck, remedy: .signIn)
        }
        if s.contains("sabr") { return .init(cause: .sabrOnly, remedy: .updateEngine) }
        if s.contains("http error 429") || s.contains("too many requests") {
            return .init(cause: .rateLimited, remedy: .waitAndRetry)
        }
        if containsAny(s, ["no space left", "disk full", "errno 28"]) {
            return .init(cause: .diskFull, remedy: .freeDiskSpace)
        }
        if EngineErrorClassifier.isAuthenticationRequiredError(output) || containsAny(s, [
            "members-only", "available to this channel's members", "requires purchase",
            "need to purchase", "purchase the course", "only available for registered users",
            "use --cookies", "sign in if you've been granted access"
        ]) {
            return .init(cause: .needsLogin, remedy: .signIn)
        }
        if containsAny(s, [
            "sslv3_alert_handshake_failure", "unable to handshake", "just a moment...",
            "enable javascript and cookies to continue", "cloudflare anti-bot"
        ]) {
            return .init(cause: .tlsFingerprint, remedy: .updateEngine)
        }
        if containsAny(s, [
            "no supported javascript runtime", "js runtime", "javascript runtime could not be found"
        ]) {
            return .init(cause: .extractorOutdated, remedy: .installJSRuntime)
        }
        if containsAny(s, [
            "nsig extraction failed", "unable to extract", "please report this issue",
            "confirm you are on the latest version"
        ]) {
            return .init(cause: .extractorOutdated, remedy: .updateEngine)
        }
        if isTerminal(output) {
            if containsAny(s, ["unsupported url", "is not a valid url"]) {
                return .init(cause: .unsupportedURL, remedy: .none)
            }
            return .init(cause: .unavailable, remedy: .none)
        }
        if containsAny(s, ["timed out", "timeout"]) {
            return .init(cause: .networkTimeout, remedy: .waitAndRetry)
        }
        return nil
    }

    /// True when retrying cannot change the outcome. Rate limiting is never
    /// terminal even when the same output mentions a missing video.
    public static func isTerminal(_ output: String) -> Bool {
        let s = output.lowercased()
        if s.contains("http error 429") { return false }
        if EngineErrorClassifier.isDRMError(output) { return true }
        return containsAny(s, [
            "video unavailable", "this video is not available", "video has been removed",
            "has been removed by the uploader", "private video", "video is private",
            "no video formats found", "unsupported url", "is not a valid url",
            "http error 404", "http error 410", "the downloaded file is empty"
        ])
    }

    /// One-off failures worth an immediate silent retry for short read-only
    /// calls (inspect / expand). The first is yt-dlp's qqmusic extractor
    /// running a regex on `False` when the page fetch hiccups.
    public static func isTransientGlitch(_ output: String) -> Bool {
        let s = output.lowercased()
        return ["expected string or bytes-like object", "timed out", "connection reset", "temporary failure in name resolution",
                "http error 500", "http error 502", "http error 503", "http error 504", "remote end closed connection"]
            .contains { s.contains($0) }
    }

    /// The most informative single line of engine output, for compact UI.
    public static func lastErrorLine(in output: String) -> String {
        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let line = lines.last(where: { $0.uppercased().hasPrefix("ERROR") }) ?? lines.last ?? ""
        return String(line.prefix(400))
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
