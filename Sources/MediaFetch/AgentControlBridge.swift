#if !MEDIAFETCH_STORE_PROFILE
import Foundation
import MediaFetchControl
import MediaFetchCore
import MediaFetchResolve
import MediaFetchTools
import MediaFetchTorrent
import MediaFetchVideo

/// Executes agent tool calls (from the MCP helper) against the same services
/// the UI uses, so every policy — protected platforms, DRM refusal, login
/// handling, no-overwrite, provenance — applies to agents too.
final class AgentControlBridge: ControlHandler, @unchecked Sendable {
    private weak var downloader: DownloaderService?
    private weak var torrents: TorrentService?
    private weak var tools: ToolService?
    private weak var resolve: ResolveService?
    private weak var logins: StreamingSiteLoginStore?

    @MainActor
    init(downloader: DownloaderService, torrents: TorrentService, tools: ToolService,
         resolve: ResolveService, logins: StreamingSiteLoginStore) {
        self.downloader = downloader
        self.torrents = torrents
        self.tools = tools
        self.resolve = resolve
        self.logins = logins
    }

    func handle(tool: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        let args = Arguments(await Self.expandingShortLinks(arguments))
        switch tool {
        case "app_status": return await appStatus()
        case "analyze_url": return try await analyze(args)
        case "preflight_batch": return try await preflight(args)
        case "enqueue_download": return try await enqueue(args)
        case "expand_collection": return try await expandCollection(args)
        case "enqueue_collection": return try await enqueueCollection(args)
        case "list_tasks": return await listTasks(args)
        case "list_torrents": return await listTasks(Arguments(["kind": "torrent"]))
        case "get_task": return try await getTask(args.string("id"))
        case "pause_task": return try await control(args.string("id"), action: .pause)
        case "resume_task": return try await control(args.string("id"), action: .resume)
        case "cancel_task": return try await control(args.string("id"), action: .cancel)
        case "retry_task": return try await control(args.string("id"), action: .retry)
        case "read_manifest": return try await readManifest(args.string("id"))
        case "add_torrent": return try await addTorrent(args)
        case "run_tool": return try await runTool(args)
        case "get_transcript": return try getTranscript(args.string("path"))
        case "send_to_resolve": return try await sendToResolve(args)
        default: throw ControlError.unknownMethod
        }
    }

    // MARK: Status & inspection

    @MainActor private func appStatus() async -> JSONValue {
        let health = await VideoEngineHealth.probe(toolchain: .applicationDefault)
        var engines: [String: JSONValue] = [
            "yt_dlp": .string(health.ytDLP.summary),
            "ffmpeg": .bool(health.ffmpegInstalled),
            "deno": .bool(health.jsRuntimePath != nil),
            "transmission": .bool(TransmissionDaemon.findExecutable() != nil),
            "whisper": .bool(ToolToolchain.local().whisper != nil),
            "davinci_resolve_installed": .bool(resolve?.isInstalled ?? false)
        ]
        if let models = tools?.installedModels { engines["whisper_models"] = .array(models.map { .string($0.lastPathComponent) }) }
        return [
            "app": .string(MediaFetchRelease.displayName), "version": .string(MediaFetchRelease.version),
            "engines": .object(engines),
            "counts": [
                "video": .number(Double(downloader?.jobs.count ?? 0)),
                "video_active": .number(Double(downloader?.jobs.filter { [.queued, .downloading, .packaging, .retrying, .suspended].contains($0.status) }.count ?? 0)),
                "torrents": .number(Double(torrents?.torrents.count ?? 0)),
                "tool_jobs": .number(Double(tools?.jobs.count ?? 0))
            ],
            "default_destination": .string(AgentPaths.defaultDestination.path),
            "allowed_roots": .array(AgentPaths.allowedRoots().map { .string($0.path) })
        ]
    }

