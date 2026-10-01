import Foundation
import Combine
import MediaFetchCore

@MainActor
public final class DownloaderService: ObservableObject {
    @Published public var metadata: MediaMetadata?
    @Published public var isAnalyzing = false
    @Published public var isDownloading = false {
        didSet { updateSleepAssertion() }
    }
    @Published public var progress = DownloadProgress()
    @Published public var status = "等待链接"
    @Published public var recentMessages: [String] = []
    @Published public var errorMessage: String?
    @Published public var safariPermissionRequired = false
    @Published public var completedFiles: [String] = []
    @Published public var jobs: [DownloadJob]

#if DEBUG
    private var previewDependenciesReady: Bool?
#endif

    private var process: Process?
    private var lineBuffer = ""
    private var currentJobID: UUID?
    private var activeFormats: [SelectedFormatInfo] = []
    private var activeMediaID: String?
    private var activePlatform: String?
    private var cancellationRequested = false
    /// Full engine output of the current attempt, for diagnosis. `recentMessages`
    /// keeps only the last few lines for display.
    private var engineLog: [String] = []
    private var attemptStates: [UUID: EngineAttemptState] = [:]
    /// 429s seen this app session; later requests slow down and use fewer fragments.
    private var sessionRateLimitCount = 0
    private var retryTask: Task<Void, Never>?
    private var sleepActivity: NSObjectProtocol?
    /// Tests shorten retry waits; production waits real seconds.
    var retryNanosecondsPerSecond: UInt64 = 1_000_000_000
    private let toolchain: VideoToolchain
    private let packageExporter: VideoPackageExporter
    private let historyWriter: ([DownloadJob]) throws -> Void
#if !MEDIAFETCH_STORE_PROFILE
    /// Injected by the app's WebKit session owner; the video module has no UI dependency.
    public var inAppCookieProvider: (@MainActor (URL) async throws -> Data)?
    private var activeCookieFile: TemporaryCookieFile?
    private var preparationTask: Task<Void, Never>?
    private var preparingJobID: UUID?
#endif

    public init(
        jobs: [DownloadJob]? = nil,
        toolchain: VideoToolchain = .applicationDefault,
        packageExporter: VideoPackageExporter = VideoPackageExporter(),
        historyWriter: @escaping ([DownloadJob]) throws -> Void = JobHistoryStore.save
    ) {
        self.jobs = jobs ?? JobHistoryStore.load()
        self.toolchain = toolchain
        self.packageExporter = packageExporter
        self.historyWriter = historyWriter
    }

#if DEBUG
    public init(previewJobs: [DownloadJob] = [], dependenciesReady: Bool) {
        jobs = previewJobs
        previewDependenciesReady = dependenciesReady
        toolchain = .applicationDefault
        packageExporter = VideoPackageExporter()
        historyWriter = { _ in }
    }
#endif

    #if MEDIAFETCH_STORE_PROFILE
    public var ytDLPPath: String? { nil }
    public var ffmpegPath: String? { nil }
    #else
    public var ytDLPPath: String? { toolchain.ytDLPURL?.path }
    public var ffmpegPath: String? { toolchain.ffmpegURL?.path }
    #endif
    public var dependenciesReady: Bool {
#if DEBUG
        if let previewDependenciesReady { return previewDependenciesReady }
#endif
        return ytDLPPath != nil && ffmpegPath != nil
    }
    public var hasResumableJobs: Bool { jobs.contains { [.queued, .paused].contains($0.status) } }

    public static func findExecutable(named name: String) -> String? {
#if MEDIAFETCH_STORE_PROFILE
        // Preserve the source-compatible helper for shared callers without
        // allowing Store builds to inspect external tool locations.
        return nil
#else
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
#endif
    }

    public static func toolEnvironment() -> [String: String] {
#if MEDIAFETCH_STORE_PROFILE
        return ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
#else
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        return environment
#endif
    }

    public func analyze(_ input: String, cookieSource: BrowserCookieSource? = nil, usesInAppLogin: Bool = false) {
#if !MEDIAFETCH_STORE_PROFILE
        if usesInAppLogin {
            guard !isAnalyzing && !isDownloading,
                  let url = LinkInputParser.URLs(from: input).first,
                  ensurePlatformAllowed(url) else { return }
            guard let provider = inAppCookieProvider else {
                errorMessage = "应用内登录尚未就绪，请重新打开登录窗口。"
                return
            }
            resetForNewOperation()
            isAnalyzing = true
            status = "正在读取应用内会话…"
            Task {
                do {
                    let file = try TemporaryCookieFile(data: await provider(url))
                    isAnalyzing = false
                    performAnalysis(input, cookieSource: nil, cookieFile: file)
                } catch {
                    isAnalyzing = false
                    status = "需要应用内登录"
                    errorMessage = error.localizedDescription
                }
            }
            return
        }
#endif
        performAnalysis(input, cookieSource: cookieSource)
    }

