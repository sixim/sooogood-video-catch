import Foundation
import MediaFetchCore

#if !MEDIAFETCH_STORE_PROFILE
/// Snapshot of the Local toolchain shown in Settings and before downloads.
/// YouTube extraction needs an external JavaScript runtime (deno by default);
/// without it yt-dlp silently degrades to fewer formats.
public struct VideoEngineHealth: Equatable, Sendable {
    public let ytDLP: EngineHealthStatus
    public let ffmpegInstalled: Bool
    public let jsRuntimePath: String?

    public var issues: [String] {
        var result: [String] = []
        if ytDLP.needsAttention { result.append(ytDLP.summary) }
        if !ffmpegInstalled { result.append("未安装 FFmpeg，请执行 brew install ffmpeg") }
        if jsRuntimePath == nil { result.append("未找到 deno，YouTube 可能只能解析到部分格式，请执行 brew install deno") }
        return result
    }

    public static func probe(toolchain: VideoToolchain) async -> VideoEngineHealth {
        let versionOutput: String?
        if let ytDLP = toolchain.ytDLPURL {
            versionOutput = await Task.detached { Self.run(ytDLP, ["--version"], environment: toolchain.processEnvironment) }.value
        } else {
            versionOutput = nil
        }
        let deno = ["/opt/homebrew/bin/deno", "/usr/local/bin/deno"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        return VideoEngineHealth(
            ytDLP: .evaluate(versionOutput: versionOutput),
            ffmpegInstalled: toolchain.ffmpegURL != nil,
            jsRuntimePath: deno
        )
    }

    private static func run(_ executable: URL, _ arguments: [String], environment: [String: String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
#endif
