import XCTest
import WebKit
@testable import MediaFetch
@testable import MediaFetchCore
@testable import MediaFetchVideo

final class InAppLoginTests: XCTestCase {
    private func cookie(_ domain: String, name: String = "session", value: String = "synthetic-test-value", expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: domain, .path: "/", .name: name, .value: value,
            .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE"
        ]
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    func testExportIsPlatformScopedAndRejectsLookalikeDomains() throws {
        let data = try XCTUnwrap(SiteSessionCookies.export([
            cookie(".vimeo.com"), cookie("player.vimeo.com", name: "player"),
            cookie("evilvimeo.com", name: "lookalike"), cookie("vimeo.com.evil.test", name: "suffix"),
            cookie("accounts.google.com", name: "google"), cookie(".youtube.com", name: "youtube")
        ], for: .vimeo))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(".vimeo.com\tTRUE"))
        XCTAssertTrue(text.contains("player.vimeo.com\tFALSE"))
        XCTAssertFalse(text.contains("lookalike"))
        XCTAssertFalse(text.contains("suffix"))
        XCTAssertFalse(text.contains("google"))
        XCTAssertFalse(text.contains("youtube"))
        XCTAssertNil(SiteSessionCookies.export([cookie(".vimeo.com")], for: .spotify))
    }

    func testExportPreservesHTTPOnlySecureSessionAndSkipsExpired() throws {
        let text = String(decoding: try XCTUnwrap(SiteSessionCookies.export([
            cookie(".vimeo.com"), cookie(".vimeo.com", name: "expired", expires: Date(timeIntervalSince1970: 1))
        ], for: .vimeo)), as: UTF8.self)
        XCTAssertTrue(text.contains("#HttpOnly_.vimeo.com\tTRUE\t/\tTRUE\t0\tsession\t"))
        XCTAssertFalse(text.contains("expired"))
    }

    func testExportRejectsCookieJarLineInjection() {
        XCTAssertNil(SiteSessionCookies.export([cookie(".vimeo.com", value: "one\ttwo")], for: .vimeo))
        XCTAssertNil(SiteSessionCookies.export([], for: .vimeo))
    }

    func testPrivateCookieFilePermissionsAndExplicitCleanup() throws {
        let file = try TemporaryCookieFile(data: Data("synthetic-secret".utf8))
        let manager = FileManager.default
        XCTAssertEqual(try manager.attributesOfItem(atPath: file.directory.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try manager.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try Data(contentsOf: file.url), Data("synthetic-secret".utf8))
        file.remove()
        XCTAssertFalse(manager.fileExists(atPath: file.directory.path))
        file.remove() // Idempotent.
    }

    func testCookieFileRemovedOnOwnerRelease() throws {
        var file: TemporaryCookieFile? = try TemporaryCookieFile(data: Data("synthetic-secret".utf8))
        let directory = try XCTUnwrap(file?.directory)
        file = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testLegacyPreferencesKeepBrowserMethodAndNewOnesDefaultToInApp() throws {
        let old = Data(#"{"platform":"vimeo","browser":"chrome","isEnabled":true}"#.utf8)
        let configuration = try JSONDecoder().decode(StreamingSiteLoginConfiguration.self, from: old)
        XCTAssertEqual(configuration.resolvedMethod, .browser)
        XCTAssertTrue(configuration.isEnabled)
        XCTAssertEqual(StreamingSiteLoginConfiguration(platform: .vimeo, browser: .chrome).resolvedMethod, .inApp)
    }

    func testJobsPersistOnlySessionModeAndDecodeLegacyHistory() throws {
        let job = DownloadJob(sourceURL: "https://vimeo.com/123", profile: .highest,
                              destination: FileManager.default.temporaryDirectory, includeSidecars: false,
                              includeSubtitles: false, browserCookieSource: nil, usesInAppLogin: true)
        let data = try JobHistoryStore.encoded([job])
        XCTAssertEqual(try JobHistoryStore.restoredJobs(from: data).first?.usesInAppLogin, true)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        object[0].removeValue(forKey: "usesInAppLogin")
        XCTAssertNil(try JobHistoryStore.restoredJobs(from: JSONSerialization.data(withJSONObject: object)).first?.usesInAppLogin)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("cookies.txt"))
    }

    @MainActor
    func testSessionMethodNeverFallsBackToBrowserCookies() throws {
        let suite = "MediaFetch.tests.inapp." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StreamingSiteLoginStore(defaults: defaults, fallbackBrowser: .chrome)
        store.setEnabled(true, for: .vimeo)
        XCTAssertNil(store.cookieSource(for: .vimeo))
        store.setMethod(.browser, for: .vimeo)
        XCTAssertEqual(store.cookieSource(for: .vimeo), .chrome)
        XCTAssertNil(store.cookieSource(for: .youtube))
        store.setEnabled(false, for: .vimeo)
        XCTAssertNil(store.cookieSource(for: .vimeo))
    }

#if !MEDIAFETCH_STORE_PROFILE
    @MainActor
    func testQueueUsesInAppProviderAndRemovesFileOnEngineFailure() async throws {
        try await exerciseEngineSession(cancel: false)
    }

    @MainActor
    func testQueueCancellationRemovesFileAfterEngineExits() async throws {
        try await exerciseEngineSession(cancel: true)
    }

    @MainActor
    private func exerciseEngineSession(cancel: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MediaFetch-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = root.appendingPathComponent("report")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/test_session_engine.sh")
        let toolchain = VideoToolchain(ytDLPURL: script, ffmpegURL: URL(fileURLWithPath: "/usr/bin/true"),
            allowsBrowserCookies: true,
            processEnvironment: ["PATH": "/usr/bin:/bin", "MF_TEST_REPORT": report.path, "MF_TEST_WAIT": cancel ? "1" : "0"])
        let downloader = DownloaderService(jobs: [], toolchain: toolchain, historyWriter: { _ in })
        var requests: [URL] = []
        downloader.inAppCookieProvider = { url in
            requests.append(url)
            return Data("# Netscape HTTP Cookie File\n".utf8)
        }
        let url = "https://vimeo.com/123"
        XCTAssertEqual(downloader.enqueue(url, profile: .highest, destination: root,
            includeSidecars: false, includeSubtitles: false, cookieSource: .chrome, inAppLoginURLs: [url]), 1)
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: report.path) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let cookiePath = try String(contentsOf: report, encoding: .utf8)
        if cancel {
            XCTAssertTrue(FileManager.default.fileExists(atPath: cookiePath))
            downloader.cancel()
        }
        for _ in 0..<200 {
            if !downloader.isDownloading { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(downloader.isDownloading)
        XCTAssertEqual(requests.map(\.absoluteString), [url])
        XCTAssertNil(downloader.jobs.first?.browserCookieSource)
        XCTAssertEqual(downloader.jobs.first?.status, cancel ? .cancelled : .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cookiePath))
        if !cancel { XCTAssertTrue(downloader.errorMessage?.contains("应用内") == true) }
    }

    @MainActor
    func testWebKitSessionExportsOnlyItsPlatformAndClearsCredentials() async throws {
        // Isolated, nonpersistent store: never accesses the user's real sessions.
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let session = InAppSiteSession(platform: .vimeo, dataStore: dataStore)
        await dataStore.httpCookieStore.setCookie(cookie(".vimeo.com"))
        await dataStore.httpCookieStore.setCookie(cookie("accounts.google.com", name: "identity"))
        await session.refreshSession()
        XCTAssertTrue(session.hasCookies)
        let exported = try await session.exportCookies()
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains("identity"))
        await session.clear()
        let remaining = await dataStore.httpCookieStore.allCookies()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(session.hasCookies)
        do {
            _ = try await session.exportCookies()
            XCTFail("An empty session must not be passed to the engine")
        } catch { XCTAssertTrue(error is InAppSiteSession.SessionError) }
    }

    @MainActor
    func testGoogleLoginDoesNotLoadAnEmbeddedIdentityPage() {
        let session = InAppSiteSession(platform: .youtube, dataStore: .nonPersistent())
        session.open()
        session.reloadLogin()
        XCTAssertTrue(session.providerBlocked)
        XCTAssertNil(session.webView.url)
    }
#endif
}