    private func performAnalysis(_ input: String, cookieSource: BrowserCookieSource?, cookieFile: TemporaryCookieFile? = nil) {
#if MEDIAFETCH_STORE_PROFILE
        errorMessage = "Mac App Store 版本不提供第三方站点视频下载；请使用本地完整版处理你有权保存的媒体。"
        return
#else
        guard !isAnalyzing && !isDownloading else { return }
        guard let url = LinkInputParser.URLs(from: input).first else {
            errorMessage = "请输入至少一条完整的 http:// 或 https:// 链接。"
            return
        }
        guard let ytDLPPath else {
            errorMessage = "未找到 yt-dlp。请先执行：brew install yt-dlp"
            return
        }
        guard ensurePlatformAllowed(url) else { return }
        guard ensureCookieAccess(cookieSource) else { return }

        resetForNewOperation()
        isAnalyzing = true
        status = "正在解析媒体信息…"

        let task = Process()
        let output = Pipe()
        let errors = Pipe()
        task.executableURL = URL(fileURLWithPath: ytDLPPath)
        task.environment = toolchain.processEnvironment
        var cookieArguments: [String] = []
        if let cookieSource { cookieArguments += cookieSource.ytDLPArguments }
        if let cookieFile { cookieArguments += ["--cookies", cookieFile.url.path] }
        task.arguments = YtDLPArgumentBuilder.analysisArguments(
            url: url.absoluteString,
            sessionRateLimitCount: sessionRateLimitCount,
            cookieArguments: cookieArguments
        )
        task.standardOutput = output
        task.standardError = errors

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { cookieFile?.remove() }
            do {
                try task.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                let stderr = String(data: errorData, encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isAnalyzing = false
                    if task.terminationStatus != 0 {
                        if cookieSource == .safari && EngineErrorClassifier.isSafariCookiePermissionError(stderr) {
                            self.presentSafariPermissionHelp()
                            return
                        }
                        if EngineErrorClassifier.isDRMError(stderr) {
                            self.status = "检测到 DRM 保护"
                            self.errorMessage = "该媒体流受 DRM 保护，Sooogood Video Catch 不会尝试绕过。"
                            return
                        }
                        if EngineErrorClassifier.isAuthenticationRequiredError(stderr) {
                            self.status = "需要登录"
                            self.errorMessage = cookieFile != nil
                                ? "应用内会话未通过验证。请在网站登录窗口重新登录，并确认账号可以观看这个视频。"
                                : self.authenticationRequiredMessage(for: cookieSource)
                            return
                        }
                        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let diagnosis = EngineDiagnostics.diagnose(stderr) {
                            self.status = diagnosis.title
                            self.errorMessage = "\(diagnosis.guidance)\n\n\(Self.lastErrorLine(in: trimmed))"
                        } else {
                            self.status = "解析失败"
                            self.errorMessage = trimmed
                        }
                        return
                    }
                    do {
                        self.metadata = try JSONDecoder().decode(MediaMetadata.self, from: data)
                        self.status = "解析完成，可以加入队列"
                    } catch {
                        self.status = "解析失败"
                        self.errorMessage = "媒体信息无法读取：\(error.localizedDescription)"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isAnalyzing = false
                    self?.status = "无法启动下载引擎"
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
#endif
    }

    @discardableResult
    public func enqueue(
        _ input: String,
        profile: DownloadProfile,
        destination: URL,
        includeSidecars: Bool,
        includeSubtitles: Bool,
        cookieSource: BrowserCookieSource? = nil,
        cookieSourceByURL: [String: BrowserCookieSource] = [:],
        inAppLoginURLs: Set<String> = []
    ) -> Int {
#if MEDIAFETCH_STORE_PROFILE
        errorMessage = "Mac App Store 版本不提供第三方站点视频下载；请使用本地完整版处理你有权保存的媒体。"
        return 0
#else
        let urls = LinkInputParser.URLs(from: input)
        guard !urls.isEmpty else {
            errorMessage = "没有找到有效媒体链接。每条链接请用空格或换行分隔。"
            return 0
        }
        guard ytDLPPath != nil else {
            errorMessage = "未找到 yt-dlp。请先执行：brew install yt-dlp"
            return 0
        }
        if let blockedURL = urls.first(where: { !StreamingPlatform.detect($0).downloadAllowed }) {
            let platform = StreamingPlatform.detect(blockedURL)
            status = "\(platform.displayName) 使用受保护媒体流"
            errorMessage = platform.restrictionMessage
            return 0
        }
        guard ffmpegPath != nil || !profile.requiresFFmpeg else {
            errorMessage = "该保存方式需要 FFmpeg 做无损封装。请先执行：brew install ffmpeg"
            return 0
        }
        for url in urls {
            let resolvedCookieSource = inAppLoginURLs.contains(url.absoluteString) ? nil : (cookieSourceByURL[url.absoluteString] ?? cookieSource)
            guard ensureCookieAccess(resolvedCookieSource) else { return 0 }
        }

        for url in urls {
            let resolvedCookieSource = inAppLoginURLs.contains(url.absoluteString) ? nil : (cookieSourceByURL[url.absoluteString] ?? cookieSource)
            jobs.append(DownloadJob(
                sourceURL: url.absoluteString,
                profile: profile,
                destination: destination,
                includeSidecars: includeSidecars,
                includeSubtitles: includeSubtitles,
                browserCookieSource: resolvedCookieSource,
                usesInAppLogin: inAppLoginURLs.contains(url.absoluteString)
            ))
        }
        persistJobs()
        status = "已加入 \(urls.count) 个任务"
        startNextIfNeeded()
        return urls.count
#endif
    }

    public func resumeQueue() {
#if MEDIAFETCH_STORE_PROFILE
        errorMessage = "Mac App Store 版本不提供第三方站点视频下载。"
        return
#else
        for index in jobs.indices where jobs[index].status == .paused {
            jobs[index].status = .queued
            jobs[index].updatedAt = Date()
        }
        persistJobs()
        startNextIfNeeded()
#endif
    }

    public func cancel() {
#if !MEDIAFETCH_STORE_PROFILE
        if let id = preparingJobID {
            preparationTask?.cancel()
            preparationTask = nil
            preparingJobID = nil
            updateJob(id) { $0.status = .cancelled; $0.updatedAt = Date() }
            isDownloading = false
            status = "下载已取消"
            persistJobs()
            startNextIfNeeded()
            return
        }
        if let retryTask, let id = currentJobID {
            retryTask.cancel()
            self.retryTask = nil
            attemptStates[id] = nil
            updateJob(id) { $0.status = .cancelled; $0.updatedAt = Date(); $0.retryNote = nil }
            isDownloading = false
            status = "下载已取消"
            finishCurrentJobAndContinue()
            return
        }
#endif
        guard let process, process.isRunning else { return }
        cancellationRequested = true
        if isSuspended { process.resume() }
        process.interrupt()
        status = "正在取消…"
    }

    /// True while the engine process is stopped in place (SIGSTOP).
    public var isSuspended: Bool {
        guard let id = currentJobID else { return false }
        return jobs.first(where: { $0.id == id })?.status == .suspended
    }

    /// Stops the running engine in place without losing connections' progress;
    /// `resumeCurrent()` continues exactly where it stopped.
    public func suspendCurrent() {
        guard let process, process.isRunning, let id = currentJobID, !isSuspended else { return }
        guard process.suspend() else { return }
        updateJob(id) { $0.status = .suspended; $0.updatedAt = Date() }
        status = "下载已暂停"
        updateSleepAssertion()
        persistJobs()
    }

    public func resumeCurrent() {
        guard let process, process.isRunning, let id = currentJobID, isSuspended else { return }
        guard process.resume() else { return }
        updateJob(id) { $0.status = .downloading; $0.updatedAt = Date() }
        status = "正在下载…"
        updateSleepAssertion()
        persistJobs()
    }

    /// Keeps the Mac from idle-sleeping while the queue is actively downloading.
    private func updateSleepAssertion() {
        let shouldHold = isDownloading && !isSuspended
        if shouldHold, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Sooogood Video Catch 正在下载"
            )
        } else if !shouldHold, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

#if !MEDIAFETCH_STORE_PROFILE
    /// Resolves every URL of a batch before anything downloads.
    public func preflight(
        urls: [URL],
        profile: DownloadProfile,
        destination: URL,
        cookieSourceByURL: [String: BrowserCookieSource],
        inAppLoginURLs: Set<String>
    ) async -> BatchPreflight.Report {
        let knownKeys = BatchPreflightRunner.downloadedMediaKeys(from: jobs)
        let knownURLs = Set(jobs.filter { $0.status == .completed }.map(\.sourceURL))
        return await BatchPreflightRunner(toolchain: toolchain).run(
            urls: urls, profile: profile, destination: destination,
            knownMediaKeys: knownKeys, knownSourceURLs: knownURLs,
            cookieArguments: { url in
                if inAppLoginURLs.contains(url.absoluteString) { return nil }
                return cookieSourceByURL[url.absoluteString]?.ytDLPArguments ?? []
            }
        )
    }
#endif

#if !MEDIAFETCH_STORE_PROFILE
    /// Resolves one URL without touching UI state (for agents and automation).
    /// Runs yt-dlp once for `url` with the right session (browser cookies or a
    /// temporary in-app cookie file that is removed afterwards).
    private func runEngine(
        _ url: URL, cookieSource: BrowserCookieSource?, usesInAppLogin: Bool,
        arguments makeArguments: ([String]) -> [String]
    ) async throws -> (status: Int32, stdout: Data, stderr: Data) {
        guard let ytDLP = toolchain.ytDLPURL else { throw EngineCallError("未找到 yt-dlp，请执行 brew install yt-dlp") }
        let platform = StreamingPlatform.detect(url)
        guard platform.downloadAllowed else { throw EngineCallError(platform.restrictionMessage ?? "受保护平台") }
        var cookieFile: TemporaryCookieFile?
        var cookieArguments = cookieSource?.ytDLPArguments ?? []
        if usesInAppLogin, let provider = inAppCookieProvider {
            let file = try TemporaryCookieFile(data: await provider(url))
            cookieFile = file
            cookieArguments = ["--cookies", file.url.path]
        }
        defer { cookieFile?.remove() }
        let arguments = makeArguments(cookieArguments)
        let environment = toolchain.processEnvironment
        return await Task.detached(priority: .userInitiated) {
            ProcessRunner.run(ytDLP, arguments, environment: environment)
        }.value
    }

    private static func engineError(_ stderr: Data) -> EngineCallError {
        let text = String(decoding: stderr, as: UTF8.self)
        let diagnosis = EngineDiagnostics.diagnose(text)
        return EngineCallError([diagnosis?.title, EngineDiagnostics.lastErrorLine(in: text)].compactMap { $0 }.joined(separator: "："))
    }

    public func inspect(_ url: URL, cookieSource: BrowserCookieSource?, usesInAppLogin: Bool) async throws -> MediaMetadata {
        let (status, output, errors) = try await runEngine(url, cookieSource: cookieSource, usesInAppLogin: usesInAppLogin) {
            YtDLPArgumentBuilder.analysisArguments(url: url.absoluteString, sessionRateLimitCount: self.sessionRateLimitCount, cookieArguments: $0)
        }
        guard status == 0 else { throw Self.engineError(errors) }
        return try JSONDecoder().decode(MediaMetadata.self, from: output)
    }

    /// One music track: who, which album, and which qualities this account can get.
    public func inspectMusic(_ url: URL, cookieSource: BrowserCookieSource?, usesInAppLogin: Bool) async throws -> MusicTrackInfo {
        let (status, output, errors) = try await runEngine(url, cookieSource: cookieSource, usesInAppLogin: usesInAppLogin) {
            YtDLPArgumentBuilder.analysisArguments(url: url.absoluteString, sessionRateLimitCount: self.sessionRateLimitCount, cookieArguments: $0)
        }
        guard status == 0 else { throw Self.engineError(errors) }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: output), let track = MusicTrackInfo.parse(json) else {
            throw EngineCallError("无法读取歌曲信息")
        }
        return track
    }

    /// Queues music tracks; each becomes its own package with tags, cover and lyrics.
    @discardableResult
    public func enqueueMusic(
        _ items: [(url: String, title: String?, collection: CollectionContext?)],
        quality: MusicQualityPreference, layout: MusicLayout, destination: URL,
        cookieSource: BrowserCookieSource?, usesInAppLogin: Bool, nameTemplate: String? = nil
    ) -> Int {
        guard ytDLPPath != nil else {
            errorMessage = "未找到 yt-dlp。请先执行：brew install yt-dlp"
            return 0
        }
        guard ffmpegPath != nil else {
            errorMessage = "写入封面和标签需要 FFmpeg。请先执行：brew install ffmpeg"
            return 0
        }
        guard ensureCookieAccess(usesInAppLogin ? nil : cookieSource) else { return 0 }
        for item in items {
            var job = DownloadJob(
                sourceURL: item.url, profile: .audioOnly, destination: destination,
                includeSidecars: false, includeSubtitles: false,
                browserCookieSource: usesInAppLogin ? nil : cookieSource, usesInAppLogin: usesInAppLogin
            )
            job.title = item.title
            job.collection = item.collection
            job.musicQuality = quality
            job.musicLayout = layout
            job.musicNameTemplate = layout == .custom ? nameTemplate : nil
            jobs.append(job)
        }
        persistJobs()
        status = "已加入 \(items.count) 首歌曲"
        startNextIfNeeded()
        return items.count
    }

    /// Lists the entries of a course or playlist without downloading anything.
    public func expandCollection(_ url: URL, cookieSource: BrowserCookieSource?, usesInAppLogin: Bool) async throws -> CollectionOutline {
        let (status, output, errors) = try await runEngine(url, cookieSource: cookieSource, usesInAppLogin: usesInAppLogin) {
            YtDLPArgumentBuilder.expansionArguments(url: url.absoluteString, cookieArguments: $0)
        }
        // Paid or private entries make yt-dlp exit non-zero even though it printed
        // the listing; a usable listing wins over the exit status.
        if let json = try? JSONDecoder().decode(JSONValue.self, from: output),
           let outline = CollectionOutline.parse(json) {
            return outline
        }
        let text = String(decoding: errors, as: UTF8.self)
        if status != 0, let diagnosis = EngineDiagnostics.diagnose(text) {
            throw EngineCallError([diagnosis.title, diagnosis.guidance, EngineDiagnostics.lastErrorLine(in: text)].joined(separator: "\n"))
        }
        throw EngineCallError("这个链接不是播放列表或课程，或者列表为空（可能需要登录才能看到课时）")
    }

    /// Queues selected entries of a course/playlist; each keeps its place in
    /// the collection folder structure and the collection manifest.
    @discardableResult
    public func enqueueCollection(
        _ outline: CollectionOutline, entries: [CollectionEntry], profile: DownloadProfile, destination: URL,
        includeSidecars: Bool, includeSubtitles: Bool, cookieSource: BrowserCookieSource?, usesInAppLogin: Bool
    ) -> Int {
        guard ytDLPPath != nil else {
            errorMessage = "未找到 yt-dlp。请先执行：brew install yt-dlp"
            return 0
        }
        guard ffmpegPath != nil || !profile.requiresFFmpeg else {
            errorMessage = "该保存方式需要 FFmpeg 做无损封装。请先执行：brew install ffmpeg"
            return 0
        }
        guard ensureCookieAccess(usesInAppLogin ? nil : cookieSource) else { return 0 }
        for entry in entries {
            var job = DownloadJob(
                sourceURL: entry.url, profile: profile, destination: destination,
                includeSidecars: includeSidecars, includeSubtitles: includeSubtitles,
                browserCookieSource: usesInAppLogin ? nil : cookieSource, usesInAppLogin: usesInAppLogin
            )
            job.title = entry.title
            job.collection = outline.context(for: entry)
            jobs.append(job)
        }
        persistJobs()
        status = "已加入「\(outline.title)」的 \(entries.count) 个条目"
        startNextIfNeeded()
        return entries.count
    }

    /// Cancels a specific job: the running one is interrupted, waiting ones are marked cancelled.
    public func cancelJob(_ id: UUID) {
        if currentJobID == id || preparingJobID == id {
            cancel()
            return
        }
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              [.queued, .paused, .retrying].contains(jobs[index].status) else { return }
        jobs[index].status = .cancelled
        jobs[index].updatedAt = Date()
        persistJobs()
    }

    /// Resumes a suspended running job in place, or re-queues a stopped one.
    public func resumeJob(_ id: UUID) {
        if currentJobID == id, isSuspended {
            resumeCurrent()
            return
        }
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status == .paused else { return }
        jobs[index].status = .queued
        jobs[index].updatedAt = Date()
        persistJobs()
        startNextIfNeeded()
    }
#endif

    /// Puts a failed or cancelled job back in the queue with a fresh attempt budget.
    public func retryJob(_ id: UUID) {
#if !MEDIAFETCH_STORE_PROFILE
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              [.failed, .cancelled].contains(jobs[index].status) else { return }
        attemptStates[id] = nil
        jobs[index].status = .queued
        jobs[index].errorMessage = nil
        jobs[index].diagnosis = nil
        jobs[index].retryNote = nil
        jobs[index].updatedAt = Date()
        persistJobs()
        startNextIfNeeded()
#endif
    }

    public func clearFinishedHistory() {
        guard !isDownloading else { return }
        jobs.removeAll { [.completed, .failed, .cancelled].contains($0.status) }
        persistJobs()
    }

#if !MEDIAFETCH_STORE_PROFILE
    private func startNextIfNeeded() {
        guard !isDownloading && !isAnalyzing,
              let index = jobs.firstIndex(where: { $0.status == .queued }) else { return }
        startJob(at: index)
    }

    private func startJob(at index: Int) {
        let job = jobs[index]
        guard job.usesInAppLogin == true else { launchJob(at: index); return }
        isDownloading = true
        preparingJobID = job.id
        status = "正在读取应用内会话…"
        preparationTask = Task {
            do {
                guard let url = URL(string: job.sourceURL),
                      let provider = inAppCookieProvider else {
                    throw NSError(domain: "MediaFetch.Session", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "应用内登录尚未就绪，请重新打开登录窗口。"
                    ])
                }
                let data = try await provider(url)
                try Task.checkCancellation()
                let file = try TemporaryCookieFile(data: data)
                guard let currentIndex = jobs.firstIndex(where: { $0.id == job.id }) else {
                    preparingJobID = nil
                    preparationTask = nil
                    isDownloading = false
                    startNextIfNeeded()
                    return
                }
                preparingJobID = nil
                preparationTask = nil
                launchJob(at: currentIndex, cookieFile: file)
            } catch {
                guard !Task.isCancelled else { return }
                preparingJobID = nil
                preparationTask = nil
                currentJobID = job.id
                failCurrentJob(error.localizedDescription)
            }
        }
    }

