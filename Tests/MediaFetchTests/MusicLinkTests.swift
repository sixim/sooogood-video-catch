import XCTest
@testable import MediaFetchCore
@testable import MediaFetchVideo
#if !MEDIAFETCH_STORE_PROFILE
import WebKit
@testable import MediaFetch
#endif

/// Answers redirects from a fixed table; never touches the network.
final class RedirectStubProtocol: URLProtocol {
    nonisolated(unsafe) static var redirects: [String: String] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        if let target = Self.redirects[url.absoluteString], let next = URL(string: target) {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: next), redirectResponse: response)
            // Like a real server: if the client declines the redirect, the 3xx is the final response.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
        } else {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class MusicLinkTests: XCTestCase {
    private func canonical(_ string: String) -> String? { MusicLink.parse(URL(string: string)!)?.canonicalURL.absoluteString }

    func testNetEaseLinkShapesNormalizeToEngineForm() {
        XCTAssertEqual(canonical("https://music.163.com/#/song?id=1973665667"), "https://music.163.com/song?id=1973665667")
        XCTAssertEqual(canonical("https://music.163.com/song?id=1973665667&userid=1"), "https://music.163.com/song?id=1973665667")
        XCTAssertEqual(canonical("https://y.music.163.com/m/song?id=42&uct2=x"), "https://music.163.com/song?id=42")
        XCTAssertEqual(canonical("https://music.163.com/#/playlist?id=3778678"), "https://music.163.com/playlist?id=3778678")
        XCTAssertEqual(canonical("https://music.163.com/#/my/m/music/playlist?id=99"), "https://music.163.com/playlist?id=99")
        XCTAssertEqual(canonical("https://music.163.com/#/discover/toplist?id=3778678"), "https://music.163.com/discover/toplist?id=3778678")
        XCTAssertEqual(canonical("https://music.163.com/#/album?id=7"), "https://music.163.com/album?id=7")
        XCTAssertEqual(canonical("https://music.163.com/#/artist?id=6452"), "https://music.163.com/artist?id=6452")
        XCTAssertEqual(MusicLink.parse(URL(string: "https://music.163.com/#/djradio?id=5")!)?.kind, .radio)
        XCTAssertNil(MusicLink.parse(URL(string: "https://music.163.com/#/song?id=abc")!))
        XCTAssertNil(MusicLink.parse(URL(string: "https://news.163.com/song?id=1")!), "only the music site counts")
    }

    func testQQLinkShapesNormalizeToEngineForm() {
        XCTAssertEqual(canonical("https://y.qq.com/n/ryqq/songDetail/000U7ztO08t2B7"), "https://y.qq.com/n/ryqq/songDetail/000U7ztO08t2B7")
        XCTAssertEqual(canonical("https://y.qq.com/n/yqq/song/000U7ztO08t2B7.html"), "https://y.qq.com/n/ryqq/songDetail/000U7ztO08t2B7")
        XCTAssertEqual(canonical("https://i.y.qq.com/v8/playsong.html?songmid=000U7ztO08t2B7&ADTAG=share"), "https://y.qq.com/n/ryqq/songDetail/000U7ztO08t2B7")
        XCTAssertEqual(canonical("https://i.y.qq.com/n2/m/share/details/taoge.html?id=7256912512"), "https://y.qq.com/n/ryqq/playlist/7256912512")
        XCTAssertEqual(canonical("https://i.y.qq.com/n2/m/share/details/album.html?albummid=002fRO0N4FftzY"), "https://y.qq.com/n/ryqq/albumDetail/002fRO0N4FftzY")
        XCTAssertEqual(canonical("https://y.qq.com/n/ryqq/toplist/26"), "https://y.qq.com/n/ryqq/toplist/26")
        XCTAssertEqual(MusicLink.parse(URL(string: "https://y.qq.com/n/ryqq/singer/0025NhlN2yWrP4")!)?.kind, .artist)
        XCTAssertNil(MusicLink.parse(URL(string: "https://y.qq.com/n/ryqq/playlist/notdigits")!))
        XCTAssertEqual(StreamingPlatform.detect(URL(string: "https://www.qq.com/news")!), .generic, "plain qq.com is not QQ Music")
    }

    func testShareTextExtractionHandlesCJKAndShortLinks() {
        let text = "分享Taylor Swift的单曲《Love Story》https://music.163.com/#/song?id=19292984&userid=1 (来自@网易云音乐)\n分享周杰伦的单曲《晴天》：https://c6.y.qq.com/base/fcgi-bin/u?__=AbCdEf，复制打开"
        let urls = LinkInputParser.URLs(from: text).map(\.absoluteString)
        XCTAssertEqual(urls, ["https://music.163.com/song?id=19292984", "https://c6.y.qq.com/base/fcgi-bin/u?__=AbCdEf"])
        XCTAssertTrue(MusicLink.needsRedirectResolution(URL(string: urls[1])!))
        XCTAssertTrue(MusicLink.needsRedirectResolution(URL(string: "http://163cn.tv/xyz")!))
        XCTAssertFalse(MusicLink.needsRedirectResolution(URL(string: "https://y.qq.com/n/ryqq/toplist/26")!))
    }

    func testCollectionsAndPlatformTraits() {
        XCTAssertTrue(CollectionDetector.looksLikeCollection(URL(string: "https://music.163.com/#/playlist?id=1")!))
        XCTAssertTrue(CollectionDetector.looksLikeCollection(URL(string: "https://y.qq.com/n/ryqq/albumDetail/x1")!))
        XCTAssertFalse(CollectionDetector.looksLikeCollection(URL(string: "https://music.163.com/#/song?id=1")!))
        XCTAssertTrue(StreamingPlatform.netease.isMusicService)
        XCTAssertTrue(StreamingPlatform.browserLoginPlatforms.contains(.qqmusic))
        XCTAssertEqual(EngineDiagnostics.diagnose("ERROR: [qqmusic] x: This video is only available for registered users.")?.cause, .needsLogin)
    }

    private func cookie(_ domain: String, _ name: String) -> HTTPCookie {
        HTTPCookie(properties: [.domain: domain, .path: "/", .name: name, .value: "v", .secure: "TRUE"])!
    }

    func testQQExportsOnlyMusicSessionCookiesNotAccountIdentity() throws {
        let data = try XCTUnwrap(SiteSessionCookies.export([
            cookie(".qq.com", "uin"), cookie(".qq.com", "qqmusic_key"), cookie(".y.qq.com", "fqm_pvqid"),
            cookie(".qq.com", "skey"), cookie(".qq.com", "p_skey"), cookie(".graph.qq.com", "pt4_token"),
            cookie(".qqmusic.evil.com", "uin")
        ], for: .qqmusic))
        let text = String(decoding: data, as: UTF8.self)
        for name in ["\tuin\t", "\tqqmusic_key\t", "\tfqm_pvqid\t"] { XCTAssertTrue(text.contains(name), name) }
        for name in ["skey", "p_skey", "pt4_token", "evil"] { XCTAssertFalse(text.contains(name), name) }

        let netease = String(decoding: try XCTUnwrap(SiteSessionCookies.export([
            cookie(".music.163.com", "MUSIC_U"), cookie(".163.com", "NTES_SESS"), cookie(".mail.163.com", "x")
        ], for: .netease)), as: UTF8.self)
        XCTAssertTrue(netease.contains("MUSIC_U"))
        XCTAssertFalse(netease.contains("NTES_SESS"), "163.com account cookies are not music session")
    }

    func testResolverFollowsOnlyMusicHostsToACanonicalLink() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectStubProtocol.self]
        let resolver = MusicLinkResolver(session: URLSession(configuration: configuration))
        RedirectStubProtocol.redirects = [
            "http://163cn.tv/abc": "https://y.music.163.com/m/song?id=1973665667&uct2=x",
            "https://c6.y.qq.com/base/fcgi-bin/u?__=ok": "https://i.y.qq.com/v8/playsong.html?songmid=000U7ztO08t2B7",
            "http://163cn.tv/evil": "https://phishing.example.com/login"
        ]
        let netease = await resolver.resolve(URL(string: "http://163cn.tv/abc")!)
        XCTAssertEqual(netease?.absoluteString, "https://music.163.com/song?id=1973665667")
        let qq = await resolver.resolve(URL(string: "https://c6.y.qq.com/base/fcgi-bin/u?__=ok")!)
        XCTAssertEqual(qq?.absoluteString, "https://y.qq.com/n/ryqq/songDetail/000U7ztO08t2B7")
        let evil = await resolver.resolve(URL(string: "http://163cn.tv/evil")!)
        XCTAssertNil(evil, "redirects off music hosts are not followed")
        let text = await resolver.resolveShortLinks(in: "《晴天》http://163cn.tv/abc 来自网易云")
        XCTAssertEqual(LinkInputParser.URLs(from: text).map(\.absoluteString), ["https://music.163.com/song?id=1973665667"])
    }

#if !MEDIAFETCH_STORE_PROFILE
    @MainActor
    func testEveryLoginPlatformHasAnInAppSession() {
        // Regression: Udemy was a login platform without a session store ID and crashed.
        for platform in StreamingPlatform.browserLoginPlatforms {
            let session = InAppSiteSession(platform: platform, dataStore: .nonPersistent())
            XCTAssertEqual(session.platform, platform)
            XCTAssertNotNil(platform.browserLoginURL)
        }
    }
#endif
}