    @MainActor private func analyze(_ args: Arguments) async throws -> JSONValue {
        let url = try args.url("url")
        guard let downloader else { throw ControlError.failed("下载服务不可用") }
        let login = loginRouting(for: url)
        let metadata = try await downloader.inspect(url, cookieSource: login.cookieSource, usesInAppLogin: login.inApp)
        return [
            "title": .string(metadata.title),
            "uploader": metadata.uploader.map(JSONValue.string) ?? .null,
            "duration_seconds": metadata.duration.map(JSONValue.number) ?? .null,
            "max_resolution": .string(metadata.maximumResolution),
            "format_count": .number(Double(metadata.formats?.count ?? 0)),
            "platform": .string(StreamingPlatform.detect(url).displayName)
        ]
    }

    @MainActor private func preflight(_ args: Arguments) async throws -> JSONValue {
        let urls = try args.urls("urls")
        guard let downloader else { throw ControlError.failed("下载服务不可用") }
        let routing = urls.map { ($0, loginRouting(for: $0)) }
        let report = await downloader.preflight(
            urls: urls, profile: try args.profile(), destination: AgentPaths.defaultDestination,
            cookieSourceByURL: Dictionary(routing.compactMap { url, login in login.cookieSource.map { (url.absoluteString, $0) } }, uniquingKeysWith: { $1 }),
            inAppLoginURLs: Set(routing.filter { $0.1.inApp }.map { $0.0.absoluteString })
        )
        return [
            "verdict": .string(report.verdict.rawValue),
            "ready": .number(Double(report.readyCount)),
            "estimated_bytes": .number(Double(report.estimatedBytes)),
            "available_bytes": report.availableBytes.map { .number(Double($0)) } ?? .null,
            "fits_on_disk": .bool(report.fitsOnDisk),
            "items": .array(report.items.map { item in
                ["url": .string(item.url), "title": item.title.map(JSONValue.string) ?? .null,
                 "estimated_bytes": item.estimatedBytes.map { .number(Double($0)) } ?? .null,
                 "problem": item.problem.map { .string($0.rawValue) } ?? .null,
                 "detail": item.detail.map(JSONValue.string) ?? .null]
            })
        ]
    }

    // MARK: Downloads

    @MainActor private func enqueue(_ args: Arguments) async throws -> JSONValue {
        let urls = try args.urls("urls")
        guard let downloader else { throw ControlError.failed("下载服务不可用") }
        let destination = try args.optionalString("destination").map { try AgentPaths.validatedFolder($0) } ?? AgentPaths.defaultDestination
        let before = Set(downloader.jobs.map(\.id))
        var cookieByURL: [String: BrowserCookieSource] = [:]
        var inApp: Set<String> = []
        for url in urls {
            let login = loginRouting(for: url)
            if let source = login.cookieSource { cookieByURL[url.absoluteString] = source }
            if login.inApp { inApp.insert(url.absoluteString) }
        }
        let count = downloader.enqueue(
            urls.map(\.absoluteString).joined(separator: "\n"), profile: try args.profile(), destination: destination,
            includeSidecars: args.bool("sidecars") ?? true, includeSubtitles: args.bool("subtitles") ?? true,
            cookieSourceByURL: cookieByURL, inAppLoginURLs: inApp
        )
        guard count > 0 else { throw ControlError.failed(downloader.errorMessage ?? "没有任务被加入队列") }
        let created = downloader.jobs.filter { !before.contains($0.id) }
        return ["enqueued": .number(Double(count)), "destination": .string(destination.path),
                "tasks": .array(created.map(videoSummary))]
    }

    @MainActor private func outline(for url: URL) async throws -> CollectionOutline {
        guard let downloader else { throw ControlError.failed("下载服务不可用") }
        let login = loginRouting(for: url)
        return try await downloader.expandCollection(url, cookieSource: login.cookieSource, usesInAppLogin: login.inApp)
    }

