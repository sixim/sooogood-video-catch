import Combine
import Foundation
import MediaFetchCore

#if !MEDIAFETCH_STORE_PROFILE
public struct ToolJob: Codable, Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case queued, running, completed, failed, cancelled

        public var displayName: String {
            switch self {
            case .queued: return "等待中"
            case .running: return "处理中"
            case .completed: return "已完成"
            case .failed: return "失败"
            case .cancelled: return "已取消"
            }
        }
    }

    public let id: UUID
    public let inputPath: String
    public let preset: ToolPreset
    public var language: String
    public let createdAt: Date
    public var status: Status
    public var progress: Double
    public var outputPaths: [String]
    public var errorMessage: String?
    public var elapsedSeconds: Double?
    /// Output seconds per wall-clock second, for the speed readout.
    public var speedFactor: Double?

    public init(input: URL, preset: ToolPreset, language: String = "auto") {
        id = UUID()
        inputPath = input.path
        self.preset = preset
        self.language = language
        createdAt = Date()
        status = .queued
        progress = 0
        outputPaths = []
    }

    public var inputName: String { (inputPath as NSString).lastPathComponent }
}

/// Queue for the creator toolbox. One job at a time: ffmpeg and whisper both
/// saturate the machine, so parallel jobs only make each one slower.
@MainActor
public final class ToolService: ObservableObject {
    @Published public private(set) var jobs: [ToolJob]
    @Published public private(set) var installedModels: [URL] = []
    @Published public var selectedModel: URL?
    @Published public var modelDownloadProgress: Double?
    @Published public var errorMessage: String?

    public let toolchain: ToolToolchain
    private let historyURL: URL
    private let modelDirectory: URL
    private var current: (id: UUID, process: ToolProcess)?

    public init(toolchain: ToolToolchain = .local(),
                historyURL: URL = ToolService.defaultHistoryURL,
                modelDirectory: URL = WhisperModelStore.directory) {
        self.toolchain = toolchain
        self.historyURL = historyURL
        self.modelDirectory = modelDirectory
        jobs = Self.loadHistory(historyURL)
        for index in jobs.indices where [.queued, .running].contains(jobs[index].status) {
            jobs[index].status = .cancelled
        }
        refreshModels()
    }

