import Foundation
import MediaFetchCore

#if !MEDIAFETCH_STORE_PROFILE
/// Homebrew tools the toolbox drives.
public struct ToolToolchain: Sendable, Equatable {
    public var ffmpeg: URL?
    public var ffprobe: URL?
    public var whisper: URL?
    public var environment: [String: String]

    public init(ffmpeg: URL?, ffprobe: URL?, whisper: URL?, environment: [String: String] = ["PATH": "/usr/bin:/bin"]) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.whisper = whisper
        self.environment = environment
    }

    public static func local() -> ToolToolchain {
        func find(_ name: String) -> URL? {
            ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
                .map(URL.init(fileURLWithPath:))
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        return ToolToolchain(ffmpeg: find("ffmpeg"), ffprobe: find("ffprobe"), whisper: find("whisper-cli"),
                             environment: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": NSHomeDirectory()])
    }
}

public enum ToolError: LocalizedError, Equatable {
    case missingTool(String)
    case noVideoStream
    case noAudioStream
    case modelMissing
    case outputExists(String)
    case cancelled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .missingTool(let name): return String(localized: "未找到 \(name)，请用 Homebrew 安装")
        case .noVideoStream: return String(localized: "这个文件没有视频流")
        case .noAudioStream: return String(localized: "这个文件没有音频流")
        case .modelMissing: return String(localized: "还没有 whisper 模型，请先在工具箱里下载一个")
        case .outputExists(let name): return String(localized: "输出文件已存在：\(name)（不会覆盖）")
        case .cancelled: return String(localized: "已取消")
        case .failed(let detail): return String(localized: "处理失败：\(detail)")
        }
    }
}

/// A cancellable operation that may run several child processes in sequence
/// (e.g. ffmpeg audio prep, then whisper). Cancel stops whichever is running.
final class ToolProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var current: Process?

    var wasCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        let running: Process? = lock.withLock {
            cancelled = true
            return current
        }
        if let running, running.isRunning { running.terminate() }
    }

    /// Runs to completion. `onLine` receives each stdout line (and stderr lines
    /// when `mergeStderr`); the stderr tail is returned otherwise.
    func run(_ executable: URL, _ arguments: [String], environment: [String: String], mergeStderr: Bool = false,
             onLine: @escaping (String) -> Void) throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = mergeStderr ? output : errors
        let alreadyCancelled: Bool = lock.withLock {
            current = process
            return cancelled
        }
        if alreadyCancelled { return (15, "") }
        defer { lock.withLock { current = nil } }
        // Both pipes are drained on their own threads until EOF, so neither can
        // fill up and block the child, and no line is lost after exit.
        let group = DispatchGroup()
        var errorData = Data()
        try process.run()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            var buffer = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    onLine(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
            }
            if !buffer.isEmpty { onLine(String(decoding: buffer, as: UTF8.self)) }
            group.leave()
        }
        if !mergeStderr {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                errorData = errors.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }
        process.waitUntilExit()
        group.wait()
        return (process.terminationStatus, String(decoding: errorData.suffix(2000), as: UTF8.self))
    }
}

/// Stateless operations used by `ToolService`; safe to call off the main actor.
public enum ToolEngine {
    public static func probe(_ input: URL, toolchain: ToolToolchain) throws -> MediaProbe {
        guard let ffprobe = toolchain.ffprobe else { throw ToolError.missingTool("ffprobe") }
        var data = Data()
        let result = try ToolProcess().run(
            ffprobe, ["-v", "error", "-of", "json", "-show_format", "-show_streams", input.path],
            environment: toolchain.environment, onLine: { data.append(Data(($0 + "\n").utf8)) }
        )
        guard result.status == 0, let probe = MediaProbe(ffprobeJSON: data) else {
            throw ToolError.failed(result.stderr.isEmpty ? String(localized: "无法读取媒体信息") : result.stderr)
        }
        return probe
    }

    public static func version(of executable: URL?, arguments: [String]) -> String {
        guard let executable else { return "not installed" }
        var first: String?
        _ = try? ToolProcess().run(executable, arguments, environment: ["PATH": "/usr/bin:/bin"]) { line in
            if first == nil { first = line }
        }
        return first ?? "unknown"
    }

    /// Runs one ffmpeg plan, reporting 0…1 progress from `-progress pipe:1`.
    static func runFFmpeg(_ plan: FFmpegCommandBuilder.Plan, duration: Double?, toolchain: ToolToolchain,
                          process: ToolProcess, progress: @escaping @Sendable (Double) -> Void) throws {
        guard let ffmpeg = toolchain.ffmpeg else { throw ToolError.missingTool("ffmpeg") }
        if FileManager.default.fileExists(atPath: plan.output.path) {
            throw ToolError.outputExists(plan.output.lastPathComponent)
        }
        let result = try process.run(ffmpeg, plan.arguments, environment: toolchain.environment) { line in
            if let seconds = FFmpegCommandBuilder.progressSeconds(from: line), let duration, duration > 0 {
                progress(min(max(seconds / duration, 0), 1))
            } else if line == "progress=end" {
                progress(1)
            }
        }
        if process.wasCancelled {
            try? FileManager.default.removeItem(at: plan.output)
            throw ToolError.cancelled
        }
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: plan.output)
            throw ToolError.failed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
#endif
