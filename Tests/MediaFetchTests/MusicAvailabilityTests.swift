import XCTest
@testable import MediaFetchCore
@testable import MediaFetchVideo

final class AvailabilityStubProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class MusicAvailabilityTests: XCTestCase {
    /// Shape of the real anonymous song-detail answer from the US (2026-10-02):
    /// 晴天 has no rights; 我不难过 is VIP-only (st -100 too, but subp 1) and
    /// downloads with a logged-in account; 明知故犯 plays.
    private let fixture = Data(#"""
    {"songs":[{"id":186016,"name":"晴天","fee":0,"noCopyrightRcmd":null},
              {"id":2700000001,"name":"我不难过","fee":1,"noCopyrightRcmd":null},
              {"id":3342319503,"name":"明知故犯","fee":8,"noCopyrightRcmd":null},
              {"id":42,"name":"下架","fee":0,"noCopyrightRcmd":{"type":1}}],
     "privileges":[{"id":186016,"st":-100,"pl":0,"cp":0,"subp":0},
                   {"id":2700000001,"st":-100,"pl":0,"cp":0,"subp":1},
                   {"id":3342319503,"st":0,"pl":320000,"cp":1,"subp":1},
                   {"id":42,"st":-200,"pl":0,"cp":0,"subp":1}],
     "code":200}
    """#.utf8)

    func testParseFlagsTracksWithoutRights() {
        let statuses = NetEaseAvailability.parse(fixture)
        XCTAssertEqual(statuses["186016"], .noRights)
        XCTAssertEqual(statuses["2700000001"], .available, "VIP-only tracks are not 'no rights'")
        XCTAssertEqual(statuses["3342319503"], .available)
        XCTAssertEqual(statuses["42"], .noRights, "noCopyrightRcmd also means no rights")
        XCTAssertEqual(NetEaseAvailability.parse(Data("oops".utf8)), [:])
    }

    func testDetailURLListsNumericIDsOnly() throws {
        let url = try XCTUnwrap(NetEaseAvailability.detailURL(ids: ["186016", "abc", "3342319503"]))
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "c" }?.value
        XCTAssertEqual(c, #"[{"id":186016},{"id":3342319503}]"#)
        XCTAssertEqual(url.host, "music.163.com")
    }

    func testNoMediaLinksBecomesNoRightsMessageOnNetEaseOnly() {
        let stderr = "ERROR: [netease:song] 186016: No media links found; possibly due to geo restriction"
        let diagnosis = EngineDiagnostics.diagnose(stderr)
        XCTAssertEqual(EngineDiagnostics.platformHint(for: diagnosis, platform: .netease, output: stderr), NetEaseAvailability.noRightsMessage)
        XCTAssertNil(EngineDiagnostics.platformHint(for: diagnosis, platform: .youtube, output: stderr))
    }

    func testRestrictedEntriesOnOutline() {
        let entry = CollectionEntry(index: 3, mediaID: "186016", title: "晴天", url: "http://music.163.com/#/song?id=186016",
                                    duration: nil, chapterNumber: nil, chapterTitle: nil)
        var outline = CollectionOutline(id: "18905", title: "叶惠美", extractor: "netease:album", entries: [entry])
        XCTAssertNil(outline.restriction(for: entry))
        outline.restricted[entry.id] = NetEaseAvailability.noRightsMessage
        XCTAssertEqual(outline.restriction(for: entry), NetEaseAvailability.noRightsMessage)
    }

    func testClientSendsNoCookiesAndToleratesFailures() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AvailabilityStubProtocol.self]
        let client = NetEaseAvailabilityClient(session: URLSession(configuration: configuration))
        AvailabilityStubProtocol.requests = []
        AvailabilityStubProtocol.statusCode = 200
        AvailabilityStubProtocol.body = fixture
        let statuses = await client.statuses(for: ["186016", "3342319503", "186016"])
        XCTAssertEqual(statuses["186016"], .noRights)
        XCTAssertEqual(AvailabilityStubProtocol.requests.count, 1, "duplicates collapse into one batch")
        XCTAssertNil(AvailabilityStubProtocol.requests.first?.value(forHTTPHeaderField: "Cookie"))

        AvailabilityStubProtocol.statusCode = 503
        let failed = await client.statuses(for: ["186016"])
        XCTAssertEqual(failed, [:], "unknown means available; the download reports the truth")
    }
}
