import Foundation
import MediaFetchCore

#if !MEDIAFETCH_STORE_PROFILE
/// Collects preflight facts for a batch: metadata for each URL (three at a
/// time, so YouTube is not hammered), duplicates against finished packages,
/// and free space at the destination.
public struct BatchPreflightRunner: Sendable {
    public let toolchain: VideoToolchain
    public var concurrency = 3

    public init(toolchain: VideoToolchain) {
        self.toolchain = toolchain
    }

    /// `platform|id` keys of media already saved, read from finished manifests.
    public static func downloadedMediaKeys(from jobs: [DownloadJob]) -> Set<String> {
        var keys: Set<String> = []
        for job in jobs where job.status == .completed {
            guard let path = job.manifestPath,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let json = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let id = json["mediaID"]?.stringValue else { continue }
            keys.insert(mediaKey(platform: json["platform"]?.stringValue, id: id))
        }
        return keys
    }

    static func mediaKey(platform: String?, id: String) -> String {
        "\((platform ?? "").lowercased().split(separator: ":").first.map(String.init) ?? "")|\(id)"
    }

    public func run(
        urls: [URL],
        profile: DownloadProfile,
        destination: URL,
        knownMediaKeys: Set<String>,
        knownSourceURLs: Set<String>,
        cookieArguments: @escaping @Sendable (URL) -> [String]?
    ) async -> BatchPreflight.Report {
        var results: [Int: BatchPreflight.Item] = [:]
        await withTaskGroup(of: (Int, BatchPreflight.Item).self) { group in
            var next = 0
            func enqueue() {
                guard next < urls.count else { return }
                let index = next
                let url = urls[index]
                next += 1
                group.addTask {
                    (index, check(url, profile: profile, knownMediaKeys: knownMediaKeys,
                                  knownSourceURLs: knownSourceURLs, cookieArguments: cookieArguments))
                }
            }
            for _ in 0..<max(1, concurrency) { enqueue() }
            for await (index, item) in group {
                results[index] = item
                enqueue()
            }
        }
        let ordered = urls.indices.compactMap { results[$0] }
        return BatchPreflight.evaluate(ordered, availableBytes: BatchPreflight.availableBytes(at: destination))
    }

    func check(
        _ url: URL,
        profile: DownloadProfile,
        knownMediaKeys: Set<String>,
        knownSourceURLs: Set<String>,
        cookieArguments: (URL) -> [String]?
    ) -> BatchPreflight.Item {
        let source = url.absoluteString
        if !StreamingPlatform.detect(url).downloadAllowed {
            return .init(url: source, problem: .blocked, detail: StreamingPlatform.detect(url).restrictionMessage)
        }
        if knownSourceURLs.contains(source) {
            return .init(url: source, problem: .alreadyDownloaded)
        }
        guard let ytDLP = toolchain.ytDLPURL else {
            return .init(url: source, problem: .engineError, detail: String(localized: "未找到 yt-dlp"))
        }
        // nil means "session is handled in-app": skip metadata instead of reporting a false login problem.
        guard let cookies = cookieArguments(url) else {
            return .init(url: source, detail: String(localized: "使用应用内登录，开始下载时再验证"))
        }
        let arguments = YtDLPArgumentBuilder.analysisArguments(url: source, cookieArguments: cookies)
        let insertAt = max(0, arguments.count - 1)
        var withFormat = arguments
        withFormat.insert(contentsOf: ["--format", profile.formatSelector], at: insertAt)
        let (status, stdout, stderr) = ProcessRunner.run(ytDLP, withFormat, environment: toolchain.processEnvironment)
        guard status == 0, let json = try? JSONDecoder().decode(JSONValue.self, from: stdout) else {
            let output = String(decoding: stderr, as: UTF8.self)
            return .init(url: source, problem: BatchPreflight.problem(forEngineOutput: output),
                         detail: EngineDiagnostics.lastErrorLine(in: output))
        }
        let title = json["title"]?.stringValue
        if let id = json["id"]?.stringValue,
           knownMediaKeys.contains(Self.mediaKey(platform: json["extractor"]?.stringValue, id: id)) {
            return .init(url: source, title: title, problem: .alreadyDownloaded)
        }
        return .init(url: source, title: title, estimatedBytes: Self.estimatedBytes(json))
    }

    /// Size of the formats yt-dlp would actually pick for this profile.
    static func estimatedBytes(_ json: JSONValue) -> Int64? {
        func size(_ value: JSONValue) -> Double? { value["filesize"]?.doubleValue ?? value["filesize_approx"]?.doubleValue }
        if let requested = json["requested_formats"]?.arrayValue, !requested.isEmpty {
            let sizes = requested.compactMap(size)
            return sizes.count == requested.count ? Int64(sizes.reduce(0, +)) : nil
        }
        return size(json).map { Int64($0) }
    }
}
#endif
