import Foundation

/// yt-dlp versions are `YYYY.MM.DD` with an optional `.N` / `-nightly` suffix.
public struct EngineVersion: Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init?(_ raw: String) {
        guard let head = raw.split(whereSeparator: \.isWhitespace).first else { return nil }
        let core = head.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? head
        let parts = core.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 3, parts[0] >= 2000, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else {
            return nil
        }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    /// Floor for yt-dlp. 2026.06.09 is the release that, per upstream notes
    /// referenced by other downloaders, fixed cookie leakage in the curl
    /// downloader and aria2c manifest execution issues.
    public static let minimumSupported = EngineVersion(year: 2026, month: 6, day: 9)
    /// Extractors go stale quickly; suggest an upgrade after this many days.
    public static let staleAfterDays = 30

    public var description: String { String(format: "%04d.%02d.%02d", year, month, day) }

    public var date: Date? {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = year
        components.month = month
        components.day = day
        return components.date
    }

    public static func < (lhs: EngineVersion, rhs: EngineVersion) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

public enum EngineHealthStatus: Equatable, Sendable {
    case missing
    case unreadable
    case belowMinimum(EngineVersion)
    case stale(EngineVersion, days: Int)
    case current(EngineVersion)

    public static func evaluate(versionOutput: String?, now: Date = Date()) -> EngineHealthStatus {
        guard let versionOutput else { return .missing }
        guard let version = EngineVersion(versionOutput) else { return .unreadable }
        if version < .minimumSupported { return .belowMinimum(version) }
        if let date = version.date {
            let days = Int(now.timeIntervalSince(date) / 86_400)
            if days > EngineVersion.staleAfterDays { return .stale(version, days: days) }
        }
        return .current(version)
    }

    public var needsAttention: Bool {
        switch self {
        case .current: return false
        default: return true
        }
    }

    public var summary: String {
        switch self {
        case .missing: return String(localized: "未安装 yt-dlp，请执行 brew install yt-dlp")
        case .unreadable: return String(localized: "无法读取 yt-dlp 版本")
        case .belowMinimum(let v): return String(localized: "yt-dlp \(v) 低于最低安全版本 \(EngineVersion.minimumSupported)，请执行 brew upgrade yt-dlp")
        case .stale(let v, let days): return String(localized: "yt-dlp \(v) 已发布 \(days) 天，建议执行 brew upgrade yt-dlp")
        case .current(let v): return "yt-dlp \(v)"
        }
    }
}
