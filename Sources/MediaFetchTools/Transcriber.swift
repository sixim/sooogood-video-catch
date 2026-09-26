import Foundation
import MediaFetchCore

#if !MEDIAFETCH_STORE_PROFILE
/// whisper.cpp models the user can choose. Files come from the official
/// whisper.cpp model repository; a mirror host is offered for mainland China.
public struct WhisperModel: Identifiable, Equatable, Sendable {
    public let fileName: String
    public let displayName: String
    public let approximateBytes: Int64
    public let note: String

    public var id: String { fileName }

    public static let catalog: [WhisperModel] = [
        .init(fileName: "ggml-large-v3-turbo-q5_0.bin", displayName: "Large v3 Turbo（量化，推荐）",
              approximateBytes: 574_000_000, note: "接近 Large 的准确度，速度快，中英文都好"),
        .init(fileName: "ggml-small.bin", displayName: "Small", approximateBytes: 488_000_000,
              note: "速度更快，准确度中等"),
        .init(fileName: "ggml-base.bin", displayName: "Base", approximateBytes: 148_000_000,
              note: "最快最小，适合快速草稿"),
        .init(fileName: "ggml-large-v3-turbo.bin", displayName: "Large v3 Turbo（完整）",
              approximateBytes: 1_620_000_000, note: "最高准确度，体积大")
    ]

    public enum Host: String, CaseIterable, Sendable {
        case huggingFace = "huggingface.co"
        case mirror = "hf-mirror.com"
    }

    public func downloadURL(host: Host) -> URL {
        URL(string: "https://\(host.rawValue)/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }
}

public enum WhisperModelStore {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MediaFetch/whisper-models", isDirectory: true)
    }

    /// Installed models, best first (catalog order), then any extra `ggml-*.bin`.
    public static func installed(in directory: URL = directory) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let models = files.filter { $0.lastPathComponent.hasPrefix("ggml-") && $0.pathExtension == "bin" && isValidModel($0) }
        let order = WhisperModel.catalog.map(\.fileName)
        return models.sorted {
            (order.firstIndex(of: $0.lastPathComponent) ?? .max, $0.lastPathComponent)
                < (order.firstIndex(of: $1.lastPathComponent) ?? .max, $1.lastPathComponent)
        }
    }

    /// ggml files start with the magic 0x67676d6c ("lmgg" little-endian).
    public static func isValidModel(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = (try? handle.read(upToCount: 4)) ?? Data()
        return magic == Data([0x6C, 0x6D, 0x67, 0x67])
    }

    /// Reuses a model that already exists elsewhere (e.g. bundled by another
    /// app) through a symlink, so nothing is copied or downloaded twice.
    public static func linkExistingModel(at source: URL, in directory: URL = directory) throws -> URL {
        guard isValidModel(source) else { throw ToolError.failed("这个文件不是 whisper.cpp 模型（ggml-*.bin）") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var name = source.lastPathComponent
        if !name.hasPrefix("ggml-") { name = "ggml-" + name }
        let link = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: link.path) { return link }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        return link
    }

    /// Downloads to a temporary name and moves into place only after the magic
    /// check passes, so a captive portal page never becomes a "model".
    public static func download(_ model: WhisperModel, host: WhisperModel.Host,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(model.fileName)
        let delegate = DownloadProgressDelegate(progress: progress, expected: model.approximateBytes)
        let (temporary, response) = try await URLSession.shared.download(from: model.downloadURL(host: host), delegate: delegate)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ToolError.failed("模型下载失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）")
        }
        guard isValidModel(temporary) else {
            try? FileManager.default.removeItem(at: temporary)
            throw ToolError.failed("下载到的文件不是 whisper 模型，请尝试切换下载源")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    let expected: Int64

    init(progress: @escaping @Sendable (Double) -> Void, expected: Int64) {
        self.progress = progress
        self.expected = expected
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
        progress(min(Double(totalBytesWritten) / Double(max(total, 1)), 1))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

extension ToolEngine {
    /// Parses whisper-cli `-pp` output; it can overshoot 100 %.
    public static func whisperProgress(from line: String) -> Double? {
        guard let range = line.range(of: "progress =") else { return nil }
        let digits = line[range.upperBound...].trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }
        return Double(digits).map { min($0 / 100, 1) }
    }

    /// Audio → 16 kHz WAV → whisper-cli → `<name>.<lang>.srt/.vtt/.txt` next to the input.
    /// Progress: first 10 % audio prep, remaining 90 % recognition.
    static func transcribe(_ input: URL, model: URL, language: String, probe: MediaProbe, toolchain: ToolToolchain,
                           process: ToolProcess, progress: @escaping @Sendable (Double) -> Void) throws -> [URL] {
        guard let whisper = toolchain.whisper else { throw ToolError.missingTool("whisper-cli（brew install whisper-cpp）") }
        guard probe.audioCodec != nil else { throw ToolError.noAudioStream }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("MediaFetch-asr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let wav = work.appendingPathComponent("audio.wav")
        let prep = FFmpegCommandBuilder.plan(input: input, preset: .transcribe, probe: probe, output: wav)
        try runFFmpeg(prep, duration: probe.duration, toolchain: toolchain, process: process) { progress($0 * 0.1) }

        let base = input.deletingPathExtension().appendingPathExtension(language == "auto" ? "transcript" : language)
        let outputs = ["srt", "vtt", "txt"].map { base.appendingPathExtension($0) }
        if let existing = outputs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            throw ToolError.outputExists(existing.lastPathComponent)
        }
        let threads = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        let arguments = ["-m", model.path, "-f", wav.path, "-l", language, "-t", String(threads),
                         "-osrt", "-ovtt", "-otxt", "-of", base.path, "-pp"]
        let result = try process.run(whisper, arguments, environment: toolchain.environment, mergeStderr: true) { line in
            if let value = whisperProgress(from: line) { progress(0.1 + value * 0.9) }
        }
        if process.wasCancelled { outputs.forEach { try? FileManager.default.removeItem(at: $0) }; throw ToolError.cancelled }
        guard result.status == 0 else { throw ToolError.failed(result.stderr) }
        return outputs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
#endif
