import Foundation

/// Checks a batch before downloading anything, so "12 of 80 failed overnight"
/// becomes a decision the user makes up front. The decision is pure; collecting
/// metadata and free space is done by the caller.
public enum BatchPreflight {
    public enum Problem: String, Codable, Sendable {
        case unsupported
        case needsLogin
        case unavailable
        case blocked
        case alreadyDownloaded
        case engineError

        public var displayName: String {
            switch self {
            case .unsupported: return String(localized: "不支持的链接")
            case .needsLogin: return String(localized: "需要登录")
            case .unavailable: return String(localized: "不存在或已删除")
            case .blocked: return String(localized: "受保护平台")
            case .alreadyDownloaded: return String(localized: "已经下载过")
            case .engineError: return String(localized: "解析失败")
            }
        }

        /// Problems the user can fix before starting (e.g. by signing in).
        public var isActionable: Bool { self == .needsLogin }
    }

    public struct Item: Equatable, Sendable, Identifiable {
        public let url: String
        public var title: String?
        public var estimatedBytes: Int64?
        public var problem: Problem?
        public var detail: String?

        public var id: String { url }

        public init(url: String, title: String? = nil, estimatedBytes: Int64? = nil, problem: Problem? = nil, detail: String? = nil) {
            self.url = url
            self.title = title
            self.estimatedBytes = estimatedBytes
            self.problem = problem
            self.detail = detail
        }
    }

    public enum Verdict: String, Sendable {
        /// Everything resolved and fits on disk.
        case go
        /// Some items have problems; the rest can download.
        case goWithSkips
        /// Nothing usable, or the batch does not fit on disk.
        case stop
    }

    public struct Report: Equatable, Sendable {
        public let items: [Item]
        public let readyCount: Int
        public let estimatedBytes: Int64
        public let unknownSizeCount: Int
        public let availableBytes: Int64?
        public let fitsOnDisk: Bool
        public let verdict: Verdict

        public var problems: [Item] { items.filter { $0.problem != nil } }
        public var readyURLs: [String] { items.filter { $0.problem == nil }.map(\.url) }
    }

    /// Estimates are often low (variable bitrate); filling a disk to the last
    /// byte breaks the user's system, not just the download.
    public static let headroom = 1.10

    public static func evaluate(_ items: [Item], availableBytes: Int64?) -> Report {
        let ready = items.filter { $0.problem == nil }
        let bytes = ready.compactMap(\.estimatedBytes).reduce(0, +)
        let unknown = ready.filter { $0.estimatedBytes == nil }.count
        let fits = availableBytes.map { Double(bytes) * headroom <= Double($0) } ?? true
        let verdict: Verdict
        if ready.isEmpty || !fits {
            verdict = .stop
        } else if ready.count < items.count {
            verdict = .goWithSkips
        } else {
            verdict = .go
        }
        return Report(items: items, readyCount: ready.count, estimatedBytes: bytes, unknownSizeCount: unknown,
                      availableBytes: availableBytes, fitsOnDisk: fits, verdict: verdict)
    }

    /// Maps an engine failure to a preflight problem.
    public static func problem(forEngineOutput output: String) -> Problem {
        guard let diagnosis = EngineDiagnostics.diagnose(output) else { return .engineError }
        switch diagnosis.cause {
        case .needsLogin, .botCheck: return .needsLogin
        case .unavailable: return .unavailable
        case .unsupportedURL: return .unsupported
        case .drmProtected: return .blocked
        default: return .engineError
        }
    }

    public static func availableBytes(at directory: URL) -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
