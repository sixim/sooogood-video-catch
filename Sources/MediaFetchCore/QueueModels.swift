import Foundation

public enum DownloadJobStatus: String, Codable, Sendable {
    case queued
    case downloading
    case packaging
    case completed
    case failed
    case cancelled
    case paused
    /// Engine process is alive but stopped (SIGSTOP); resumes in place.
    case suspended
    /// Waiting for an automatic retry after a recoverable failure.
    case retrying

    public var displayName: String {
        switch self {
        case .queued: return "等待中"
        case .downloading: return "下载中"
        case .packaging: return "正在生成清单"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .paused: return "已暂停"
        case .suspended: return "已暂停（可继续）"
        case .retrying: return "等待自动重试"
        }
    }
}

/// Where a running job is in the pipeline, for the stage bar.
public enum DownloadStage: Int, Codable, CaseIterable, Sendable {
    case resolving
    case downloading
    case merging
    case verifying
    case manifest

    public var displayName: String {
        switch self {
        case .resolving: return "解析"
        case .downloading: return "下载"
        case .merging: return "合并"
        case .verifying: return "校验"
        case .manifest: return "清单"
        }
    }
}

public struct DownloadJob: Codable, Identifiable, Sendable {
    public let id: UUID
    public let sourceURL: String
    public let profile: DownloadProfile
    public let destinationPath: String
    public let includeSidecars: Bool
    public let includeSubtitles: Bool
    public let browserCookieSource: BrowserCookieSource?
    /// Optional for backwards-compatible decoding of existing history.
    public var usesInAppLogin: Bool?
    public let createdAt: Date
    public var updatedAt: Date
    public var title: String?
    public var status: DownloadJobStatus
    public var progressFraction: Double
    public var progressText: String
    public var completedFiles: [String]
    public var manifestPath: String?
    public var errorMessage: String?
    /// Engine attempt bookkeeping. All optional so pre-0.6 history decodes.
    public var attempts: Int?
    public var youtubePlayerClient: String?
    public var diagnosis: EngineDiagnosis?
    /// Last engine command with credential paths redacted, for the audit view.
    public var lastCommand: String?
    public var retryNote: String?
    /// Set when the job belongs to a course or playlist.
    public var collection: CollectionContext?
    /// Live pipeline position and throughput; not meaningful after completion.
    public var stage: DownloadStage?
    /// Set for music-service downloads: picks audio formats, tags and layout.
    public var musicQuality: MusicQualityPreference?
    public var musicLayout: MusicLayout?
    public var musicNameTemplate: String?
    /// Measured quality of the downloaded audio (music jobs).
    public var audioQuality: AudioQualityReport?
    public var speedText: String?
    public var etaText: String?

    public init(
        sourceURL: String,
        profile: DownloadProfile,
        destination: URL,
        includeSidecars: Bool,
        includeSubtitles: Bool,
        browserCookieSource: BrowserCookieSource?,
        usesInAppLogin: Bool = false
    ) {
        id = UUID()
        self.sourceURL = sourceURL
        self.profile = profile
        destinationPath = destination.path
        self.includeSidecars = includeSidecars
        self.includeSubtitles = includeSubtitles
        self.browserCookieSource = browserCookieSource
        self.usesInAppLogin = usesInAppLogin ? true : nil
        createdAt = Date()
        updatedAt = Date()
        title = nil
        status = .queued
        progressFraction = 0
        progressText = "0%"
        completedFiles = []
        manifestPath = nil
        errorMessage = nil
    }
}

public struct SelectedFormatInfo: Codable, Equatable, Sendable {
    public var formatID: String
    public var resolution: String
    public var videoCodec: String
    public var audioCodec: String
    public var container: String

    public init(formatID: String, resolution: String, videoCodec: String, audioCodec: String, container: String) {
        self.formatID = formatID
        self.resolution = resolution
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.container = container
    }
}

public enum LinkInputParser {
    /// http(s) URLs found anywhere in pasted text — including app share text
    /// where the link is glued to CJK characters, e.g. `《晴天》http://163cn.tv/x`.
    /// Music links are normalized to the form the engine accepts.
    public static func URLs(from input: String) -> [URL] {
        candidates(in: input)
            .compactMap(URLValidator.validatedMediaURL)
            .map(MusicLink.canonicalize)
            .reduce(into: [URL]()) { result, url in
                if !result.contains(url) { result.append(url) }
            }
    }

    private static let urlPattern = try! NSRegularExpression(
        pattern: #"https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'*+,;=%]+"#, options: [.caseInsensitive])

    public static func candidates(in input: String) -> [String] {
        let range = NSRange(input.startIndex..., in: input)
        return urlPattern.matches(in: input, range: range).compactMap { match in
            Range(match.range, in: input).map { String(input[$0]) }
        }
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?'")) }
    }
}

public enum JobHistoryStore {
    public static var historyURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
#if MEDIAFETCH_STORE_PROFILE
        let filename = "store-video-history.json"
#else
        let filename = "history.json"
#endif
        return base.appendingPathComponent("MediaFetch", isDirectory: true)
            .appendingPathComponent(filename)
    }

    public static func load() -> [DownloadJob] {
        guard let data = try? Data(contentsOf: historyURL),
              let jobs = try? restoredJobs(from: data) else { return [] }
        return jobs
    }

    public static func restoredJobs(from data: Data) throws -> [DownloadJob] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var jobs = try decoder.decode([DownloadJob].self, from: data)
        for index in jobs.indices where [.downloading, .packaging, .suspended, .retrying].contains(jobs[index].status) {
            jobs[index].status = .paused
            jobs[index].updatedAt = Date()
        }
        return jobs
    }

    public static func encoded(_ jobs: [DownloadJob]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(jobs)
    }

    public static func save(_ jobs: [DownloadJob]) throws {
        let directory = historyURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoded(jobs).write(to: historyURL, options: .atomic)
    }
}
