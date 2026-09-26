#if !MEDIAFETCH_STORE_PROFILE
import XCTest
@testable import MediaFetchCore
@testable import MediaFetchTools
@testable import MediaFetchResolve

final class ToolsTests: XCTestCase {
    private let probe = MediaProbe(duration: 10, videoCodec: "vp9", width: 3840, height: 2160, audioCodec: "opus")

    func testProxyPlanUsesHardwareProResHalfResAndNeverOverwrites() {
        let plan = FFmpegCommandBuilder.plan(input: URL(fileURLWithPath: "/m/clip.webm"), preset: .proresProxy, probe: probe)
        XCTAssertEqual(plan.output.path, "/m/clip.proxy.mov")
        XCTAssertTrue(plan.arguments.contains("-n"), "never overwrite existing files")
        XCTAssertTrue(plan.arguments.contains("prores_videotoolbox"))
        XCTAssertTrue(plan.arguments.contains("proxy"))
        XCTAssertTrue(plan.arguments.contains { $0.contains("ih/2") })
        XCTAssertEqual(plan.arguments.last, "/m/clip.proxy.mov")
        let software = FFmpegCommandBuilder.plan(input: URL(fileURLWithPath: "/m/clip.webm"), preset: .proresProxy,
                                                 probe: probe, hardwareProRes: false)
        XCTAssertTrue(software.arguments.contains("prores_ks"))
    }

    func testAudioExtractionCopiesWhenContainerAllows() {
        let copy = FFmpegCommandBuilder.plan(input: URL(fileURLWithPath: "/m/a.webm"), preset: .extractAudio, probe: probe)
        XCTAssertEqual(copy.output.pathExtension, "ogg")
        XCTAssertTrue(copy.arguments.contains("copy"))
        let odd = MediaProbe(duration: 1, videoCodec: nil, width: nil, height: nil, audioCodec: "ac3")
        let pcm = FFmpegCommandBuilder.plan(input: URL(fileURLWithPath: "/m/a.mkv"), preset: .extractAudio, probe: odd)
        XCTAssertEqual(pcm.output.pathExtension, "wav")
        XCTAssertTrue(pcm.arguments.contains("pcm_s24le"))
    }

    func testProbeParsingIgnoresCoverArt() throws {
        let json = #"{"format":{"duration":"12.5"},"streams":[{"codec_type":"video","codec_name":"mjpeg","disposition":{"attached_pic":1}},{"codec_type":"video","codec_name":"av1","width":1920,"height":1080,"disposition":{"attached_pic":0}},{"codec_type":"audio","codec_name":"aac"}]}"#
        let parsed = try XCTUnwrap(MediaProbe(ffprobeJSON: Data(json.utf8)))
        XCTAssertEqual(parsed, MediaProbe(duration: 12.5, videoCodec: "av1", width: 1920, height: 1080, audioCodec: "aac"))
    }

    func testProgressParsers() {
        XCTAssertEqual(FFmpegCommandBuilder.progressSeconds(from: "out_time_us=2500000"), 2.5)
        XCTAssertNil(FFmpegCommandBuilder.progressSeconds(from: "frame=10"))
        XCTAssertEqual(ToolEngine.whisperProgress(from: "whisper_print_progress_callback: progress =  45%"), 0.45)
        XCTAssertEqual(ToolEngine.whisperProgress(from: "whisper_print_progress_callback: progress = 272%"), 1)
    }

