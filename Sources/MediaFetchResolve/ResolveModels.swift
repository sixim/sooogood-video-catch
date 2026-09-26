import Foundation
import MediaFetchCore

// DaVinci Resolve integration is Local-profile only.
#if !MEDIAFETCH_STORE_PROFILE
/// One media file to place in the Media Pool, with provenance metadata.
public struct ResolveClipSpec: Codable, Equatable, Sendable {
    public var path: String
    /// Resolve's built-in clip metadata fields (e.g. Comments, Description, Keywords).
    public var metadata: [String: String]
    /// Free-form keys shown under Third Party metadata (e.g. SHA-256).
    public var thirdParty: [String: String]
    /// Optional proxy file linked with `LinkProxyMedia`.
    public var proxy: String?

    public init(path: String, metadata: [String: String] = [:], thirdParty: [String: String] = [:], proxy: String? = nil) {
        self.path = path
        self.metadata = metadata
        self.thirdParty = thirdParty
        self.proxy = proxy
    }
}

public struct ResolveImportRequest: Codable, Equatable, Sendable {
    public var op = "import"
    /// Media Pool bin path under the root, created as needed.
    public var binPath: [String]
    public var clips: [ResolveClipSpec]
    public var subtitles: [String]
    /// When set, a timeline with this name is created from the imported clips.
    public var timelineName: String?

    public init(binPath: [String], clips: [ResolveClipSpec], subtitles: [String] = [], timelineName: String? = nil) {
        self.binPath = binPath
        self.clips = clips
        self.subtitles = subtitles
        self.timelineName = timelineName
    }

    public var isEmpty: Bool { clips.isEmpty && subtitles.isEmpty }
}

public struct ResolveImportedClip: Codable, Equatable, Sendable {
    public let path: String
    public let name: String
    public let reused: Bool
    public let metadataFailures: [String]
    public let proxyLinked: Bool?
}

public struct ResolveImportResult: Codable, Equatable, Sendable {
    public let product: String
    public let version: String
    public let project: String
    public let bin: [String]
    public let clips: [ResolveImportedClip]
    public let subtitles: [String]
    public let failed: [String]
    public let timeline: String?
}

public struct ResolveStatus: Codable, Equatable, Sendable {
    public let product: String
    public let version: String
    public let project: String?

    public var isStudio: Bool { product.localizedCaseInsensitiveContains("studio") }
}

public enum ResolveBridgeError: LocalizedError, Equatable {
    case notInstalled
    case pythonMissing
    case notRunning
    case notConnected
    case noProject
    case scriptModuleMissing(String)
    case binFailed(String)
    case timedOut
    case bridgeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: return "没有找到 DaVinci Resolve（/Applications/DaVinci Resolve）"
        case .pythonMissing: return "没有找到可用的 Python 3，请执行 brew install python"
        case .notRunning: return "DaVinci Resolve 没有运行，请先打开达芬奇并载入一个项目"
        case .notConnected:
            return "无法连接达芬奇脚本接口。请在达芬奇「偏好设置 › 系统 › 常规 › 外部脚本使用」中选择「本地」，然后重启达芬奇。外部脚本需要 DaVinci Resolve Studio。"
        case .noProject: return "达芬奇里没有打开的项目，请先打开或新建一个项目"
        case .scriptModuleMissing(let detail): return "达芬奇脚本模块无法加载：\(detail)"
        case .binFailed(let name): return "无法在媒体池中创建媒体夹「\(name)」"
        case .timedOut: return "达芬奇在规定时间内没有响应"
        case .bridgeFailed(let detail): return "发送到达芬奇失败：\(detail)"
        }
    }

    /// Whether offering "打开达芬奇" would help.
    public var suggestsLaunching: Bool { self == .notRunning }
}
#endif
