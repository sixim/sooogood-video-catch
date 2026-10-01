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

    /// Magnet path end to end: metadata fetch → file selection → download → stop → manifest.
    @MainActor
    func testMagnetWithFileSelection() async throws {
        let dir = try liveDirectory("magnet-\(Int(Date().timeIntervalSince1970))")
        guard let magnet = environment["MF_LIVE_MAGNET"], let source = TorrentSource.magnet(from: magnet) else {
            throw XCTSkip("MF_LIVE_MAGNET not set")
        }
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
        let record = try await service.add(source, seedPolicy: .stopWhenDone, selectFiles: true)
        XCTAssertTrue(record.awaitingFileSelection)
        var snapshot: TorrentSnapshot?
        while Date().timeIntervalSince(started) < 180 {
            await service.refresh()
            snapshot = service.torrents.first { $0.hash == record.hash }
            if snapshot?.hasMetadata == true && snapshot?.state == .stopped { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let withMetadata = try XCTUnwrap(snapshot, "no metadata")
        XCTAssertTrue(withMetadata.hasMetadata, "metadata not fetched in 3 min")
        XCTAssertEqual(withMetadata.state, .stopped, "waits paused for the user's file choice")
        report(String(format: "magnet metadata after %.1f s: %@ (%d files)", Date().timeIntervalSince(started),
                      withMetadata.name, withMetadata.files.count))
        try await service.confirmSelection(hash: record.hash, wantedIndices: Set(withMetadata.files.map(\.index)),
                                           highPriority: [0])
        var done = false
        while Date().timeIntervalSince(started) < 1_200 {
            await service.refresh()
            if service.record(for: record.hash)?.manifestPath != nil { done = true; break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        XCTAssertTrue(done, "did not complete")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        await service.refresh()
        let final = try XCTUnwrap(service.torrents.first { $0.hash == record.hash })
        report(String(format: "magnet complete in %.1f s, state after completion: %@ (stop-when-done), manifest: %@",
                      Date().timeIntervalSince(started), final.state.displayName,
                      service.record(for: record.hash)?.manifestPath ?? "-"))
        XCTAssertEqual(final.state, .stopped, "stop-when-done policy stops seeding")
    }

    /// Course flow with the app's engine: expand → enqueue viewable lessons → course-manifest.json.
    @MainActor
    func testCourseExpansionAndDownload() async throws {
        let dir = try liveDirectory("course-\(Int(Date().timeIntervalSince1970))")
        guard let courseURL = environment["MF_LIVE_COURSE"].flatMap(URL.init(string:)) else { throw XCTSkip("MF_LIVE_COURSE not set") }
        let downloader = DownloaderService(jobs: [], toolchain: .local(), historyWriter: { _ in })
        let outline = try await downloader.expandCollection(courseURL, cookieSource: nil, usesInAppLogin: false)
        report("course \(outline.title): \(outline.entries.count) viewable, \(outline.unavailableCount) unavailable, isCourse=\(outline.isCourse)")
        let started = Date()
        XCTAssertEqual(downloader.enqueueCollection(outline, entries: outline.entries, profile: .compatibleMP4, destination: dir,
                                                    includeSidecars: false, includeSubtitles: false,
                                                    cookieSource: nil, usesInAppLogin: false), outline.entries.count)
        while Date().timeIntervalSince(started) < 900,
              downloader.jobs.contains(where: { ![.completed, .failed, .cancelled].contains($0.status) }) {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        for job in downloader.jobs {
            report("  \(job.status.rawValue): \(job.title ?? job.sourceURL) \(job.errorMessage ?? "")")
        }
        let root = dir.appendingPathComponent(outline.rootFolderName)
        let manifestURL = root.appendingPathComponent(CollectionManifestWriter.courseFileName)
        let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: manifestURL))
        let entries = try XCTUnwrap(manifest["entries"]?.arrayValue)
        report("course-manifest.json: kind=\(manifest["kind"]?.stringValue ?? "-"), entries=\(entries.map { "\($0["index"]?.intValue ?? 0):\($0["status"]?.stringValue ?? "")" })")
        let tree = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".mp4") || $0.hasSuffix("manifest.json") }.sorted()
        report("tree: \(tree)")
        XCTAssertEqual(manifest["kind"]?.stringValue, "course")
        XCTAssertTrue(entries.allSatisfy { $0["status"]?.stringValue == "completed" })
    }

    /// Music path with the app's engine: inspect, expand a chart, download, verify tags/cover/lyrics.
    @MainActor
    func testNetEaseMusicPipeline() async throws {
        let dir = try liveDirectory("music-\(Int(Date().timeIntervalSince1970))")
        let downloader = DownloaderService(jobs: [], toolchain: .local(), historyWriter: { _ in })
        let single = try await downloader.inspectMusic(URL(string: "https://music.163.com/song?id=1973665667")!, cookieSource: nil, usesInAppLogin: false)
        report("inspect: \(single.title) — \(single.artistLine) — tiers \(single.availableTiers.map(\.displayName)) lyrics=\(single.hasLyrics)")
        let chart = try await downloader.expandCollection(URL(string: "https://music.163.com/discover/toplist?id=3778678")!, cookieSource: nil, usesInAppLogin: false)
        report("chart: \(chart.title) \(chart.entries.count) entries")
        let picked = Array(chart.entries.prefix(2))
        let started = Date()
        let queued = downloader.enqueueMusic(picked.map { ($0.url, $0.title, chart.context(for: $0)) }, quality: .best, layout: .artistAlbum,
                                             destination: dir, cookieSource: nil, usesInAppLogin: false)
        XCTAssertEqual(queued, 2)
        var lastSeen: [UUID: String] = [:]
        while Date().timeIntervalSince(started) < 300, downloader.jobs.contains(where: { ![.completed, .failed, .cancelled].contains($0.status) }) {
            for job in downloader.jobs {
                let key = "\(job.status.rawValue)/\(job.stage.map { "\($0)" } ?? "-")"
                if lastSeen[job.id] != key {
                    lastSeen[job.id] = key
                    report(String(format: "  t=%5.1fs %@ %@", Date().timeIntervalSince(started), job.title ?? "?", key))
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        for job in downloader.jobs {
            XCTAssertEqual(job.status, .completed, job.errorMessage ?? "")
            let package = URL(fileURLWithPath: try XCTUnwrap(job.manifestPath)).deletingLastPathComponent()
            let files = try FileManager.default.contentsOfDirectory(atPath: package.path).sorted()
            report("package \(package.path.replacingOccurrences(of: dir.path + "/", with: "")): \(files)")
            let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: job.manifestPath!)))
            report("  measured: \(job.audioQuality?.summary ?? "-") tier=\(job.audioQuality?.tier.displayName ?? "-") expected=\(job.audioQuality?.expectedTier?.displayName ?? "-") manifest.schema=\(manifest["schemaVersion"]?.intValue ?? 0) manifest.audio=\(manifest["audio"]?["codec"]?.stringValue ?? "-")")
            XCTAssertNotNil(job.audioQuality)
            XCTAssertEqual(manifest["audio"]?["codec"]?.stringValue, job.audioQuality?.codec)
            report("  attempts=\(job.attempts ?? 1) created→updated \(String(format: "%.1f", job.updatedAt.timeIntervalSince(job.createdAt)))s cmd=\(job.lastCommand ?? "-")")
            XCTAssertTrue(files.contains { $0.hasSuffix(".mp3") || $0.hasSuffix(".flac") })
            XCTAssertTrue(files.contains { $0.hasSuffix(".jpg") }, "cover kept")
            XCTAssertTrue(files.contains { $0.hasSuffix(".lrc") }, "lyrics kept")
        }
        report(String(format: "2 tracks in %.1f s", Date().timeIntervalSince(started)))
    }

    @MainActor
    func testMusicFirstJobLatency() async throws {
        let dir = try liveDirectory("latency-\(Int(Date().timeIntervalSince1970))")
        let downloader = DownloaderService(jobs: [], toolchain: .local(), historyWriter: { _ in })
        let steps = environment["MF_LATENCY_STEPS"] ?? ""
        if steps.contains("inspect") {
            _ = try await downloader.inspectMusic(URL(string: "https://music.163.com/song?id=1973665667")!, cookieSource: nil, usesInAppLogin: false)
        }
        if steps.contains("expand") {
            _ = try await downloader.expandCollection(URL(string: "https://music.163.com/discover/toplist?id=3778678")!, cookieSource: nil, usesInAppLogin: false)
        }
        let started = Date()
        downloader.enqueueMusic([("https://music.163.com/song?id=3342319503", "b", nil), ("https://music.163.com/song?id=1973665667", "a", nil)],
                                quality: .best, layout: .flat, destination: dir, cookieSource: nil, usesInAppLogin: false)
        var marks: [String] = []
        var last: [UUID: String] = [:]
        var lastLine = ""
        while Date().timeIntervalSince(started) < 200, downloader.jobs.contains(where: { ![.completed, .failed].contains($0.status) }) {
            for job in downloader.jobs {
                let key = "\(job.status.rawValue)/\(job.stage.map { "\($0)" } ?? "-")"
                if last[job.id] != key { last[job.id] = key; marks.append(String(format: "%.1f %@ %@", Date().timeIntervalSince(started), job.title ?? "", key)) }
            }
            if let line = downloader.recentMessages.last, line != lastLine {
                lastLine = line
                marks.append(String(format: "%.1f | %@", Date().timeIntervalSince(started), String(line.prefix(90))))
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        for mark in marks { report("  " + mark) }
        report("engine log tail: \(downloader.recentMessages.suffix(4))")
    }

    /// Free account + "lossless only": must fail fast with a clear reason, no retries.
    @MainActor
    func testLosslessOnlyFailsFastWithoutVIP() async throws {
        let dir = try liveDirectory("lossless-\(Int(Date().timeIntervalSince1970))")
        let downloader = DownloaderService(jobs: [], toolchain: .local(), historyWriter: { _ in })
        let started = Date()
        downloader.enqueueMusic([("https://music.163.com/song?id=1973665667", "x", nil)], quality: .losslessOnly, layout: .flat,
                                destination: dir, cookieSource: nil, usesInAppLogin: false)
        while Date().timeIntervalSince(started) < 120, downloader.jobs.contains(where: { ![.completed, .failed].contains($0.status) }) {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let job = try XCTUnwrap(downloader.jobs.first)
        report(String(format: "lossless-only on free account: %@ after %.1f s, attempts %d: %@", job.status.rawValue,
                      Date().timeIntervalSince(started), job.attempts ?? 1, job.errorMessage ?? "-"))
        XCTAssertEqual(job.status, .failed)
        XCTAssertEqual(job.attempts ?? 1, 1, "no pointless retries")
        XCTAssertTrue(job.errorMessage?.contains("只要无损") == true)
    }

    /// Custom template + embedded lyrics on a real NetEase track.
    @MainActor
    func testMusicLyricsAndCustomTemplate() async throws {
        let dir = try liveDirectory("tags-\(Int(Date().timeIntervalSince1970))")
        let downloader = DownloaderService(jobs: [], toolchain: .local(), historyWriter: { _ in })
        let started = Date()
        downloader.enqueueMusic([("https://music.163.com/song?id=1973665667", "x", nil)], quality: .best, layout: .custom,
                                destination: dir, cookieSource: nil, usesInAppLogin: false, nameTemplate: "{artist}/{title}")
        while Date().timeIntervalSince(started) < 120, downloader.jobs.contains(where: { ![.completed, .failed].contains($0.status) }) {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let job = try XCTUnwrap(downloader.jobs.first)
        XCTAssertEqual(job.status, .completed, job.errorMessage ?? "")
        let audio = try XCTUnwrap(job.completedFiles.first { $0.hasSuffix(".mp3") })
        report("custom template path: \(audio.replacingOccurrences(of: dir.path + "/", with: ""))")
        let probe = Process(); let pipe = Pipe()
        probe.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
        probe.arguments = ["-v", "error", "-show_entries", "format_tags", "-of", "json", audio]
        probe.standardOutput = pipe
        try probe.run()
        let tags = try JSONDecoder().decode(JSONValue.self, from: pipe.fileHandleForReading.readDataToEndOfFile())["format"]?["tags"]?.objectValue ?? [:]
        probe.waitUntilExit()
        let lyrics = tags.first { $0.key.lowercased().hasPrefix("lyrics") }?.value.stringValue ?? ""
        report("embedded lyrics: \(lyrics.split(separator: "\n").prefix(2).joined(separator: " / ")) (\(lyrics.split(separator: "\n").count) lines); title=\(tags["title"]?.stringValue ?? "-") artist=\(tags["artist"]?.stringValue ?? "-")")
        XCTAssertFalse(lyrics.isEmpty)
        XCTAssertFalse(lyrics.contains("[00:"), "plain text, timestamps stripped")
        XCTAssertEqual(audio.replacingOccurrences(of: dir.path + "/", with: "").split(separator: "/").count, 3)
        // Manifest hash is of the final (tagged) file.
        let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: job.manifestPath!)))
        let recorded = manifest["files"]?.arrayValue?.first { ($0["relativePath"]?.stringValue ?? "").hasSuffix(".mp3") }?["sha256"]?.stringValue
        XCTAssertEqual(recorded, try ManifestWriter.sha256(URL(fileURLWithPath: audio)))
    }
}
#endif
