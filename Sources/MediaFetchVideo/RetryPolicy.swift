import Foundation
import MediaFetchCore

/// Mutable per-job engine tuning carried across attempts. Only `attempt` and
/// `youtubePlayerClient` are persisted (for the manifest); the rest lives for
/// the current app session.
public struct EngineAttemptState: Equatable, Sendable {
    public var attempt: Int = 1
    public var youtubePlayerClient: String?
    public var forceIPv4 = false
    public var subtitlesEnabled = true

    public init() {}
}

public struct RetryDecision: Equatable, Sendable {
    public let delaySeconds: Int
    public let nextState: EngineAttemptState
    public let reason: String
    /// True when the platform rate-limited media/metadata (not just subtitles);
    /// the caller slows the rest of the session down.
    public let countsAsRateLimit: Bool
}

/// Decides whether a failed yt-dlp run is worth another attempt and how the
/// next attempt should differ. Pure so it can be tested with captured stderr.
public enum RetryPolicy {
    public static let maxAttempts = 3

    /// Fallback `player_client` lists for YouTube, tried in order. Lists are
    /// additive ("default,<extra>") so the best default formats stay available
    /// and the extra client only fills gaps; the last entry drops `default` for
    /// when the default clients themselves are broken.
    ///
    /// Measured against yt-dlp 2026.08.19 on 2026-09-25: single clients `ios`,
    /// `web_safari` returned no formats and `tv`/`tv_downgraded` failed, while
    /// `mweb` and `android` still served formats. Re-measure when upgrading.
    public static let youtubeClientCascade = ["default,mweb", "default,android", "mweb,android"]

    public static func next(
        after output: String,
        state: EngineAttemptState,
        isYouTube: Bool,
        sessionRateLimitCount: Int = 0
    ) -> RetryDecision? {
        guard state.attempt < maxAttempts else { return nil }
        let s = output.lowercased()
        // "No formats" right after we overrode the client is our doing, not the video's.
        let causedByClientOverride = state.youtubePlayerClient != nil && s.contains("no video formats found")
        if EngineDiagnostics.isTerminal(output) && !causedByClientOverride { return nil }
        if EngineErrorClassifier.isAuthenticationRequiredError(output) { return nil }
        if containsNoSpace(s) { return nil }

        var next = state
        next.attempt += 1
        let index = state.attempt - 1
        var reasons: [String] = []
        var delay = 2
        var countsAsRateLimit = false

        if s.contains("http error 429") {
            let onlySubtitles = output.components(separatedBy: .newlines).allSatisfy {
                let line = $0.lowercased()
                return !line.contains("429") || line.contains("subtitle")
            }
            next.subtitlesEnabled = false
            if onlySubtitles {
                delay = 3
                reasons.append("字幕请求被限流，本次不再下载字幕")
            } else {
                countsAsRateLimit = true
                delay = 10 * (1 << index) + (index * 7 + sessionRateLimitCount) % 5
                reasons.append("平台限流（429），等待 \(delay) 秒")
                if isYouTube { next.youtubePlayerClient = cascadeClient(index) }
            }
        }
        if isYouTube && (s.contains("sabr") || s.contains("not a bot") || causedByClientOverride) {
            next.youtubePlayerClient = cascadeClient(index)
            reasons.append(s.contains("sabr")
                ? "YouTube 仅提供 SABR 流，改用 \(next.youtubePlayerClient!) 客户端"
                : "YouTube 要求人机验证，改用 \(next.youtubePlayerClient!) 客户端")
        } else if isYouTube && s.contains("nsig") && !s.contains("http error 429") {
            next.youtubePlayerClient = cascadeClient(index)
            reasons.append("签名解析失败，改用 \(next.youtubePlayerClient!) 客户端")
        }
        if (s.contains("http error 403") || s.contains("forbidden")) && !state.forceIPv4 {
            next.forceIPv4 = true
            reasons.append("403 拒绝访问，改用 IPv4 重试")
        }
        if s.contains("subtitle") && !s.contains("http error 429") && state.subtitlesEnabled {
            next.subtitlesEnabled = false
            reasons.append("字幕下载失败，本次跳过字幕")
        }
        if reasons.isEmpty {
            // Unknown transient failure: one more plain attempt with backoff.
            delay = 5 * state.attempt
            reasons.append("下载引擎返回错误，\(delay) 秒后重试")
        }
        return RetryDecision(delaySeconds: delay, nextState: next, reason: reasons.joined(separator: "；"), countsAsRateLimit: countsAsRateLimit)
    }

    private static func cascadeClient(_ index: Int) -> String {
        youtubeClientCascade[min(index, youtubeClientCascade.count - 1)]
    }

    private static func containsNoSpace(_ s: String) -> Bool {
        s.contains("no space left") || s.contains("errno 28")
    }
}
