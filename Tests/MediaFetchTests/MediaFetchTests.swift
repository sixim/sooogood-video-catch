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
