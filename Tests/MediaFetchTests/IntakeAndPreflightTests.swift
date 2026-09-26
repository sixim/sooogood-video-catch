import XCTest
@testable import MediaFetchCore
@testable import MediaFetchVideo

final class IntakeAndPreflightTests: XCTestCase {
    func testClassifierRoutesMixedInput() {
        let magnet = "magnet:?xt=urn:btih:\(String(repeating: "a", count: 40))&dn=x"
        let items = InputClassifier.classify("""
        https://www.youtube.com/watch?v=abc  \(magnet)
        /Users/me/Movies/clip.MOV ~/Downloads/show.torrent https://example.com/files/a.torrent
        hello https://www.youtube.com/watch?v=abc
        """)
        XCTAssertEqual(items.count, 6, "duplicates collapse")
        XCTAssertEqual(items[0], .webMedia(URL(string: "https://www.youtube.com/watch?v=abc")!))
        XCTAssertEqual(items[1], .magnet(magnet))
        XCTAssertEqual(items[2].destination, .tools)
        XCTAssertEqual(items[3].destination, .torrent)
        XCTAssertEqual(items[4].destination, .torrent)
        XCTAssertEqual(items[5], .unsupported("hello"))
        XCTAssertEqual(InputClassifier.primaryDestination(of: items), .torrent)
        XCTAssertEqual(InputClassifier.primaryDestination(of: [.webMedia(URL(string: "https://a.b")!), .magnet("m")]), .video,
                       "ties prefer video")
        XCTAssertEqual(InputClassifier.primaryDestination(of: [.unsupported("x")]), .none)
    }

    func testPreflightVerdicts() {
        let ok = BatchPreflight.Item(url: "a", estimatedBytes: 1_000)
        let bad = BatchPreflight.Item(url: "b", problem: .needsLogin)
        XCTAssertEqual(BatchPreflight.evaluate([ok], availableBytes: 10_000).verdict, .go)
        XCTAssertEqual(BatchPreflight.evaluate([ok, bad], availableBytes: 10_000).verdict, .goWithSkips)
        XCTAssertEqual(BatchPreflight.evaluate([bad], availableBytes: 10_000).verdict, .stop)
        let tight = BatchPreflight.evaluate([ok], availableBytes: 1_050)
        XCTAssertFalse(tight.fitsOnDisk, "10% headroom is required")
        XCTAssertEqual(tight.verdict, .stop)
        XCTAssertEqual(BatchPreflight.evaluate([ok, .init(url: "c")], availableBytes: nil).unknownSizeCount, 1)
        XCTAssertEqual(BatchPreflight.problem(forEngineOutput: "Sign in to confirm you're not a bot"), .needsLogin)
        XCTAssertEqual(BatchPreflight.problem(forEngineOutput: "HTTP Error 404"), .unavailable)
    }

#if !MEDIAFETCH_STORE_PROFILE
    func testEstimatedBytesUsesSelectedFormats() {
        XCTAssertEqual(BatchPreflightRunner.estimatedBytes(["requested_formats": [["filesize": 10], ["filesize_approx": 5]]]), 15)
        XCTAssertNil(BatchPreflightRunner.estimatedBytes(["requested_formats": [["filesize": 10], ["vcodec": "x"]]]),
                     "a partial sum would understate the size")
        XCTAssertEqual(BatchPreflightRunner.estimatedBytes(["filesize_approx": 7]), 7)
        XCTAssertEqual(BatchPreflightRunner.mediaKey(platform: "youtube:tab", id: "x"), "youtube|x")
    }

    func testRunnerClassifiesEachURLAgainstSyntheticEngine() async throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/test_preflight_engine.sh")
        let toolchain = VideoToolchain(ytDLPURL: script, ffmpegURL: nil, allowsBrowserCookies: true,
                                       processEnvironment: ["PATH": "/usr/bin:/bin"])
        let urls = ["https://youtu.be/ok", "https://youtu.be/gone", "https://vimeo.com/login",
                    "https://youtu.be/dup", "https://www.netflix.com/watch/1", "https://example.com/done",
                    "https://vimeo.com/inapp"].map { URL(string: $0)! }
        let report = await BatchPreflightRunner(toolchain: toolchain).run(
            urls: urls, profile: .highest, destination: FileManager.default.temporaryDirectory,
            knownMediaKeys: ["youtube|dup1"], knownSourceURLs: ["https://example.com/done"],
            cookieArguments: { $0.absoluteString.contains("inapp") ? nil : [] }
        )
        XCTAssertEqual(report.items.map(\.url), urls.map(\.absoluteString), "order preserved")
        XCTAssertEqual(report.items.map(\.problem), [nil, .unavailable, .needsLogin, .alreadyDownloaded, .blocked, .alreadyDownloaded, nil])
        XCTAssertEqual(report.items[0].estimatedBytes, 1_500)
        XCTAssertEqual(report.items[0].title, "OK")
        XCTAssertEqual(report.readyCount, 2)
        XCTAssertEqual(report.verdict, .goWithSkips)
    }
#endif
}
