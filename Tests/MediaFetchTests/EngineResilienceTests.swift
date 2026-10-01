import XCTest
@testable import MediaFetchCore
@testable import MediaFetchVideo

final class EngineResilienceTests: XCTestCase {
    // MARK: Diagnosis

    func testFrequentFailuresMapToCauseAndSingleAction() {
        let cases: [(String, EngineFailureCause, EngineRemedy)] = [
            ("ERROR: [youtube] abc: Sign in to confirm you're not a bot", .botCheck, .signIn),
            ("WARNING: [youtube] abc: YouTube is forcing SABR streaming", .sabrOnly, .updateEngine),
            ("ERROR: HTTP Error 429: Too Many Requests", .rateLimited, .waitAndRetry),
            ("ERROR: unable to write data: [Errno 28] No space left on device", .diskFull, .freeDiskSpace),
            ("ERROR: [vimeo] 1: This video only works when logged-in", .needsLogin, .signIn),
            ("ERROR: [youtube] abc: Private video. Sign in if you've been granted access", .needsLogin, .signIn),
            ("ERROR: [generic] Unable to handshake: SSLV3_ALERT_HANDSHAKE_FAILURE", .tlsFingerprint, .updateEngine),
            ("ERROR: [youtube] abc: nsig extraction failed", .extractorOutdated, .updateEngine),
            ("ERROR: [youtube] abc: Video unavailable", .unavailable, .none),
            ("ERROR: Unsupported URL: https://example.com", .unsupportedURL, .none),
            ("ERROR: [x] This video is DRM protected", .drmProtected, .none)
        ]
        for (stderr, cause, remedy) in cases {
            let diagnosis = EngineDiagnostics.diagnose(stderr)
            XCTAssertEqual(diagnosis?.cause, cause, stderr)
            XCTAssertEqual(diagnosis?.remedy, remedy, stderr)
        }
        XCTAssertNil(EngineDiagnostics.diagnose("ERROR: something nobody has seen before"))
    }

    func testTransientGlitchesAreRecognisedForQuietRetry() {
        // Captured: yt-dlp qqmusic _download_init_data when the page fetch fails.
        XCTAssertTrue(EngineDiagnostics.isTransientGlitch("ERROR: expected string or bytes-like object, got 'bool'"))
        XCTAssertTrue(EngineDiagnostics.isTransientGlitch("ERROR: Unable to download webpage: HTTP Error 502: Bad Gateway"))
        XCTAssertFalse(EngineDiagnostics.isTransientGlitch("ERROR: [qqmusic] x: This video is only available for registered users."))
        XCTAssertFalse(EngineDiagnostics.isTransientGlitch("ERROR: Video unavailable"))
    }

    func testRateLimitIsNeverTerminalButRemovedVideoIs() {
        XCTAssertFalse(EngineDiagnostics.isTerminal("HTTP Error 429 ... Video unavailable"))
        XCTAssertTrue(EngineDiagnostics.isTerminal("ERROR: HTTP Error 404: Not Found"))
        XCTAssertTrue(EngineDiagnostics.isTerminal("This video has been removed by the uploader"))
    }

    // MARK: Retry policy

    func testSABRWalksClientCascadeAndStopsAtBudget() throws {
        let sabr = "YouTube is forcing SABR streaming"
        var state = EngineAttemptState()
        let first = try XCTUnwrap(RetryPolicy.next(after: sabr, state: state, isYouTube: true))
        XCTAssertEqual(first.nextState.youtubePlayerClient, "default,mweb")
        XCTAssertEqual(first.nextState.attempt, 2)
        state = first.nextState
        let second = try XCTUnwrap(RetryPolicy.next(after: sabr, state: state, isYouTube: true))
        XCTAssertEqual(second.nextState.youtubePlayerClient, "default,android")
        XCTAssertNil(RetryPolicy.next(after: sabr, state: second.nextState, isYouTube: true))
    }

    func testNoFormatsAfterOurClientOverrideKeepsCascading() throws {
        var state = EngineAttemptState()
        state.attempt = 2
        state.youtubePlayerClient = "default,mweb"
        let decision = try XCTUnwrap(RetryPolicy.next(
            after: "ERROR: [youtube] abc: No video formats found!", state: state, isYouTube: true))
        XCTAssertEqual(decision.nextState.youtubePlayerClient, "default,android")
        XCTAssertNil(RetryPolicy.next(after: "ERROR: [youtube] abc: No video formats found!",
                                      state: EngineAttemptState(), isYouTube: true))
    }

    func testRateLimitBacksOffRotatesClientAndDropsSubtitles() throws {
        let decision = try XCTUnwrap(RetryPolicy.next(
            after: "ERROR: [youtube] abc: HTTP Error 429: Too Many Requests",
            state: EngineAttemptState(), isYouTube: true))
        XCTAssertGreaterThanOrEqual(decision.delaySeconds, 10)
        XCTAssertEqual(decision.nextState.youtubePlayerClient, "default,mweb")
        XCTAssertFalse(decision.nextState.subtitlesEnabled)
        XCTAssertTrue(decision.countsAsRateLimit)
    }

