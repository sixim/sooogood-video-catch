#if !MEDIAFETCH_STORE_PROFILE
import XCTest
import WebKit

/// Feasibility probe (opt-in, MF_LIVE_KUGOU=<song page>): does Kugou's own web
/// player play a plain, capturable audio URL, or blob:/encrypted media?
final class KugouFeasibilityTests: XCTestCase {
    @MainActor
    func testKugouWebPlayerMediaSource() async throws {
        guard let page = ProcessInfo.processInfo.environment["MF_LIVE_KUGOU"].flatMap(URL.init(string:)) else {
            throw XCTSkip("set MF_LIVE_KUGOU to a kugou.com/mixsong page")
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 900), configuration: configuration)
        web.load(URLRequest(url: page))
        let script = """
        (() => {
          const media = [...document.querySelectorAll('audio,video')].map(m => ({tag: m.tagName, src: m.currentSrc || m.src, paused: m.paused, ready: m.readyState, duration: m.duration}));
          const res = performance.getEntriesByType('resource').map(r => r.name).filter(n => /\\.(mp3|m4a|flac|aac|ogg)(\\?|$)/i.test(n) || /mp3|audio/i.test(n.split('?')[0].split('/').pop()));
          document.querySelectorAll('audio').forEach(a => { try { a.play() } catch (e) {} });
          return JSON.stringify({title: document.title, media, res: res.slice(0, 5)});
        })()
        """
        var last = ""
        for second in [6, 12, 18] {
            try await Task.sleep(nanoseconds: 6_000_000_000)
            last = (try? await web.evaluateJavaScript(script) as? String) ?? "js failed"
            print("KUGOU t=\(second)s: \(last.prefix(900))")
        }
        XCTAssertFalse(last.isEmpty)
    }
}
#endif
