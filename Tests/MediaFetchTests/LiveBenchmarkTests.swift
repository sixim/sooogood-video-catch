#if !MEDIAFETCH_STORE_PROFILE
import XCTest
@testable import MediaFetchCore
@testable import MediaFetchTools
@testable import MediaFetchTorrent
@testable import MediaFetchVideo

/// Real-network benchmarks of the app's own engines. Never run by default:
///   MF_LIVE_DIR=/path MF_LIVE_NETWORK=1 swift test --filter LiveBenchmarkTests
/// Optional: MF_WHISPER_MODEL=/path/ggml-*.bin, MF_LIVE_TORRENT=/path/file.torrent
final class LiveBenchmarkTests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    private func liveDirectory(_ name: String) throws -> URL {
        guard environment["MF_LIVE_NETWORK"] == "1", let base = environment["MF_LIVE_DIR"] else {
            throw XCTSkip("live benchmark disabled")
        }
        let url = URL(fileURLWithPath: base).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func report(_ line: String) {
        print("BENCH | " + line)
    }

    private static func size(of url: URL) -> Int64 {
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    @MainActor
    private func download(_ url: String, profile: DownloadProfile, into dir: URL, timeout: TimeInterval = 900) async throws -> (DownloadJob, TimeInterval) {
        let downloader = DownloaderService(jobs: [], toolchain: .local(), historyWriter: { _ in })
        let started = Date()
        XCTAssertEqual(downloader.enqueue(url, profile: profile, destination: dir, includeSidecars: true, includeSubtitles: false), 1)
        while Date().timeIntervalSince(started) < timeout {
            if let job = downloader.jobs.first, [.completed, .failed, .cancelled].contains(job.status) { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let job = try XCTUnwrap(downloader.jobs.first)
        return (job, Date().timeIntervalSince(started))
    }

    @MainActor
    func testFullVideoPipeline4KAndToolbox() async throws {
        let dir = try liveDirectory("video")
        let (job, elapsed) = try await download("https://www.youtube.com/watch?v=LXb3EKWsInQ", profile: .highest, into: dir)
        XCTAssertEqual(job.status, .completed, job.errorMessage ?? "")
        let manifest = URL(fileURLWithPath: try XCTUnwrap(job.manifestPath))
        let package = manifest.deletingLastPathComponent()
        let bytes = Self.size(of: package)
        report(String(format: "4K highest (download+merge+SHA-256 manifest): %.1f s, %.0f MB, %.1f MB/s end-to-end, attempts %d",
                      elapsed, Double(bytes) / 1_048_576, Double(bytes) / 1_048_576 / elapsed, job.attempts ?? 1))

        // Toolbox on the downloaded 4K file.
        let media = try XCTUnwrap(job.completedFiles.map(URL.init(fileURLWithPath:)).first { $0.pathExtension == "mkv" || $0.pathExtension == "mp4" })
        let tools = ToolService(toolchain: .local(), historyURL: dir.appendingPathComponent("tools.json"),
                                modelDirectory: dir.appendingPathComponent("models"))
        tools.enqueue(inputs: [media], presets: [.proresProxy, .h264Proxy, .extractAudio])
        while tools.jobs.contains(where: { [.queued, .running].contains($0.status) }) {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        for toolJob in tools.jobs {
            XCTAssertEqual(toolJob.status, .completed, "\(toolJob.preset): \(toolJob.errorMessage ?? "")")
            report(String(format: "%@: %.1f s, %.1f× realtime", toolJob.preset.displayName,
                          toolJob.elapsedSeconds ?? 0, toolJob.speedFactor ?? 0))
        }
        XCTAssertFalse(DerivativeLog.proxies(in: package).isEmpty)
    }

    @MainActor
    func testTranscriptionSpeedWithRealModel() async throws {
        let dir = try liveDirectory("speech")
        guard let modelPath = environment["MF_WHISPER_MODEL"] else { throw XCTSkip("MF_WHISPER_MODEL not set") }
        // Public TED-Ed talk (English speech, ~5 min).
        let (job, elapsed) = try await download("https://www.youtube.com/watch?v=arj7oStGLkU", profile: .compatibleMP4, into: dir)
        XCTAssertEqual(job.status, .completed, job.errorMessage ?? "")
        report(String(format: "speech video download: %.1f s", elapsed))
        let media = try XCTUnwrap(job.completedFiles.map(URL.init(fileURLWithPath:)).first { $0.pathExtension == "mp4" })
        let tools = ToolService(toolchain: .local(), historyURL: dir.appendingPathComponent("tools.json"),
                                modelDirectory: dir.appendingPathComponent("models"))
        tools.useExistingModel(at: URL(fileURLWithPath: modelPath))
        tools.enqueue(inputs: [media], presets: [.transcribe], language: "en")
        while tools.jobs.contains(where: { [.queued, .running].contains($0.status) }) {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let result = try XCTUnwrap(tools.jobs.first)
        XCTAssertEqual(result.status, .completed, result.errorMessage ?? "")
        let txt = try XCTUnwrap(result.outputPaths.first { $0.hasSuffix(".txt") })
        let text = try String(contentsOfFile: txt, encoding: .utf8)
        report(String(format: "transcribe (%@): %.1f s, %.1f× realtime, %d words",
                      URL(fileURLWithPath: modelPath).lastPathComponent, result.elapsedSeconds ?? 0,
                      result.speedFactor ?? 0, text.split(separator: " ").count))
        XCTAssertGreaterThan(text.split(separator: " ").count, 100)
    }

    @MainActor
    func testTorrentDownloadSpeed() async throws {
        let dir = try liveDirectory("torrent")
        guard let torrentPath = environment["MF_LIVE_TORRENT"] else { throw XCTSkip("MF_LIVE_TORRENT not set") }
        guard let daemon = TransmissionDaemon.findExecutable() else { throw XCTSkip("transmission not installed") }
        let service = TorrentService(
            defaultDownloadDirectory: dir, historyURL: dir.appendingPathComponent("history.json"),
            daemonFactory: {
                TransmissionDaemon(configuration: .init(executable: daemon, configDirectory: dir.appendingPathComponent("engine"),
                                                        downloadDirectory: dir))
            })
        defer { service.shutdown() }
        service.isObserved = true
        let started = Date()
        let record = try await service.add(try .metainfo(fileAt: URL(fileURLWithPath: torrentPath)),
                                           seedPolicy: .stopWhenDone, selectFiles: false)
        var peak: Int64 = 0
        while Date().timeIntervalSince(started) < 1_200 {
            await service.refresh()
            if let snapshot = service.torrents.first { peak = max(peak, snapshot.downloadRate) }
            if service.record(for: record.hash)?.manifestPath != nil { break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let elapsed = Date().timeIntervalSince(started)
        let snapshot = try XCTUnwrap(service.torrents.first)
        XCTAssertNotNil(service.record(for: record.hash)?.manifestPath, "did not finish in time")
        report(String(format: "torrent %@: %.0f MB in %.1f s, avg %.1f MB/s, peak %.1f MB/s, manifest %@",
                      snapshot.name, Double(snapshot.sizeWhenDone) / 1_048_576, elapsed,
                      Double(snapshot.sizeWhenDone) / 1_048_576 / elapsed, Double(peak) / 1_048_576,
                      service.record(for: record.hash)?.manifestPath != nil ? "yes" : "no"))
    }
}
#endif