    func testSubtitleOnlyRateLimitRetriesQuicklyWithoutCountingSession() throws {
        let decision = try XCTUnwrap(RetryPolicy.next(
            after: "WARNING: Unable to download video subtitles for 'en': HTTP Error 429",
            state: EngineAttemptState(), isYouTube: true))
        XCTAssertEqual(decision.delaySeconds, 3)
        XCTAssertNil(decision.nextState.youtubePlayerClient)
        XCTAssertFalse(decision.countsAsRateLimit)
    }

    func testForbiddenForcesIPv4AndTerminalOrLoginErrorsDoNotRetry() throws {
        let forbidden = try XCTUnwrap(RetryPolicy.next(
            after: "ERROR: unable to download video data: HTTP Error 403: Forbidden",
            state: EngineAttemptState(), isYouTube: false))
        XCTAssertTrue(forbidden.nextState.forceIPv4)
        XCTAssertNil(RetryPolicy.next(after: "ERROR: Video unavailable", state: EngineAttemptState(), isYouTube: true))
        XCTAssertNil(RetryPolicy.next(after: "This video only works when logged-in", state: EngineAttemptState(), isYouTube: false))
        XCTAssertNil(RetryPolicy.next(after: "[Errno 28] No space left on device", state: EngineAttemptState(), isYouTube: false))
    }

    // MARK: Arguments

    private func job(_ url: String, subtitles: Bool = true) -> DownloadJob {
        DownloadJob(sourceURL: url, profile: .highest, destination: URL(fileURLWithPath: "/tmp"),
                    includeSidecars: false, includeSubtitles: subtitles, browserCookieSource: nil)
    }

    func testDownloadArgumentsCarryResilienceAndAttemptTuning() {
        var state = EngineAttemptState()
        state.youtubePlayerClient = "ios"
        state.forceIPv4 = true
        state.subtitlesEnabled = false
        let args = YtDLPArgumentBuilder.downloadArguments(
            job: job("https://www.youtube.com/watch?v=abc"), destination: URL(fileURLWithPath: "/tmp/out"),
            ffmpegPath: nil, state: state, sessionRateLimitCount: 1, cookieArguments: [])
        XCTAssertTrue(args.contains("--fragment-retries"))
        XCTAssertTrue(args.contains("exp=1:30"))
        XCTAssertEqual(args[args.firstIndex(of: "--concurrent-fragments")! + 1], "4")
        XCTAssertTrue(args.contains("youtube:player_client=ios;formats=dashy"))
        let plain = YtDLPArgumentBuilder.downloadArguments(
            job: job("https://www.youtube.com/watch?v=abc"), destination: URL(fileURLWithPath: "/tmp/out"),
            ffmpegPath: nil, state: EngineAttemptState(), sessionRateLimitCount: 0, cookieArguments: [])
        XCTAssertTrue(plain.contains("youtube:formats=dashy"), "fragmented DASH so concurrent fragments apply")
        XCTAssertFalse(YtDLPArgumentBuilder.analysisArguments(url: "https://www.youtube.com/watch?v=abc").contains { $0.contains("dashy") },
                       "analysis keeps the normal format list")
        XCTAssertTrue(args.contains("--force-ipv4"))
        XCTAssertTrue(args.contains("--sleep-requests"))
        XCTAssertFalse(args.contains("--write-subs"))
        XCTAssertEqual(args.last, "https://www.youtube.com/watch?v=abc")
    }

    func testNonYouTubeGetsNoYouTubeTuning() {
        let args = YtDLPArgumentBuilder.downloadArguments(
            job: job("https://vimeo.com/1"), destination: URL(fileURLWithPath: "/tmp"),
            ffmpegPath: nil, state: EngineAttemptState(), sessionRateLimitCount: 3, cookieArguments: [])
        XCTAssertFalse(args.contains { $0.contains("player_client") })
        XCTAssertFalse(args.contains("--throttled-rate"))
        XCTAssertEqual(args[args.firstIndex(of: "--concurrent-fragments")! + 1], "8")
    }

    func testRedactedCommandHidesCookieFilePath() {
        let line = YtDLPArgumentBuilder.redactedCommandLine(
            executable: "/opt/homebrew/bin/yt-dlp",
            arguments: ["--cookies", "/private/tmp/secret/cookies.txt", "--output", "%(title)s [%(id)s].%(ext)s", "https://x.y"])
        XCTAssertFalse(line.contains("secret"))
        XCTAssertTrue(line.contains("--cookies <cookies>"))
        XCTAssertTrue(line.contains("'%(title)s [%(id)s].%(ext)s'"))
    }

    // MARK: Signatures & versions

