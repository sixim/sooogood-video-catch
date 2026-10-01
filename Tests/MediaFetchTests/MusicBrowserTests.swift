#if !MEDIAFETCH_STORE_PROFILE
import XCTest
import WebKit
@testable import MediaFetch
@testable import MediaFetchCore

final class MusicBrowserTests: XCTestCase {
    @MainActor
    func testNavigationStaysOnPlatformHosts() {
        XCTAssertTrue(MusicBrowserModel.isAllowedHost("music.163.com", for: .netease))
        XCTAssertTrue(MusicBrowserModel.isAllowedHost("p2.music.126.net", for: .netease))
        XCTAssertTrue(MusicBrowserModel.isAllowedHost("y.qq.com", for: .qqmusic))
        XCTAssertTrue(MusicBrowserModel.isAllowedHost("open.weixin.qq.com", for: .qqmusic))
        XCTAssertFalse(MusicBrowserModel.isAllowedHost("evil-163.com", for: .netease))
        XCTAssertFalse(MusicBrowserModel.isAllowedHost("music.163.com.evil.test", for: .netease))
        XCTAssertFalse(MusicBrowserModel.isAllowedHost("y.qq.com", for: .netease), "each platform keeps its own hosts")
        XCTAssertEqual(MusicBrowserView.kindName(.toplist), "排行榜")
    }

    /// Real pages in a throwaway WebKit store (opt-in): the SPA URL is observed
    /// and becomes the download target.
    @MainActor
    func testLivePagesBecomeDownloadTargets() async throws {
        guard ProcessInfo.processInfo.environment["MF_LIVE_NETWORK"] == "1" else { throw XCTSkip("live disabled") }
        let store = StreamingSiteLoginStore()
        let model = MusicBrowserModel(logins: store, platform: .netease, dataStoreProvider: { _ in .nonPersistent() })
        model.activate(.netease)
        model.activeWebView.load(URLRequest(url: URL(string: "https://music.163.com/#/discover/toplist?id=3778678")!))
        for _ in 0..<60 where model.musicLink?.kind != .toplist { try await Task.sleep(nanoseconds: 250_000_000) }
        print("BROWSER netease: \(model.currentURL?.absoluteString ?? "-") → \(model.musicLink?.canonicalURL.absoluteString ?? "none") title=\(model.title)")
        XCTAssertEqual(model.musicLink?.canonicalURL.absoluteString, "https://music.163.com/discover/toplist?id=3778678")

        model.activate(.qqmusic)
        model.activeWebView.load(URLRequest(url: URL(string: "https://y.qq.com/n/ryqq/toplist/26")!))
        for _ in 0..<60 where model.musicLink?.platform != .qqmusic { try await Task.sleep(nanoseconds: 250_000_000) }
        print("BROWSER qq: \(model.currentURL?.absoluteString ?? "-") → \(model.musicLink?.canonicalURL.absoluteString ?? "none") title=\(model.title)")
        XCTAssertEqual(model.musicLink?.kind, .toplist)
    }
}
#endif