    private func launchJob(at index: Int, cookieFile: TemporaryCookieFile? = nil) {
        let job = jobs[index]
        guard let ytDLPPath else {
            currentJobID = job.id
            failCurrentJob("未找到 yt-dlp，请检查下载引擎设置。")
            return
        }
        if let url = URL(string: job.sourceURL), !StreamingPlatform.detect(url).downloadAllowed {
            jobs[index].status = .failed
            jobs[index].updatedAt = Date()
            jobs[index].errorMessage = StreamingPlatform.detect(url).restrictionMessage
            isDownloading = false
            persistJobs()
            startNextIfNeeded()
            return
        }
        guard ensureCookieAccess(job.browserCookieSource) else {
            jobs[index].status = .paused
            isDownloading = false
            jobs[index].updatedAt = Date()
            persistJobs()
            return
        }
        currentJobID = job.id
        activeCookieFile = cookieFile
        cancellationRequested = false
        activeFormats = []
        activeMediaID = nil
        activePlatform = nil
        errorMessage = nil
        completedFiles = []
        progress = DownloadProgress()
        recentMessages = []
        engineLog = []
        lineBuffer = ""
        isDownloading = true
        status = "正在准备下载…"
        updateJob(job.id) {
            $0.status = .downloading
            $0.updatedAt = Date()
            $0.errorMessage = nil
            $0.diagnosis = nil
            $0.stage = .resolving
        }
        persistJobs()

        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: ytDLPPath)
        task.environment = toolchain.processEnvironment
        let engineDestination = engineDestination(for: job)
        let state = attemptStates[job.id] ?? EngineAttemptState()
        attemptStates[job.id] = state
        var cookieArguments: [String] = []
        if cookieFile == nil, let cookieSource = job.browserCookieSource { cookieArguments += cookieSource.ytDLPArguments }
        if let cookieFile { cookieArguments += ["--cookies", cookieFile.url.path] }
        let arguments = YtDLPArgumentBuilder.downloadArguments(
            job: job,
            destination: engineDestination,
            ffmpegPath: ffmpegPath,
            state: state,
            sessionRateLimitCount: sessionRateLimitCount,
            cookieArguments: cookieArguments
        )
        updateJob(job.id) {
            $0.attempts = state.attempt
            $0.youtubePlayerClient = state.youtubePlayerClient
            $0.lastCommand = YtDLPArgumentBuilder.redactedCommandLine(executable: ytDLPPath, arguments: arguments)
        }

