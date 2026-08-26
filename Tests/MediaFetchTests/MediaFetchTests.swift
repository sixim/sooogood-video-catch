import XCTest
@testable import MediaFetch

final class MediaFetchTests: XCTestCase {
    func testURLValidatorAcceptsWebURLs() {
        XCTAssertEqual(
            URLValidator.validatedMediaURL(from: "  https://www.youtube.com/watch?v=test  ")?.host,
            "www.youtube.com"
        )
    }

    func testURLValidatorRejectsLocalAndCommandInput() {
        XCTAssertNil(URLValidator.validatedMediaURL(from: "file:///etc/passwd"))
        XCTAssertNil(URLValidator.validatedMediaURL(from: "$(touch /tmp/nope)"))
        XCTAssertNil(URLValidator.validatedMediaURL(from: "not a link"))
    }

    func testVimeoDetection() {
        XCTAssertTrue(URLValidator.isVimeoURL("https://vimeo.com/1084537"))
        XCTAssertTrue(URLValidator.isVimeoURL("https://player.vimeo.com/video/1084537"))
        XCTAssertFalse(URLValidator.isVimeoURL("https://example.com/vimeo.com/1084537"))
    }

    func testBrowserCookieArgumentsAreExplicit() {
        XCTAssertEqual(BrowserCookieSource.safari.ytDLPArguments, ["--cookies-from-browser", "safari"])
        XCTAssertEqual(BrowserCookieSource.chrome.ytDLPArguments, ["--cookies-from-browser", "chrome"])
    }

    func testProgressParser() {
        let result = ProgressParser.parse("MF_PROGRESS| 42.5%|100|200|2.5MiB/s|12")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.fraction, 0.425, accuracy: 0.0001)
        XCTAssertEqual(result?.percentText, "42.5%")
        XCTAssertEqual(result?.speedText, "2.5MiB/s")
        XCTAssertEqual(result?.etaText, "12")
    }

    func testProfilesDoNotRequestTranscoding() {
        XCTAssertEqual(DownloadProfile.highest.formatSelector, "bv*+ba/b")
        XCTAssertEqual(DownloadProfile.sourceStreams.formatSelector, "bv,ba")
        XCTAssertTrue(DownloadProfile.compatibleMP4.formatSelector.contains("vcodec^=avc1"))
    }

    func testLinkInputParserHandlesMultipleLinksAndDeduplicates() {
        let links = LinkInputParser.URLs(from: """
        https://www.youtube.com/watch?v=one
        https://vimeo.com/123 https://www.youtube.com/watch?v=one
        invalid
        """)
        XCTAssertEqual(links.map(\.host), ["www.youtube.com", "vimeo.com"])
    }

    func testSHA256UsesWholeFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mediafetch-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(
            try ManifestWriter.sha256(url),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testManifestContainsProvenanceAndFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mediafetch-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("media".utf8).write(to: directory.appendingPathComponent("clip.mkv"))

        var job = DownloadJob(
            sourceURL: "https://example.com/video",
            profile: .highest,
            destination: directory,
            includeSidecars: true,
            includeSubtitles: true,
            browserCookieSource: nil
        )
        job.title = "Test Clip"
        let manifestURL = try ManifestWriter.write(
            job: job,
            packageDirectory: directory,
            platform: "test",
            mediaID: "abc123",
            selectedFormats: [SelectedFormatInfo(
                formatID: "v+a", resolution: "3840x2160", videoCodec: "av1",
                audioCodec: "opus", container: "mkv"
            )],
            ytDLPPath: "/usr/bin/true",
            ffmpegPath: nil
        )
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        XCTAssertEqual(json?["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json?["mediaID"] as? String, "abc123")
        XCTAssertEqual((json?["files"] as? [[String: Any]])?.count, 1)
        XCTAssertNotNil((json?["files"] as? [[String: Any]])?.first?["sha256"])
    }

    func testInterruptedHistoryRestoresAsPausedWithoutCookieContents() throws {
        var job = DownloadJob(
            sourceURL: "https://vimeo.com/123",
            profile: .highest,
            destination: FileManager.default.temporaryDirectory,
            includeSidecars: true,
            includeSubtitles: false,
            browserCookieSource: .safari
        )
        job.status = .downloading
        let data = try JobHistoryStore.encoded([job])
        let restored = try JobHistoryStore.restoredJobs(from: data)
        XCTAssertEqual(restored.first?.status, .paused)
        XCTAssertEqual(restored.first?.browserCookieSource, .safari)
        XCTAssertFalse(String(data: data, encoding: .utf8)?.contains("cookie_value") ?? true)
    }
}