    @MainActor private func expandCollection(_ args: Arguments) async throws -> JSONValue {
        let outline = try await outline(for: try args.url("url"))
        return [
            "id": .string(outline.id), "title": .string(outline.title), "kind": .string(outline.isCourse ? "course" : "playlist"),
            "entries": .array(outline.entries.map { entry in
                ["index": .number(Double(entry.index)), "title": .string(entry.title), "url": .string(entry.url),
                 "chapter": entry.chapterTitle.map(JSONValue.string) ?? .null,
                 "duration_seconds": entry.duration.map(JSONValue.number) ?? .null]
            })
        ]
    }

    @MainActor private func enqueueCollection(_ args: Arguments) async throws -> JSONValue {
        let url = try args.url("url")
        guard let downloader else { throw ControlError.failed("下载服务不可用") }
        let outline = try await outline(for: url)
        let wanted: Set<Int>? = args.raw["indices"]?.arrayValue.map { Set($0.compactMap(\.intValue)) }
        let entries = outline.entries.filter { wanted?.contains($0.index) ?? true }
        guard !entries.isEmpty else { throw ControlError.invalidParams("没有匹配的条目") }
        let destination = try args.optionalString("destination").map { try AgentPaths.validatedFolder($0) } ?? AgentPaths.defaultDestination
        let login = loginRouting(for: url)
        let count = downloader.enqueueCollection(
            outline, entries: entries, profile: try args.profile(), destination: destination,
            includeSidecars: true, includeSubtitles: true, cookieSource: login.cookieSource, usesInAppLogin: login.inApp)
        guard count > 0 else { throw ControlError.failed(downloader.errorMessage ?? "没有任务被加入队列") }
        return ["enqueued": .number(Double(count)), "title": .string(outline.title),
                "folder": .string(destination.appendingPathComponent(outline.rootFolderName).path)]
    }

    // MARK: Tasks

    enum Action { case pause, resume, cancel, retry }

    @MainActor private func listTasks(_ args: Arguments) async -> JSONValue {
        let kind = (try? args.optionalString("kind")) ?? nil
        let limit = args.int("limit") ?? 50
        var items: [JSONValue] = []
        if kind == nil || kind == "all" || kind == "video" {
            items += (downloader?.jobs ?? []).suffix(limit).reversed().map(videoSummary)
        }
        if kind == nil || kind == "all" || kind == "torrent" {
            items += (torrents?.torrents ?? []).prefix(limit).map(torrentSummary)
        }
        if kind == nil || kind == "all" || kind == "tools" {
            items += (tools?.jobs ?? []).suffix(limit).reversed().map(toolSummary)
        }
        return ["tasks": .array(items)]
    }

    @MainActor private func getTask(_ id: String) async throws -> JSONValue {
        if let job = videoJob(id) {
            var summary = videoSummary(job).objectValue ?? [:]
            summary["files"] = .array(job.completedFiles.map(JSONValue.string))
            summary["command"] = job.lastCommand.map(JSONValue.string) ?? .null
            summary["attempts"] = .number(Double(job.attempts ?? 1))
            if let diagnosis = job.diagnosis {
                summary["diagnosis"] = ["cause": .string(diagnosis.title), "fix": .string(diagnosis.guidance)]
            }
            return .object(summary)
        }
        if let snapshot = torrents?.torrents.first(where: { $0.hash == id.lowercased() }) {
            var summary = torrentSummary(snapshot).objectValue ?? [:]
            summary["files"] = .array(snapshot.files.map { ["name": .string($0.name), "bytes": .number(Double($0.length)),
                                                             "progress": .number($0.progress), "wanted": .bool($0.wanted)] })
            return .object(summary)
        }
        if let job = toolJob(id) { return toolSummary(job) }
        throw ControlError.notFound("没有找到任务 \(id)")
    }

