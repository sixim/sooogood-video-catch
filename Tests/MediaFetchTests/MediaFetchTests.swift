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
}
