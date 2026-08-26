import Foundation

@MainActor
final class DownloaderService: ObservableObject {
    @Published var metadata: MediaMetadata?
    @Published var isAnalyzing = false
    @Published var isDownloading = false
    @Published var progress = DownloadProgress()
    @Published var status = "等待链接"
    @Published var recentMessages: [String] = []
    @Published var errorMessage: String?
    @Published var completedFiles: [String] = []
    @Published var jobs: [DownloadJob]

    private var process: Process?
    private var lineBuffer = ""
    private var currentJobID: UUID?
    private var activeFormats: [SelectedFormatInfo] = []
    private var activeMediaID: String?
    private var activePlatform: String?
    private var cancellationRequested = false

    init(jobs: [DownloadJob]? = nil) {
        self.jobs = jobs ?? JobHistoryStore.load()
    }

    var ytDLPPath: String? { Self.findExecutable(named: "yt-dlp") }
    var ffmpegPath: String? { Self.findExecutable(named: "ffmpeg") }
    var dependenciesReady: Bool { ytDLPPath != nil && ffmpegPath != nil }
    var hasResumableJobs: Bool { jobs.contains { [.queued, .paused].contains($0.status) } }

    static func findExecutable(named name: String) -> String? {
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    static func toolEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        return environment
    }

    func analyze(_ input: String, cookieSource: BrowserCookieSource? = nil) {
        guard !isAnalyzing && !isDownloading else { return }
        guard let url = LinkInputParser.URLs(from: input).first else {
            errorMessage = "请输入至少一条完整的 http:// 或 https:// 链接。"
            return
        }
        guard let ytDLPPath else {
            errorMessage = "未找到 yt-dlp。请先执行：brew install yt-dlp"
            return
        }

        resetForNewOperation()
        isAnalyzing = true
        status = "正在解析媒体信息…"

        let task = Process()
        let output = Pipe()
        let errors = Pipe()
        task.executableURL = URL(fileURLWithPath: ytDLPPath)
        task.environment = Self.toolEnvironment()
        var arguments = ["--dump-single-json", "--skip-download", "--no-playlist", "--no-warnings"]
        if let cookieSource { arguments += cookieSource.ytDLPArguments }
        arguments.append(url.absoluteString)
        task.arguments = arguments
        task.standardOutput = output
        task.standardError = errors

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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
    }

    @discardableResult
    func enqueue(
        _ input: String,
        profile: DownloadProfile,
        destination: URL,
        includeSidecars: Bool,
        includeSubtitles: Bool,
        cookieSource: BrowserCookieSource? = nil
    ) -> Int {
        let urls = LinkInputParser.URLs(from: input)
        guard !urls.isEmpty else {
            errorMessage = "没有找到有效媒体链接。每条链接请用空格或换行分隔。"
            return 0
        }
        guard ytDLPPath != nil else {
            errorMessage = "未找到 yt-dlp。请先执行：brew install yt-dlp"
            return 0
        }
        guard ffmpegPath != nil || profile == .sourceStreams else {
            errorMessage = "该保存方式需要 FFmpeg 做无损封装。请先执行：brew install ffmpeg"
            return 0
        }

        for url in urls {
            jobs.append(DownloadJob(
                sourceURL: url.absoluteString,
                profile: profile,
                destination: destination,
                includeSidecars: includeSidecars,
                includeSubtitles: includeSubtitles,
                browserCookieSource: cookieSource
            ))
        }
        persistJobs()
        status = "已加入 \(urls.count) 个任务"
        startNextIfNeeded()
        return urls.count
    }

    func resumeQueue() {
        for index in jobs.indices where jobs[index].status == .paused {
            jobs[index].status = .queued
            jobs[index].updatedAt = Date()
        }
        persistJobs()
        startNextIfNeeded()
    }

    func cancel() {
        guard let process, process.isRunning else { return }
        cancellationRequested = true
        process.interrupt()
        status = "正在取消…"
    }

    func clearFinishedHistory() {
        guard !isDownloading else { return }
        jobs.removeAll { [.completed, .failed, .cancelled].contains($0.status) }
        persistJobs()
    }

    private func startNextIfNeeded() {
        guard !isDownloading && !isAnalyzing,
              let index = jobs.firstIndex(where: { $0.status == .queued }) else { return }
        startJob(at: index)
    }

    private func startJob(at index: Int) {
        guard let ytDLPPath else { return }
        let job = jobs[index]
        currentJobID = job.id
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
        task.environment = Self.toolEnvironment()
        var arguments = [
            "--newline", "--no-playlist", "--continue",
            "--format", job.profile.formatSelector,
            "--paths", job.destinationPath,
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
        if let cookieSource = job.browserCookieSource { arguments += cookieSource.ytDLPArguments }
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
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.updateJob(job.id) {
                        $0.status = .completed
                        $0.updatedAt = Date()
                        $0.manifestPath = manifest.path
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

    private func persistJobs() {
        do { try JobHistoryStore.save(jobs) }
        catch { errorMessage = "任务历史无法保存：\(error.localizedDescription)" }
    }

    private func resetForNewOperation() {
        errorMessage = nil
        metadata = nil
        recentMessages = []
        completedFiles = []
        progress = DownloadProgress()
    }
}