    public nonisolated static var defaultHistoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MediaFetch/tools-history.json")
    }

    public var isBusy: Bool { current != nil }

    public func refreshModels() {
        installedModels = WhisperModelStore.installed(in: modelDirectory)
        if selectedModel == nil || !installedModels.contains(selectedModel!) { selectedModel = installedModels.first }
    }

    // MARK: Queue

    @discardableResult
    public func enqueue(inputs: [URL], presets: [ToolPreset], language: String = "auto") -> [ToolJob] {
        let created = inputs.flatMap { input in presets.map { ToolJob(input: input, preset: $0, language: language) } }
        jobs.append(contentsOf: created)
        persist()
        startNextIfNeeded()
        return created
    }

    public func cancel(_ id: UUID) {
        if current?.id == id {
            current?.process.cancel()
        } else if let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status == .queued {
            jobs[index].status = .cancelled
            persist()
        }
    }

    public func clearFinished() {
        jobs.removeAll { [.completed, .failed, .cancelled].contains($0.status) }
        persist()
    }

    private func startNextIfNeeded() {
        guard current == nil, let index = jobs.firstIndex(where: { $0.status == .queued }) else { return }
        let job = jobs[index]
        let process = ToolProcess()
        current = (job.id, process)
        jobs[index].status = .running
        jobs[index].progress = 0
        let toolchain = self.toolchain
        let model = selectedModel
        let jobID = job.id
        let report: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in self?.update(jobID) { $0.progress = value } }
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let started = Date()
            let outcome = Result { () -> (outputs: [URL], duration: Double?) in
                try ToolService.execute(job, model: model, toolchain: toolchain, process: process, progress: report)
            }
            let elapsed = Date().timeIntervalSince(started)
            await self?.finish(jobID, outcome: outcome, elapsed: elapsed)
        }
    }

    private func finish(_ id: UUID, outcome: Result<(outputs: [URL], duration: Double?), Error>, elapsed: Double) {
        current = nil
        update(id) { job in
            job.elapsedSeconds = elapsed
            switch outcome {
            case .success(let result):
                job.status = .completed
                job.progress = 1
                job.outputPaths = result.outputs.map(\.path)
                if let duration = result.duration, elapsed > 0 { job.speedFactor = duration / elapsed }
            case .failure(let error):
                job.status = (error as? ToolError) == .cancelled ? .cancelled : .failed
                job.errorMessage = error.localizedDescription
            }
        }
        persist()
        startNextIfNeeded()
    }

    // MARK: Execution (off the main actor)

    nonisolated static func execute(_ job: ToolJob, model: URL?, toolchain: ToolToolchain, process: ToolProcess,
                                    progress: @escaping @Sendable (Double) -> Void) throws -> (outputs: [URL], duration: Double?) {
        let input = URL(fileURLWithPath: job.inputPath)
        let probe = try ToolEngine.probe(input, toolchain: toolchain)
        let started = Date()
        var outputs: [URL] = []
        var command: [String] = []
        var engine = ToolEngine.version(of: toolchain.ffmpeg, arguments: ["-version"])

        if job.preset == .transcribe {
            guard let model else { throw ToolError.modelMissing }
            outputs = try ToolEngine.transcribe(input, model: model, language: job.language, probe: probe,
                                                toolchain: toolchain, process: process, progress: progress)
            command = ["whisper-cli", "-m", model.lastPathComponent, "-l", job.language, "-osrt", "-ovtt", "-otxt"]
            engine = "whisper.cpp · \(model.lastPathComponent)"
        } else {
            if job.preset.needsVideo && probe.videoCodec == nil { throw ToolError.noVideoStream }
            if !job.preset.needsVideo && probe.audioCodec == nil { throw ToolError.noAudioStream }
            var plan = FFmpegCommandBuilder.plan(input: input, preset: job.preset, probe: probe)
            do {
                try ToolEngine.runFFmpeg(plan, duration: probe.duration, toolchain: toolchain, process: process, progress: progress)
            } catch ToolError.failed(let detail) where plan.arguments.contains("prores_videotoolbox") {
                // Hardware ProRes is unavailable on some Macs/inputs: retry in software.
                plan = FFmpegCommandBuilder.plan(input: input, preset: job.preset, probe: probe, hardwareProRes: false)
                do {
                    try ToolEngine.runFFmpeg(plan, duration: probe.duration, toolchain: toolchain, process: process, progress: progress)
                } catch {
                    throw ToolError.failed(detail)
                }
            }
            outputs = [plan.output]
            command = ["ffmpeg"] + plan.arguments
        }
        record(outputs: outputs, source: input, preset: job.preset, command: command, engine: engine,
               elapsed: Date().timeIntervalSince(started))
        return (outputs, probe.duration)
    }

    /// Appends each output to `derivatives.json` in the source folder.
    nonisolated static func record(outputs: [URL], source: URL, preset: ToolPreset, command: [String], engine: String, elapsed: Double) {
        let directory = source.deletingLastPathComponent()
        guard let sourceRef = fileRef(source, in: directory) else { return }
        for output in outputs where output.deletingLastPathComponent().path == directory.path {
            guard let outputRef = fileRef(output, in: directory) else { continue }
            let role: DerivativeRecord.Role = preset == .transcribe && output.pathExtension == "txt" ? .transcript : preset.role
            try? DerivativeLog.append(DerivativeRecord(
                tool: preset == .transcribe ? "whisper.cpp" : "ffmpeg", preset: preset.rawValue, role: role,
                source: sourceRef, output: outputRef, command: command, engineVersion: engine, elapsedSeconds: elapsed
            ), in: directory)
        }
    }

    nonisolated static func fileRef(_ url: URL, in directory: URL) -> DerivativeRecord.FileRef? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              let hash = try? ManifestWriter.sha256(url) else { return nil }
        return .init(relativePath: url.lastPathComponent, byteSize: Int64(size), sha256: hash)
    }

    // MARK: Models

    public func downloadModel(_ model: WhisperModel, host: WhisperModel.Host) async {
        modelDownloadProgress = 0
        errorMessage = nil
        do {
            let url = try await WhisperModelStore.download(model, host: host) { value in
                Task { @MainActor [weak self] in self?.modelDownloadProgress = value }
            }
            refreshModels()
            selectedModel = url
        } catch {
            errorMessage = error.localizedDescription
        }
        modelDownloadProgress = nil
    }

    public func useExistingModel(at url: URL) {
        do {
            selectedModel = try WhisperModelStore.linkExistingModel(at: url, in: modelDirectory)
            refreshModels()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Persistence

    private func update(_ id: UUID, _ mutation: (inout ToolJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutation(&jobs[index])
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(jobs).write(to: historyURL, options: .atomic)
        } catch {
            errorMessage = "工具箱记录无法保存：\(error.localizedDescription)"
        }
    }

    private static func loadHistory(_ url: URL) -> [ToolJob] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ToolJob].self, from: Data(contentsOf: url))) ?? []
    }
}
#endif