    @MainActor private func control(_ id: String, action: Action) async throws -> JSONValue {
        if let job = videoJob(id), let downloader {
            switch action {
            case .pause:
                guard job.status == .downloading else { throw ControlError.failed("只能暂停正在下载的视频任务") }
                downloader.suspendCurrent()
            case .resume: downloader.resumeJob(job.id)
            case .cancel: downloader.cancelJob(job.id)
            case .retry: downloader.retryJob(job.id)
            }
            return videoSummary(downloader.jobs.first { $0.id == job.id } ?? job)
        }
        if let torrents, torrents.torrents.contains(where: { $0.hash == id.lowercased() }) {
            switch action {
            case .pause: await torrents.pause(id.lowercased())
            case .resume: await torrents.resume(id.lowercased())
            case .cancel, .retry: throw ControlError.failed("Torrent 只支持暂停和继续；移除请在应用内操作")
            }
            return try await getTask(id)
        }
        if let job = toolJob(id), let tools {
            guard action == .cancel else { throw ControlError.failed("工具箱任务只支持取消") }
            tools.cancel(job.id)
            return toolSummary(job)
        }
        throw ControlError.notFound("没有找到任务 \(id)")
    }

    @MainActor private func readManifest(_ id: String) async throws -> JSONValue {
        let path: String? = videoJob(id)?.manifestPath ?? torrents?.record(for: id.lowercased())?.manifestPath
        guard let path else { throw ControlError.notFound("这个任务还没有清单（未完成或不存在）") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    // MARK: Torrent, tools, Resolve

    @MainActor private func addTorrent(_ args: Arguments) async throws -> JSONValue {
        guard UserDefaults.standard.bool(forKey: "MediaFetch.torrent.noticeAccepted") else {
            throw ControlError.forbidden("用户尚未在应用的 Torrent 页确认使用说明；请让用户先在应用内确认")
        }
        guard let source = TorrentSource.magnet(from: try args.string("magnet")) else {
            throw ControlError.invalidParams(TorrentError.invalidMagnet.localizedDescription)
        }
        guard let torrents else { throw ControlError.failed("Torrent 服务不可用") }
        let policy: SeedPolicy
        switch try args.optionalString("seed_policy") {
        case "stop_when_done": policy = .stopWhenDone
        case "ratio_2": policy = .ratio(2)
        case "idle_30min": policy = .idleMinutes(30)
        default: policy = .default
        }
        let record = try await torrents.add(source, sequential: args.bool("sequential") ?? false,
                                            seedPolicy: policy, selectFiles: false)
        return ["id": .string(record.hash), "name": .string(record.name), "seed_policy": .string(policy.displayName),
                "download_directory": .string(record.downloadDirectory)]
    }

    @MainActor private func runTool(_ args: Arguments) async throws -> JSONValue {
        guard let tools else { throw ControlError.failed("工具箱不可用") }
        let paths = try args.strings("paths").map { try AgentPaths.validatedFile($0) }
        let presets = try args.strings("presets").map { name -> ToolPreset in
            guard let preset = ToolPreset(rawValue: name) else { throw ControlError.invalidParams("未知预设：\(name)") }
            return preset
        }
        if presets.contains(.transcribe) && tools.selectedModel == nil {
            throw ControlError.failed(ToolError.modelMissing.localizedDescription)
        }
        let jobs = tools.enqueue(inputs: paths, presets: presets, language: (try? args.optionalString("language")) ?? "auto")
        return ["tasks": .array(jobs.map(toolSummary))]
    }

    private func getTranscript(_ path: String) throws -> JSONValue {
        let url = try AgentPaths.validatedFile(path)
        var candidates: [URL] = []
        if url.pathExtension.lowercased() == "txt" {
            candidates = [url]
        } else {
            let base = url.deletingPathExtension()
            let folder = (try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
            candidates = folder.filter { $0.pathExtension == "txt" && $0.lastPathComponent.hasPrefix(base.lastPathComponent + ".") }
        }
        guard let transcript = candidates.first else { throw ControlError.notFound("没有找到转录文本；可先用 run_tool 的 transcribe 预设生成") }
        let data = try Data(contentsOf: transcript)
        guard data.count <= 2_000_000 else { throw ControlError.failed("转录文本超过 2 MB") }
        return ["path": .string(transcript.path), "text": .string(String(decoding: data, as: UTF8.self))]
    }

    @MainActor private func sendToResolve(_ args: Arguments) async throws -> JSONValue {
        guard let resolve else { throw ControlError.failed("达芬奇对接不可用") }
        let package: URL
        if let id = try args.optionalString("id") {
            if let manifest = videoJob(id)?.manifestPath ?? torrents?.record(for: id.lowercased())?.manifestPath {
                package = URL(fileURLWithPath: manifest).deletingLastPathComponent()
            } else {
                throw ControlError.notFound("任务 \(id) 还没有完成的素材包")
            }
        } else if let path = try args.optionalString("path") {
            package = try AgentPaths.validatedFolder(path)
        } else {
            throw ControlError.invalidParams("需要 id 或 path")
        }
        guard let result = await resolve.send(packageDirectory: package) else {
            throw ControlError.failed(resolve.errorMessage ?? "发送到达芬奇失败")
        }
        return ["project": .string(result.project), "bin": .array(result.bin.map(JSONValue.string)),
                "clips": .array(result.clips.map { .string($0.name) }), "failed": .array(result.failed.map(JSONValue.string)),
                "timeline": result.timeline.map(JSONValue.string) ?? .null]
    }

    // MARK: Helpers

    /// Music share short links in `url` / `urls` are expanded before validation.
    static func expandingShortLinks(_ arguments: [String: JSONValue]) async -> [String: JSONValue] {
        var result = arguments
        let resolver = MusicLinkResolver()
        if let url = arguments["url"]?.stringValue {
            result["url"] = .string(await resolver.resolveShortLinks(in: url).trimmingCharacters(in: .whitespaces))
        }
        if let urls = arguments["urls"]?.arrayValue?.compactMap(\.stringValue) {
            var expanded: [JSONValue] = []
            for url in urls { expanded.append(.string(await resolver.resolveShortLinks(in: url).trimmingCharacters(in: .whitespaces))) }
            result["urls"] = .array(expanded)
        }
        return result
    }

    @MainActor private func loginRouting(for url: URL) -> (cookieSource: BrowserCookieSource?, inApp: Bool) {
        logins?.routing(for: url) ?? (nil, false)
    }

    @MainActor private func videoJob(_ id: String) -> DownloadJob? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return downloader?.jobs.first { $0.id == uuid }
    }

    @MainActor private func toolJob(_ id: String) -> ToolJob? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return tools?.jobs.first { $0.id == uuid }
    }

    private func videoSummary(_ job: DownloadJob) -> JSONValue {
        [
            "id": .string(job.id.uuidString), "kind": "video", "status": .string(job.status.rawValue),
            "title": job.title.map(JSONValue.string) ?? .null, "source": .string(job.sourceURL),
            "progress": .number(job.progressFraction), "profile": .string(job.profile.rawValue),
            "manifest": job.manifestPath.map(JSONValue.string) ?? .null,
            "error": job.errorMessage.map(JSONValue.string) ?? .null,
            "retry_note": job.retryNote.map(JSONValue.string) ?? .null
        ]
    }

    private func torrentSummary(_ snapshot: TorrentSnapshot) -> JSONValue {
        [
            "id": .string(snapshot.hash), "kind": "torrent", "status": .string(snapshot.state.displayName),
            "title": .string(snapshot.name), "progress": .number(snapshot.percentDone),
            "download_rate": .number(Double(snapshot.downloadRate)), "upload_ratio": .number(snapshot.uploadRatio),
            "size": .number(Double(snapshot.sizeWhenDone)), "complete": .bool(snapshot.isComplete)
        ]
    }

    private func toolSummary(_ job: ToolJob) -> JSONValue {
        [
            "id": .string(job.id.uuidString), "kind": "tools", "status": .string(job.status.rawValue),
            "title": .string(job.inputName), "preset": .string(job.preset.rawValue), "progress": .number(job.progress),
            "outputs": .array(job.outputPaths.map(JSONValue.string)),
            "speed_factor": job.speedFactor.map(JSONValue.number) ?? .null,
            "error": job.errorMessage.map(JSONValue.string) ?? .null
        ]
    }
}

/// Typed access to tool arguments with agent-readable errors.
struct Arguments {
    let raw: [String: JSONValue]
    init(_ raw: [String: JSONValue]) { self.raw = raw }