        task.arguments = arguments
        task.standardOutput = output
        task.standardError = output
        process = task
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consume(text) }
        }
        task.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                output.fileHandleForReading.readabilityHandler = nil
                self?.handleTermination(finished, ytDLPPath: ytDLPPath)
            }
        }
        do {
            try task.run()
            status = "正在下载…"
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            failCurrentJob(error.localizedDescription)
        }
    }

    private func handleTermination(_ finished: Process, ytDLPPath: String) {
        activeCookieFile?.remove()
        activeCookieFile = nil
        process = nil
        guard let jobID = currentJobID,
              let jobIndex = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        if cancellationRequested || finished.terminationReason == .uncaughtSignal {
            isDownloading = false
            status = "下载已取消"
            jobs[jobIndex].status = .cancelled
            jobs[jobIndex].updatedAt = Date()
            finishCurrentJobAndContinue()
            return
        }
        guard finished.terminationStatus == 0 else {
            let engineOutput = engineLog.joined(separator: "\n")
            if jobs[jobIndex].browserCookieSource == .safari &&
                EngineErrorClassifier.isSafariCookiePermissionError(engineOutput) {
                isDownloading = false
                jobs[jobIndex].status = .paused
                jobs[jobIndex].updatedAt = Date()
                presentSafariPermissionHelp()
                persistJobs()
                currentJobID = nil
                return
            }
            let diagnosis = EngineDiagnostics.diagnose(engineOutput)
            jobs[jobIndex].diagnosis = diagnosis
            if EngineErrorClassifier.isDRMError(engineOutput) {
                failCurrentJob("该媒体流受 DRM 保护，Sooogood Video Catch 不会尝试绕过。")
                return
            }
            if EngineErrorClassifier.isAuthenticationRequiredError(engineOutput) {
                failCurrentJob(jobs[jobIndex].usesInAppLogin == true
                    ? "应用内会话未通过验证，请在网站登录窗口重新登录并确认视频访问权限。"
                    : authenticationRequiredMessage(for: jobs[jobIndex].browserCookieSource))
                return
            }
            if let preference = jobs[jobIndex].musicQuality,
               engineOutput.lowercased().contains("requested format is not available") {
                // A missing quality tier will not appear on retry: say so instead.
                failCurrentJob("该曲目当前账号没有「\(preference.displayName)」可用（平台只提供更低音质，或需要会员）。可改用「最高可用音质」。")
                return
            }
            if scheduleRetryIfUseful(jobIndex: jobIndex, output: engineOutput) { return }
            let lastLine = Self.lastErrorLine(in: engineOutput)
            let fallback = lastLine.isEmpty ? "下载引擎返回错误 \(finished.terminationStatus)" : lastLine
            failCurrentJob(diagnosis.map { "\($0.title)：\($0.guidance)\n\(fallback)" } ?? fallback)
            return
        }
        attemptStates[jobID] = nil

        progress = DownloadProgress(fraction: 1, percentText: "100%", speedText: "", etaText: "")
        jobs[jobIndex].progressFraction = 1
        jobs[jobIndex].progressText = "100%"
        jobs[jobIndex].status = .packaging
        jobs[jobIndex].stage = .verifying
        jobs[jobIndex].speedText = nil
        jobs[jobIndex].etaText = nil
        jobs[jobIndex].updatedAt = Date()
        jobs[jobIndex].completedFiles = completedFiles
        status = "正在计算 SHA-256 并生成清单…"
        persistJobs()

        var job = jobs[jobIndex]
        let packageDirectory = completedFiles.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        let formats = activeFormats
        let mediaID = activeMediaID
        let platform = activePlatform
        let ffmpeg = ffmpegPath
        guard let packageDirectory else {
            failCurrentJob("下载完成，但没有收到最终文件路径，无法生成 manifest.json")
            return
        }

        let audioFiles = completedFiles.map(URL.init(fileURLWithPath:)).filter {
            ["mp3", "flac", "m4a", "ogg", "opus", "ape", "wav", "aac"].contains($0.pathExtension.lowercased())
        }
        let expectedTier = formats.first.map {
            MusicQualityTier.classify(formatID: $0.formatID, codec: $0.audioCodec, ext: $0.container, bitrate: nil, sampleRate: nil)
        }
        let ffprobe = ffmpeg.map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("ffprobe") }
        let environment = toolchain.processEnvironment
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                if job.musicQuality != nil, let audio = audioFiles.first,
                   let lrc = (try? FileManager.default.contentsOfDirectory(at: audio.deletingLastPathComponent(), includingPropertiesForKeys: nil))?
                       .first(where: { $0.pathExtension.lowercased() == "lrc" }) {
                    MusicTagger.embedLyrics(audio: audio, lrc: lrc, ffmpeg: ffmpeg.map(URL.init(fileURLWithPath:)), environment: environment)
                }
                if job.musicQuality != nil, let audio = audioFiles.first, let ffprobe,
                   FileManager.default.isExecutableFile(atPath: ffprobe.path) {
                    let probe = ProcessRunner.run(ffprobe, ["-v", "error", "-of", "json", "-show_format", "-show_streams", audio.path],
                                                  environment: environment)
                    job.audioQuality = AudioQualityReport.parse(ffprobeJSON: probe.stdout, expectedTier: expectedTier)
                }
                let manifest = try ManifestWriter.write(
                    job: job, packageDirectory: packageDirectory, platform: platform,
                    mediaID: mediaID, selectedFormats: formats, ytDLPPath: ytDLPPath, ffmpegPath: ffmpeg
                )
                DispatchQueue.main.async { self?.updateJob(job.id) { $0.stage = .manifest } }
                #if MEDIAFETCH_STORE_PROFILE
                let exportedDirectory = try self?.packageExporter.export(
                    packageDirectory: packageDirectory,
                    to: URL(fileURLWithPath: job.destinationPath, isDirectory: true)
                )
                guard let exportedDirectory else {
                    throw VideoPackageExportError.copyFailed("导出器不可用")
                }
                let finalManifest = exportedDirectory.appendingPathComponent("manifest.json")
                let finalFiles = try self?.packageExporter.regularFiles(in: exportedDirectory) ?? []
                self?.packageExporter.removeStagingDirectory(for: job.id)
                #else
                let exportedDirectory = packageDirectory
                let finalManifest = manifest
                let finalFiles = try FileManager.default.contentsOfDirectory(
                    at: exportedDirectory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ).filter {
                    (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                }
                #endif
                #if !MEDIAFETCH_STORE_PROFILE
                if let collection = job.collection, job.musicLayout != .custom {
                    try? CollectionManifestWriter.record(
                        destination: URL(fileURLWithPath: job.destinationPath, isDirectory: true), context: collection,
                        sourceURL: job.sourceURL, title: job.title, status: .completed, packageManifest: finalManifest)
                }
                #endif
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.updateJob(job.id) {
                        $0.stage = nil
                        $0.audioQuality = job.audioQuality
                        $0.status = .completed
                        $0.updatedAt = Date()
                        $0.manifestPath = finalManifest.path
                        $0.completedFiles = finalFiles.map(\.path)
                    }
                    self.isDownloading = false
                    self.status = "下载与素材清单已完成"
                    self.finishCurrentJobAndContinue()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.failCurrentJob("媒体已下载，但生成清单失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// Applies `RetryPolicy`; returns true when another attempt was scheduled.
    private func scheduleRetryIfUseful(jobIndex: Int, output: String) -> Bool {
        let job = jobs[jobIndex]
        let state = attemptStates[job.id] ?? EngineAttemptState()
        guard let decision = RetryPolicy.next(
            after: output,
            state: state,
            isYouTube: YtDLPArgumentBuilder.isYouTube(job.sourceURL),
            sessionRateLimitCount: sessionRateLimitCount
        ) else {
            attemptStates[job.id] = nil
            return false
        }
        if decision.countsAsRateLimit { sessionRateLimitCount += 1 }
        attemptStates[job.id] = decision.nextState
        jobs[jobIndex].status = .retrying
        jobs[jobIndex].retryNote = "第 \(decision.nextState.attempt)/\(RetryPolicy.maxAttempts) 次尝试：\(decision.reason)"
        jobs[jobIndex].updatedAt = Date()
        status = jobs[jobIndex].retryNote ?? "等待自动重试"
        persistJobs()
        let jobID = job.id
        let waitNanoseconds = UInt64(decision.delaySeconds) * retryNanosecondsPerSecond
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: waitNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            guard let index = self.jobs.firstIndex(where: { $0.id == jobID }),
                  self.jobs[index].status == .retrying else { return }
            self.jobs[index].status = .queued
            self.currentJobID = nil
            self.isDownloading = false
            self.startJob(at: index)
        }
        return true
    }

    static func lastErrorLine(in output: String) -> String {
        EngineDiagnostics.lastErrorLine(in: output)
    }

    private func failCurrentJob(_ message: String) {
        if let currentJobID { attemptStates[currentJobID] = nil }
        #if !MEDIAFETCH_STORE_PROFILE
        if let currentJobID, let job = jobs.first(where: { $0.id == currentJobID }), let collection = job.collection,
           job.musicLayout != .custom {
            let drm = job.diagnosis?.cause == .drmProtected || message.contains("DRM")
            try? CollectionManifestWriter.record(
                destination: URL(fileURLWithPath: job.destinationPath, isDirectory: true), context: collection,
                sourceURL: job.sourceURL, title: job.title, status: drm ? .drmSkipped : .failed,
                packageManifest: nil, note: message)
        }
        #endif
        activeCookieFile?.remove()
        activeCookieFile = nil
        isDownloading = false
        process = nil
        status = "任务失败"
        errorMessage = message
        if let currentJobID {
            updateJob(currentJobID) {
                $0.status = .failed
                $0.updatedAt = Date()
                $0.errorMessage = message
                $0.retryNote = nil
                $0.stage = nil
            }
        }
        finishCurrentJobAndContinue()
    }

    private func finishCurrentJobAndContinue() {
        persistJobs()
        currentJobID = nil
        activeFormats = []
        activeMediaID = nil
        activePlatform = nil
        startNextIfNeeded()
    }

    private func consume(_ text: String) {
        lineBuffer += text
        let lines = lineBuffer.components(separatedBy: .newlines)
        lineBuffer = lines.last ?? ""
        for line in lines.dropLast() where !line.isEmpty { consumeLine(line) }
    }

    private func consumeLine(_ line: String) {
        if let parsed = ProgressParser.parse(line) {
            progress = parsed
            status = "正在下载…"
            if let currentJobID {
                updateJob(currentJobID) {
                    $0.progressFraction = parsed.fraction
                    $0.progressText = parsed.percentText
                    $0.stage = .downloading
                    $0.speedText = parsed.speedText.isEmpty ? nil : parsed.speedText
                    $0.etaText = parsed.etaText.isEmpty ? nil : parsed.etaText
                }
            }
            return
        }
        if line.hasPrefix("MF_POSTPROCESS|") {
            status = "下载完成，正在无损封装…"
            if let currentJobID { updateJob(currentJobID) { $0.stage = .merging; $0.etaText = nil } }
            return
        }
        if line.hasPrefix("MF_FILE|") {
            let path = String(line.dropFirst("MF_FILE|".count))
            if !completedFiles.contains(path) { completedFiles.append(path) }
            return
        }
        if line.hasPrefix("MF_TITLE|") {
            let title = String(line.dropFirst("MF_TITLE|".count))
            if let currentJobID { updateJob(currentJobID) { $0.title = title } }
            return
        }
        if line.hasPrefix("MF_MUSIC|") {
            let parts = line.dropFirst("MF_MUSIC|".count).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if let currentJobID {
                updateJob(currentJobID) {
                    $0.musicArtist = parts.first.flatMap { $0.isEmpty ? nil : $0 }
                    $0.musicAlbum = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
                }
            }
            return
        }
        if line.hasPrefix("MF_ID|") { activeMediaID = String(line.dropFirst("MF_ID|".count)); return }
        if line.hasPrefix("MF_PLATFORM|") {
            activePlatform = String(line.dropFirst("MF_PLATFORM|".count)); return
        }
        if line.hasPrefix("MF_FORMAT|") {
            let parts = line.dropFirst("MF_FORMAT|".count)
                .split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 5 {
                let format = SelectedFormatInfo(
                    formatID: parts[0], resolution: parts[1], videoCodec: parts[2],
                    audioCodec: parts[3], container: parts[4]
                )
                if !activeFormats.contains(format) { activeFormats.append(format) }
            }
            return
        }
        let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        engineLog.append(cleaned)
        if engineLog.count > 400 { engineLog.removeFirst(engineLog.count - 400) }
        recentMessages.append(cleaned)
        if recentMessages.count > 8 { recentMessages.removeFirst() }
    }

#endif

    private func updateJob(_ id: UUID, mutation: (inout DownloadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutation(&jobs[index])
    }

    private func persistJobs() {
        do { try historyWriter(jobs) }
        catch { errorMessage = "任务历史无法保存：\(error.localizedDescription)" }
    }

#if !MEDIAFETCH_STORE_PROFILE
    private func ensureCookieAccess(_ source: BrowserCookieSource?) -> Bool {
        guard source == .safari else {
            if source != nil && !toolchain.allowsBrowserCookies {
                errorMessage = "App Store 版本不读取浏览器 Cookie；请使用公开媒体链接或应用支持的授权方式。"
                return false
            }
            return true
        }
        guard toolchain.allowsBrowserCookies else {
            errorMessage = "App Store 版本不支持浏览器 Cookie 登录状态。"
            return false
        }
        guard SafariCookieAccess.canReadCookieStore() else {
            presentSafariPermissionHelp()
            return false
        }
        return true
    }

    private func engineDestination(for job: DownloadJob) -> URL {
        #if MEDIAFETCH_STORE_PROFILE
        return packageExporter.stagingDirectory(for: job.id)
        #else
        return URL(fileURLWithPath: job.destinationPath, isDirectory: true)
        #endif
    }

    private func ensurePlatformAllowed(_ url: URL) -> Bool {
        let platform = StreamingPlatform.detect(url)
        guard platform.downloadAllowed else {
            status = "\(platform.displayName) 使用受保护媒体流"
            errorMessage = platform.restrictionMessage
            return false
        }
        return true
    }

    private func presentSafariPermissionHelp() {
        errorMessage = nil
        status = "Safari Cookie 读取权限未开启"
        safariPermissionRequired = true
    }

    private func authenticationRequiredMessage(for source: BrowserCookieSource?) -> String {
        if source == nil {
            return "该媒体内容要求登录。请勾选“使用浏览器登录状态”，选择已经登录该平台的 Chrome 或 Firefox 后重试；如果内容本来就是公开的，也可以换用公开链接。"
        }
        if source == .safari {
            return "该媒体内容要求登录，但 Safari 登录状态未通过验证。请确认 Safari 已登录 Vimeo，并为 Sooogood Video Catch 开启“完整磁盘访问”后退出重开；也可以改用已登录的 Chrome 或 Firefox。"
        }
        return "该媒体内容要求登录，但所选浏览器的登录状态未通过验证。请确认浏览器中已登录 Vimeo，重新选择浏览器后再试。"
    }

    private func resetForNewOperation() {
        errorMessage = nil
        metadata = nil
        recentMessages = []
        completedFiles = []
        progress = DownloadProgress()
    }
#endif
}

/// Error surfaced to agents and automation callers.
public struct EngineCallError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
