import Foundation

enum DownloadJobStatus: String, Codable {
    case queued
    case downloading
    case packaging
    case completed
    case failed
    case cancelled
    case paused

    var displayName: String {
        switch self {
        case .queued: return "等待中"
        case .downloading: return "下载中"
        case .packaging: return "正在生成清单"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .paused: return "已暂停"
        }
    }
}

struct DownloadJob: Codable, Identifiable {
    let id: UUID
    let sourceURL: String
    let profile: DownloadProfile
    let destinationPath: String
    let includeSidecars: Bool
    let includeSubtitles: Bool
    let browserCookieSource: BrowserCookieSource?
    let createdAt: Date
    var updatedAt: Date
    var title: String?
    var status: DownloadJobStatus
    var progressFraction: Double
    var progressText: String
    var completedFiles: [String]
    var manifestPath: String?
    var errorMessage: String?

    init(
        sourceURL: String,
        profile: DownloadProfile,
        destination: URL,
        includeSidecars: Bool,
        includeSubtitles: Bool,
        browserCookieSource: BrowserCookieSource?
    ) {
        id = UUID()
        self.sourceURL = sourceURL
        self.profile = profile
        destinationPath = destination.path
        self.includeSidecars = includeSidecars
        self.includeSubtitles = includeSubtitles
        self.browserCookieSource = browserCookieSource
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

struct SelectedFormatInfo: Codable, Equatable {
    var formatID: String
    var resolution: String
    var videoCodec: String
    var audioCodec: String
    var container: String
}

enum LinkInputParser {
    static func URLs(from input: String) -> [URL] {
        input
            .components(separatedBy: .whitespacesAndNewlines)
            .compactMap(URLValidator.validatedMediaURL)
            .reduce(into: [URL]()) { result, url in
                if !result.contains(url) { result.append(url) }
            }
    }
}

enum JobHistoryStore {
    static var historyURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MediaFetch", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    static func load() -> [DownloadJob] {
        guard let data = try? Data(contentsOf: historyURL),
              let jobs = try? restoredJobs(from: data) else { return [] }
        return jobs
    }

    static func restoredJobs(from data: Data) throws -> [DownloadJob] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var jobs = try decoder.decode([DownloadJob].self, from: data)
        for index in jobs.indices where [.downloading, .packaging].contains(jobs[index].status) {
            jobs[index].status = .paused
            jobs[index].updatedAt = Date()
        }
        return jobs
    }

    static func encoded(_ jobs: [DownloadJob]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(jobs)
    }

    static func save(_ jobs: [DownloadJob]) throws {
        let directory = historyURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoded(jobs).write(to: historyURL, options: .atomic)
    }
}