    func testSignatureRecognisesContainersAndErrorPages() {
        XCTAssertEqual(MediaSignature.detect(Data([0, 0, 0, 0x18]) + Data("ftypisom".utf8)), .isoBMFF)
        XCTAssertEqual(MediaSignature.detect(Data([0x1A, 0x45, 0xDF, 0xA3, 0x01])), .matroska)
        XCTAssertEqual(MediaSignature.detect(Data("  <!DOCTYPE html><html>".utf8)), .html)
        XCTAssertEqual(MediaSignature.detect(Data("WEBVTT\n\n".utf8)), .subtitle)
        XCTAssertTrue(MediaSignature.expectsMedia(URL(fileURLWithPath: "/a/b.MKV")))
        XCTAssertFalse(MediaSignature.expectsMedia(URL(fileURLWithPath: "/a/b.info.json")))
    }

    func testManifestRefusesHTMLDisguisedAsVideo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mf-sig-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("<!doctype html><title>403</title>".utf8).write(to: dir.appendingPathComponent("clip.mp4"))
        XCTAssertThrowsError(try ManifestWriter.write(
            job: job("https://vimeo.com/1"), packageDirectory: dir, platform: nil, mediaID: nil,
            selectedFormats: [], ytDLPPath: "/usr/bin/true", ffmpegPath: nil))
    }

    func testEngineVersionFloorAndStaleness() {
        let now = EngineVersion(year: 2026, month: 9, day: 25).date!
        XCTAssertEqual(EngineVersion("2026.08.19.232012 nightly")?.description, "2026.08.19")
        XCTAssertNil(EngineVersion("garbage"))
        XCTAssertEqual(EngineHealthStatus.evaluate(versionOutput: "2026.09.01", now: now), .current(EngineVersion("2026.09.01")!))
        if case .stale(_, let days) = EngineHealthStatus.evaluate(versionOutput: "2026.08.19", now: now) {
            XCTAssertEqual(days, 37, "older than 30 days suggests brew upgrade")
        } else { XCTFail("2026.08.19 is stale on 2026-09-25") }
        XCTAssertEqual(EngineHealthStatus.evaluate(versionOutput: "2026.05.01", now: now), .belowMinimum(EngineVersion("2026.05.01")!))
        if case .stale = EngineHealthStatus.evaluate(versionOutput: "2026.06.10", now: now) {} else { XCTFail("expected stale") }
        XCTAssertEqual(EngineHealthStatus.evaluate(versionOutput: nil), .missing)
    }

    func testHistoryWithoutEngineFieldsStillDecodes() throws {
        let data = try JobHistoryStore.encoded([job("https://vimeo.com/1")])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        for key in ["attempts", "youtubePlayerClient", "diagnosis", "lastCommand", "retryNote"] {
            object[0].removeValue(forKey: key)
        }
        let restored = try JobHistoryStore.restoredJobs(from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(restored.first?.attempts)
    }

    // MARK: End-to-end with a synthetic engine

#if !MEDIAFETCH_STORE_PROFILE
    @MainActor
    func testQueueRetriesSABRWithNextClientAndRecordsItInManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mf-retry-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = root.appendingPathComponent("report")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/test_retry_engine.sh")
        let toolchain = VideoToolchain(
            ytDLPURL: script, ffmpegURL: URL(fileURLWithPath: "/usr/bin/true"), allowsBrowserCookies: true,
            processEnvironment: ["PATH": "/usr/bin:/bin", "MF_TEST_REPORT": report.path,
                                 "MF_TEST_STATE": root.appendingPathComponent("state").path])
        let downloader = DownloaderService(jobs: [], toolchain: toolchain, historyWriter: { _ in })
        downloader.retryNanosecondsPerSecond = 1_000_000
        let url = "https://www.youtube.com/watch?v=abc"
        XCTAssertEqual(downloader.enqueue(url, profile: .compatibleMP4, destination: root,
                                          includeSidecars: false, includeSubtitles: false), 1)
        for _ in 0..<400 {
            if downloader.jobs.first?.status == .completed || downloader.jobs.first?.status == .failed { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let job = try XCTUnwrap(downloader.jobs.first)
        XCTAssertEqual(job.status, .completed, job.errorMessage ?? "")
        XCTAssertEqual(job.attempts, 2)
        let calls = try String(contentsOf: report, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(calls.count, 2)
        XCTAssertFalse(calls[0].contains("player_client"))
        XCTAssertTrue(calls[0].contains("youtube:formats=dashy"))
        XCTAssertTrue(calls[1].contains("youtube:player_client=default,mweb;formats=dashy"))
        let manifest = try XCTUnwrap(job.manifestPath)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: manifest))) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 4)
        let engine = try XCTUnwrap(object["engine"] as? [String: Any])
        XCTAssertEqual(engine["attempts"] as? Int, 2)
        XCTAssertEqual(engine["youtubePlayerClient"] as? String, "default,mweb")
        let files = try XCTUnwrap(object["files"] as? [[String: Any]])
        XCTAssertEqual(files.first?["signature"] as? String, "isoBMFF")
    }
#endif
}
