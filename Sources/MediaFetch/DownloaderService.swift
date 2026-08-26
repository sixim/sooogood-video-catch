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

    private var process: Process?
    private var lineBuffer = ""

    var ytDLPPath: String? { Self.findExecutable(named: "yt-dlp") }
    var ffmpegPath: String? { Self.findExecutable(named: "ffmpeg") }
    var dependenciesReady: Bool { ytDLPPath != nil && ffmpegPath != nil }

    static func findExecutable(named name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    static func toolEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        return environment
    }

    func analyze(_ input: String) {
        guard !isAnalyzing && !isDownloading else { return }
        guard let url = URLValidator.validatedMediaURL(from: input) else {
            errorMessage = "请输入完整的 http:// 或 https:// 链接。"
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
        task.arguments = [
            "--dump-single-json", "--skip-download", "--no-playlist",
            "--no-warnings", url.absoluteString
        ]
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
                        self.status = "解析完成，可以下载"
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

    func download(_ input: String, profile: DownloadProfile, destination: URL) {
        guard !isDownloading && !isAnalyzing else { return }
        guard let url = URLValidator.validatedMediaURL(from: input) else {
            errorMessage = "媒体链接无效。"
            return
        }
        guard let ytDLPPath else {
            errorMessage = "未找到 yt-dlp。请先执行：brew install yt-dlp"
            return
        }
        guard ffmpegPath != nil || profile == .sourceStreams else {
            errorMessage = "该保存方式需要 FFmpeg 做无损封装。请先执行：brew install ffmpeg"
            return
        }

        errorMessage = nil
        completedFiles = []
        progress = DownloadProgress()
        recentMessages = []
        lineBuffer = ""
        isDownloading = true
        status = "正在准备下载…"

        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: ytDLPPath)
        task.environment = Self.toolEnvironment()

        var arguments = [
            "--newline",
            "--no-playlist",
            "--format", profile.formatSelector,
            "--paths", destination.path,
            "--progress-template", "download:MF_PROGRESS|%(progress._percent_str)s|%(progress.downloaded_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
            "--progress-template", "postprocess:MF_POSTPROCESS|%(info.title)s",
            "--print", "after_move:MF_FILE|%(filepath)s"
        ]

        if profile == .sourceStreams {
            arguments += ["--output", "%(title).180B [%(id)s].f%(format_id)s.%(ext)s"]
        } else {
            arguments += ["--output", "%(title).180B [%(id)s].%(ext)s"]
        }
        if profile == .highest {
            arguments += ["--merge-output-format", "mkv"]
        } else if profile == .compatibleMP4 {
            arguments += ["--merge-output-format", "mp4"]
        }
        if let ffmpegPath {
            arguments += ["--ffmpeg-location", ffmpegPath]
        }
        arguments.append(url.absoluteString)

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
                guard let self else { return }
                self.isDownloading = false
                self.process = nil
                if finished.terminationReason == .uncaughtSignal {
                    self.status = "下载已取消"
                } else if finished.terminationStatus == 0 {
                    self.progress.fraction = 1
                    self.progress.percentText = "100%"
                    self.status = "下载完成"
                } else {
                    self.status = "下载失败"
                    self.errorMessage = self.recentMessages.last ?? "下载引擎返回错误 \(finished.terminationStatus)"
                }
            }
        }

        do {
            try task.run()
            status = "正在下载…"
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            isDownloading = false
            process = nil
            status = "无法启动下载引擎"
            errorMessage = error.localizedDescription
        }
    }

    func cancel() {
        guard let process, process.isRunning else { return }
        process.interrupt()
        status = "正在取消…"
    }

    private func consume(_ text: String) {
        lineBuffer += text
        let lines = lineBuffer.components(separatedBy: .newlines)
        lineBuffer = lines.last ?? ""
        for line in lines.dropLast() where !line.isEmpty {
            consumeLine(line)
        }
    }

    private func consumeLine(_ line: String) {
        if let parsed = ProgressParser.parse(line) {
            progress = parsed
            status = "正在下载…"
            return
        }
        if line.hasPrefix("MF_POSTPROCESS|") {
            status = "下载完成，正在无损封装…"
            return
        }
        if line.hasPrefix("MF_FILE|") {
            completedFiles.append(String(line.dropFirst("MF_FILE|".count)))
            return
        }

        let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        recentMessages.append(cleaned)
        if recentMessages.count > 8 { recentMessages.removeFirst() }
    }

    private func resetForNewOperation() {
        errorMessage = nil
        metadata = nil
        recentMessages = []
        completedFiles = []
        progress = DownloadProgress()
    }
}