    func testModelMagicAndSymlinkReuse() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mf-models-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("small.bin")
        try Data([0x6C, 0x6D, 0x67, 0x67, 1, 2]).write(to: fake)
        let html = dir.appendingPathComponent("page.bin")
        try Data("<html>".utf8).write(to: html)
        XCTAssertTrue(WhisperModelStore.isValidModel(fake))
        XCTAssertThrowsError(try WhisperModelStore.linkExistingModel(at: html, in: dir.appendingPathComponent("store")))
        let link = try WhisperModelStore.linkExistingModel(at: fake, in: dir.appendingPathComponent("store"))
        XCTAssertEqual(link.lastPathComponent, "ggml-small.bin")
        XCTAssertEqual(WhisperModelStore.installed(in: dir.appendingPathComponent("store")).map(\.lastPathComponent), ["ggml-small.bin"])
    }

    func testDerivativeProxiesFeedResolvePlanner() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mf-deriv-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mp4 = Data([0, 0, 0, 0x18]) + Data("ftypisom".utf8) + Data(count: 16)
        try mp4.write(to: dir.appendingPathComponent("clip.mp4"))
        try mp4.write(to: dir.appendingPathComponent("clip.proxy.mov"))
        try DerivativeLog.append(DerivativeRecord(
            tool: "ffmpeg", preset: "proresProxy", role: .proxy,
            source: .init(relativePath: "clip.mp4", byteSize: 28, sha256: "a"),
            output: .init(relativePath: "clip.proxy.mov", byteSize: 28, sha256: "b"),
            command: ["ffmpeg"], engineVersion: "8", elapsedSeconds: 1), in: dir)
        let request = try ResolveImportPlanner.plan(packageDirectory: dir)
        XCTAssertEqual(request.clips.count, 1, "the proxy is linked, not imported as a second clip")
        XCTAssertEqual(request.clips.first?.proxy.map { ($0 as NSString).lastPathComponent }, "clip.proxy.mov")
    }

    // MARK: Real ffmpeg / whisper end to end

    @MainActor
    func testRealToolchainProducesOutputsAndDerivativeLog() async throws {
        let toolchain = ToolToolchain.local()
        guard let ffmpeg = toolchain.ffmpeg, toolchain.ffprobe != nil else { throw XCTSkip("ffmpeg not installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mf-tools-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("sample.mp4")
        let maker = Process()
        maker.executableURL = ffmpeg
        maker.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=2560x1440:rate=25",
                           "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "3",
                           "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-shortest", source.path]
        try maker.run()
        maker.waitUntilExit()
        XCTAssertEqual(maker.terminationStatus, 0)

        let modelDir = dir.appendingPathComponent("models")
        let testModel = URL(fileURLWithPath: "/opt/homebrew/share/whisper-cpp/for-tests-ggml-tiny.bin")
        var presets: [ToolPreset] = [.proresProxy, .extractAudio, .gifPreview, .h264Proxy]
        let service = ToolService(toolchain: toolchain, historyURL: dir.appendingPathComponent("h.json"), modelDirectory: modelDir)
        if toolchain.whisper != nil, WhisperModelStore.isValidModel(testModel) {
            service.useExistingModel(at: testModel)
            presets.append(.transcribe)
        }
        service.enqueue(inputs: [source], presets: presets)
        for _ in 0..<600 {
            if service.jobs.allSatisfy({ [.completed, .failed, .cancelled].contains($0.status) }) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        for job in service.jobs {
            XCTAssertEqual(job.status, .completed, "\(job.preset): \(job.errorMessage ?? "")")
            XCTAssertNotNil(job.speedFactor)
        }
        let proxy = dir.appendingPathComponent("sample.proxy.mov")
        let proxyProbe = try ToolEngine.probe(proxy, toolchain: toolchain)
        XCTAssertEqual(proxyProbe.videoCodec, "prores")
        XCTAssertEqual(proxyProbe.height, 720, "1440p is halved for the proxy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sample.audio.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sample.preview.gif").path))
        let records = DerivativeLog.load(in: dir)
        XCTAssertTrue(records.contains { $0.role == .proxy && $0.output.relativePath == "sample.proxy.mov" })
        XCTAssertEqual(records.filter { $0.role == .proxy }.count, 2, "ProRes and H.264 proxies are both recorded")
        XCTAssertEqual(DerivativeLog.proxies(in: dir).values.map { ($0 as NSString).lastPathComponent }, ["sample.proxy.mov"],
                       "Resolve links one proxy per clip; ProRes wins over H.264")

        // Running the same preset again must not overwrite the existing output.
        service.enqueue(inputs: [source], presets: [.proresProxy])
        for _ in 0..<200 {
            if service.jobs.last?.status == .failed || service.jobs.last?.status == .completed { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(service.jobs.last?.status, .failed)
        XCTAssertTrue(service.jobs.last?.errorMessage?.contains("不会覆盖") == true)
    }
}
#endif
