import Foundation
import Combine
import MediaFetchCore

@MainActor
public final class DownloaderService: ObservableObject {
    @Published public var metadata: MediaMetadata?
    @Published public var isAnalyzing = false
    @Published public var isDownloading = false
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
        var arguments = ["--dump-single-json", "--skip-download", "--no-playlist", "--no-warnings"]
        if let cookieSource { arguments += cookieSource.ytDLPArguments }
        if let cookieFile { arguments += ["--cookies", cookieFile.url.path] }
        arguments.append(url.absoluteString)
        task.arguments = arguments
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
                        self.status = "解析失败"
                        self.errorMessage = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
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
#endif
        guard let process, process.isRunning else { return }
        cancellationRequested = true
        process.interrupt()
        status = "正在取消…"
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
        lineBuffer = ""
        isDownloading = true
        status = "正在准备下载…"
        updateJob(job.id) {
            $0.status = .downloading
            $0.updatedAt = Date()
            $0.errorMessage = nil
        }
        persistJobs()

        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: ytDLPPath)
        task.environment = toolchain.processEnvironment
        let engineDestination = engineDestination(for: job)
        var arguments = [
            "--newline", "--no-playlist", "--continue",
            "--format", job.profile.formatSelector,
            "--paths", engineDestination.path,
            "--progress-template", "download:MF_PROGRESS|%(progress._percent_str)s|%(progress.downloaded_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
            "--progress-template", "postprocess:MF_POSTPROCESS|%(info.title)s",
            "--print", "before_dl:MF_ID|%(id)s",
            "--print", "before_dl:MF_TITLE|%(title)s",
            "--print", "before_dl:MF_PLATFORM|%(extractor)s",
            "--print", "before_dl:MF_FORMAT|%(format_id)s|%(resolution)s|%(vcodec)s|%(acodec)s|%(ext)s",
            "--print", "after_move:MF_FILE|%(filepath)s"
        ]

        let packageName = "%(title).180B [%(id)s]"
        if job.profile == .sourceStreams {
            arguments += ["--output", "\(packageName)/\(packageName).f%(format_id)s.%(ext)s"]
        } else {
            arguments += ["--output", "\(packageName)/\(packageName).%(ext)s"]
        }
        if job.profile == .highest {
            arguments += ["--merge-output-format", "mkv"]
        } else if job.profile == .compatibleMP4 {
            arguments += ["--merge-output-format", "mp4"]
        }
        if job.includeSidecars { arguments += ["--write-info-json", "--write-thumbnail"] }
        if job.includeSubtitles {
            arguments += [
                "--write-subs", "--write-auto-subs", "--sub-langs",
                "en,zh,zh-CN,zh-TW,zh-Hans,zh-Hant,-live_chat"
            ]
        }
        if let ffmpegPath { arguments += ["--ffmpeg-location", ffmpegPath] }
        if cookieFile == nil, let cookieSource = job.browserCookieSource { arguments += cookieSource.ytDLPArguments }
        if let cookieFile { arguments += ["--cookies", cookieFile.url.path] }
        arguments.append(job.sourceURL)

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
            let engineOutput = recentMessages.joined(separator: "\n")
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
            failCurrentJob(recentMessages.last ?? "下载引擎返回错误 \(finished.terminationStatus)")
            return
        }

        progress = DownloadProgress(fraction: 1, percentText: "100%", speedText: "", etaText: "")
        jobs[jobIndex].progressFraction = 1
        jobs[jobIndex].progressText = "100%"
        jobs[jobIndex].status = .packaging
        jobs[jobIndex].updatedAt = Date()
        jobs[jobIndex].completedFiles = completedFiles
        status = "正在计算 SHA-256 并生成清单…"
        persistJobs()

        let job = jobs[jobIndex]
        let packageDirectory = completedFiles.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        let formats = activeFormats
        let mediaID = activeMediaID
        let platform = activePlatform
        let ffmpeg = ffmpegPath
        guard let packageDirectory else {
            failCurrentJob("下载完成，但没有收到最终文件路径，无法生成 manifest.json")
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let manifest = try ManifestWriter.write(
                    job: job, packageDirectory: packageDirectory, platform: platform,
                    mediaID: mediaID, selectedFormats: formats, ytDLPPath: ytDLPPath, ffmpegPath: ffmpeg
                )
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
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.updateJob(job.id) {
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

    private func failCurrentJob(_ message: String) {
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
                }
            }
            return
        }
        if line.hasPrefix("MF_POSTPROCESS|") { status = "下载完成，正在无损封装…"; return }
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
        recentMessages.append(cleaned)
        if recentMessages.count > 8 { recentMessages.removeFirst() }
    }

    private func updateJob(_ id: UUID, mutation: (inout DownloadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutation(&jobs[index])
    }
#endif

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