    func string(_ key: String) throws -> String {
        guard let value = raw[key]?.stringValue, !value.isEmpty else { throw ControlError.invalidParams("缺少参数 \(key)") }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = raw[key], value != .null else { return nil }
        guard let text = value.stringValue else { throw ControlError.invalidParams("\(key) 必须是字符串") }
        return text
    }

    func strings(_ key: String) throws -> [String] {
        guard let values = raw[key]?.arrayValue?.compactMap(\.stringValue), !values.isEmpty else {
            throw ControlError.invalidParams("\(key) 必须是非空字符串数组")
        }
        return values
    }

    func bool(_ key: String) -> Bool? { raw[key]?.boolValue }
    func int(_ key: String) -> Int? { raw[key]?.intValue }

    func url(_ key: String) throws -> URL {
        guard let url = LinkInputParser.URLs(from: try string(key)).first else { throw ControlError.invalidParams("\(key) 不是有效的 http(s) 链接") }
        return url
    }

    func urls(_ key: String) throws -> [URL] {
        let urls = LinkInputParser.URLs(from: try strings(key).joined(separator: "\n"))
        guard !urls.isEmpty else { throw ControlError.invalidParams("\(key) 中没有有效链接") }
        return urls
    }

    func profile() throws -> DownloadProfile {
        switch try optionalString("profile") ?? "highest" {
        case "highest": return .highest
        case "source": return .sourceStreams
        case "mp4": return .compatibleMP4
        case "audio": return .audioOnly
        case let other: throw ControlError.invalidParams("未知 profile：\(other)")
        }
    }
}

/// Where agents may read and write: the user's Downloads and Movies, plus
/// folders the user picked in the app. Everything else is refused.
enum AgentPaths {
    @MainActor static var defaultDestination: URL {
        SecurityScopedBookmarkStore(key: "MediaFetch.video.destination").resolve()
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    static func allowedRoots() -> [URL] {
        var roots = [
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0],
            FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        ]
        if let video = SecurityScopedBookmarkStore(key: "MediaFetch.video.destination").resolve() { roots.append(video) }
        roots.append(MusicPreferences.destination)
        if let torrent = UserDefaults.standard.string(forKey: "MediaFetch.torrent.directory") {
            roots.append(URL(fileURLWithPath: torrent, isDirectory: true))
        }
        return roots.map { $0.resolvingSymlinksInPath().standardizedFileURL }
    }

    static func isAllowed(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return allowedRoots().contains { path == $0.path || path.hasPrefix($0.path + "/") }
    }

    static func validatedFolder(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        guard isAllowed(url) else { throw ControlError.forbidden("路径不在允许范围内（下载、影片或应用中选择的文件夹）：\(path)") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ControlError.notFound("文件夹不存在：\(path)")
        }
        return url
    }

    static func validatedFile(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard isAllowed(url) else { throw ControlError.forbidden("路径不在允许范围内（下载、影片或应用中选择的文件夹）：\(path)") }
        guard FileManager.default.fileExists(atPath: url.path) else { throw ControlError.notFound("文件不存在：\(path)") }
        return url
    }
}
#endif
