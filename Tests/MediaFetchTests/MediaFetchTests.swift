import XCTest
@testable import MediaFetch
@testable import MediaFetchCore
@testable import MediaFetchVideo
@testable import MediaFetchMusic

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
#if MEDIAFETCH_STORE_PROFILE
        XCTAssertTrue(BrowserCookieSource.safari.ytDLPArguments.isEmpty)
        XCTAssertTrue(BrowserCookieSource.chrome.ytDLPArguments.isEmpty)
#else
        XCTAssertEqual(BrowserCookieSource.safari.ytDLPArguments, ["--cookies-from-browser", "safari"])
        XCTAssertEqual(BrowserCookieSource.chrome.ytDLPArguments, ["--cookies-from-browser", "chrome"])
#endif
    }

    func testBundledToolchainNeverFallsBackToExternalToolsOrCookies() {
        let toolchain = VideoToolchain.bundled(bundleURL: URL(fileURLWithPath: "/tmp/MediaFetch-NoBundle.app"))
        XCTAssertFalse(toolchain.allowsBrowserCookies)
#if !MEDIAFETCH_STORE_PROFILE
        XCTAssertNil(toolchain.ytDLPURL)
        XCTAssertNil(toolchain.ffmpegURL)
#endif
        XCTAssertTrue(toolchain.processEnvironment["PATH"]?.contains("/opt/homebrew") == false)
    }

    func testBundledAudioToolchainNeverFallsBackToExternalFFprobe() {
        let toolchain = AudioToolchain.bundled(bundleURL: URL(fileURLWithPath: "/tmp/MediaFetch-NoBundle.app"))
#if MEDIAFETCH_STORE_PROFILE
        XCTAssertTrue(toolchain.usesNativeProbe)
        XCTAssertEqual(toolchain.processEnvironment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
#else
        XCTAssertNil(toolchain.ffprobeURL)
        XCTAssertTrue(toolchain.processEnvironment["PATH"]?.contains("/opt/homebrew") == false)
#endif
    }

    func testNativeAudioToolchainUsesNoExecutable() {
        let toolchain = AudioToolchain.native()
        XCTAssertTrue(toolchain.usesNativeProbe)
#if !MEDIAFETCH_STORE_PROFILE
        XCTAssertNil(toolchain.ffprobeURL)
#endif
        XCTAssertEqual(toolchain.processEnvironment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    func testBundledToolchainsRejectSymlinkedHelpers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaFetchHelpers-\(UUID().uuidString)", isDirectory: true)
        let helpers = root.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["yt-dlp", "ffmpeg", "ffprobe"] {
            try FileManager.default.createSymbolicLink(
                at: helpers.appendingPathComponent(name),
                withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")
            )
        }

        let bundleURL = root.appendingPathComponent("MediaFetch.app", isDirectory: true)
#if !MEDIAFETCH_STORE_PROFILE
        XCTAssertNil(VideoToolchain.bundled(bundleURL: bundleURL).ytDLPURL)
        XCTAssertNil(VideoToolchain.bundled(bundleURL: bundleURL).ffmpegURL)
#endif
#if !MEDIAFETCH_STORE_PROFILE
        XCTAssertNil(AudioToolchain.bundled(bundleURL: bundleURL).ffprobeURL)
#else
        XCTAssertTrue(AudioToolchain.bundled(bundleURL: bundleURL).usesNativeProbe)
#endif
    }

    func testReleaseMetadataUsesExpectedSchemaVersions() {
        XCTAssertEqual(MediaFetchRelease.bundleIdentifier, "com.simon.mediafetch")
        XCTAssertEqual(MediaFetchRelease.displayName, "Sooogood Video Catch")
        XCTAssertEqual(MediaFetchRelease.version, "0.12.0")
        XCTAssertEqual(MediaFetchRelease.build, "15")
        XCTAssertEqual(MediaFetchRelease.videoManifestSchema, 2)
        XCTAssertEqual(MediaFetchRelease.musicManifestSchema, 2)
    }

#if MEDIAFETCH_STORE_PROFILE
    @MainActor
    func testStoreDemoModeLoadsSyntheticMetadataWithoutCredentials() {
        let model = SpotifyBridgeViewModel(restoresConnection: false, allowsPersistence: false)
        let demoDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaFetch-demo-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: demoDirectory) }

        model.loadDemoCollection(demoDirectory: demoDirectory)

        XCTAssertEqual(model.connectionState, .demo)
        XCTAssertEqual(model.collection?.id, "37i9dQZF1DX-mediafetch-demo")
        XCTAssertEqual(model.items.count, SpotifyDemoFixture.tracks.count)
        XCTAssertEqual(model.readyCount, 2)
        XCTAssertEqual(model.phase, .chooseSource)
        XCTAssertFalse(model.hasStoredCredentials)
        XCTAssertTrue(model.audioToolReady)
    }

    @MainActor
    func testStoreDemoModeSavesOnlyTheTwoSyntheticAudioSources() async throws {
        let model = SpotifyBridgeViewModel(restoresConnection: false, allowsPersistence: false)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaFetch-demo-save-\(UUID().uuidString)", isDirectory: true)
        let demoDirectory = root.appendingPathComponent("Demo Audio", isDirectory: true)
        let destination = root.appendingPathComponent("Packages", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        model.destination = destination
        model.loadDemoCollection(demoDirectory: demoDirectory)
        await model.saveReadyItems()

        XCTAssertEqual(model.phase, .completed)
        XCTAssertEqual(model.completedPackageURL?.deletingLastPathComponent(), destination)
        XCTAssertEqual(model.items.filter { $0.status == .completed }.count, 2)
        XCTAssertEqual(model.items.filter { $0.status == .unmatched }.count, 2)

        let packageURL = try XCTUnwrap(model.completedPackageURL)
        let audioFiles = try FileManager.default.contentsOfDirectory(
            at: packageURL.appendingPathComponent("audio", isDirectory: true),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "wav" }
        XCTAssertEqual(audioFiles.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("playlist.m3u8").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("manifest.json").path))
    }
#endif

    func testVideoPackageExporterCopiesACompletedPackageToUserDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaFetchExporter-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("Clip [abc]", isDirectory: true)
        let destination = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("manifest".utf8).write(to: package.appendingPathComponent("manifest.json"))
        defer { try? FileManager.default.removeItem(at: root) }

        let exported = try VideoPackageExporter().export(packageDirectory: package, to: destination)

        XCTAssertEqual(exported.lastPathComponent, "Clip [abc]")
        XCTAssertEqual(
            try Data(contentsOf: exported.appendingPathComponent("manifest.json")),
            Data("manifest".utf8)
        )
    }

    func testSafariPermissionErrorClassification() {
#if MEDIAFETCH_STORE_PROFILE
        XCTAssertFalse(EngineErrorClassifier.isSafariCookiePermissionError(
            "ERROR: [Errno 1] Operation not permitted: /Library/Cookies/Cookies.binarycookies"
        ))
#else
        XCTAssertTrue(EngineErrorClassifier.isSafariCookiePermissionError(
            "ERROR: [Errno 1] Operation not permitted: /Library/Cookies/Cookies.binarycookies"
        ))
        XCTAssertTrue(EngineErrorClassifier.isSafariCookiePermissionError(
            "Permission denied when accessing Safari Cookies.binarycookies"
        ))
        XCTAssertFalse(EngineErrorClassifier.isSafariCookiePermissionError("Video unavailable"))
#endif
    }

    func testDRMErrorClassification() {
        XCTAssertTrue(EngineErrorClassifier.isDRMError("The requested site is known to use DRM protection"))
        XCTAssertTrue(EngineErrorClassifier.isDRMError("This format is DRM protected"))
        XCTAssertFalse(EngineErrorClassifier.isDRMError("Requested format is not available"))
    }

    func testAuthenticationRequiredErrorClassification() {
        XCTAssertTrue(EngineErrorClassifier.isAuthenticationRequiredError(
            "The web client only works when logged-in. Use --cookies-from-browser"
        ))
        XCTAssertTrue(EngineErrorClassifier.isAuthenticationRequiredError("login required"))
        XCTAssertTrue(EngineErrorClassifier.isAuthenticationRequiredError("authentication required"))
        XCTAssertFalse(EngineErrorClassifier.isAuthenticationRequiredError("Video unavailable"))
    }

    func testBrowserLoginPlatformsHaveOfficialHTTPSEntryPoints() throws {
        let expectedHosts: [StreamingPlatform: String] = [
            .youtube: "www.youtube.com",
            .vimeo: "vimeo.com",
            .bilibili: "passport.bilibili.com",
            .youku: "account.youku.com",
            .udemy: "www.udemy.com"
        ]

        XCTAssertEqual(Set(StreamingPlatform.browserLoginPlatforms), Set(expectedHosts.keys))
        for platform in StreamingPlatform.browserLoginPlatforms {
            let url = try XCTUnwrap(platform.browserLoginURL)
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, expectedHosts[platform])
        }
        XCTAssertNil(StreamingPlatform.netflix.browserLoginURL)
        XCTAssertNil(StreamingPlatform.spotify.browserLoginURL)
    }

    @MainActor
    func testStreamingSiteLoginPreferencesPersistWithoutSecrets() throws {
        let suiteName = "MediaFetchTests.SiteLogin.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = StreamingSiteLoginStore(defaults: defaults, fallbackBrowser: .safari)
        XCTAssertFalse(store.isEnabled(for: .vimeo))
        store.setBrowser(.firefox, for: .vimeo)
        store.setEnabled(true, for: .vimeo)

        let restored = StreamingSiteLoginStore(defaults: defaults, fallbackBrowser: .chrome)
        XCTAssertTrue(restored.isEnabled(for: .vimeo))
        XCTAssertEqual(restored.browser(for: .vimeo), .firefox)
        XCTAssertNil(restored.cookieSource(for: .youtube))

        let persistedData = try XCTUnwrap(defaults.data(forKey: StreamingSiteLoginStore.defaultsKey))
        let persistedText = try XCTUnwrap(String(data: persistedData, encoding: .utf8)).lowercased()
        XCTAssertFalse(persistedText.contains("password"))
        XCTAssertFalse(persistedText.contains("token"))
        XCTAssertFalse(persistedText.contains("cookie"))
    }

    func testStreamingPlatformDetectionAndDRMPolicy() {
        XCTAssertEqual(StreamingPlatform.detect(URL(string: "https://youtu.be/abc")!), .youtube)
        XCTAssertEqual(StreamingPlatform.detect(URL(string: "https://www.bilibili.com/video/BV1")!), .bilibili)
        XCTAssertEqual(StreamingPlatform.detect(URL(string: "https://v.youku.com/v_show/id_X.html")!), .youku)
        XCTAssertEqual(StreamingPlatform.detect(URL(string: "https://cdn.example.com/master.m3u8")!), .directStream)
        XCTAssertEqual(StreamingPlatform.detect(URL(string: "https://www.netflix.com/title/1")!), .netflix)
        XCTAssertEqual(StreamingPlatform.detect(URL(string: "https://open.spotify.com/track/1")!), .spotify)
        XCTAssertEqual(StreamingPlatform.detect(URL(string: "https://spotify.link/example")!), .spotify)
        XCTAssertEqual(StreamingPlatform.detect(URL(string: "https://spotify.app.link/example")!), .spotify)
        XCTAssertFalse(StreamingPlatform.detect(URL(string: "https://spotify.link/example")!).downloadAllowed)
        XCTAssertFalse(StreamingPlatform.detect(URL(string: "https://spotify.app.link/example")!).downloadAllowed)
        XCTAssertEqual(StreamingPlatform.detect(URL(string: "https://spotify.link.evil.example/a")!), .generic)
        XCTAssertEqual(StreamingPlatform.detect(URL(string: "https://netflix.com.evil.example/video")!), .generic)
        XCTAssertEqual(StreamingPlatform.spotify.route, .spotifyBridge)
        XCTAssertEqual(StreamingPlatform.netflix.route, .drmBlocked)
        XCTAssertEqual(StreamingPlatform.youtube.route, .networkDownload)
        XCTAssertFalse(StreamingPlatform.netflix.downloadAllowed)
        XCTAssertFalse(StreamingPlatform.spotify.downloadAllowed)
        XCTAssertTrue(StreamingPlatform.bilibili.downloadAllowed)
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
        XCTAssertEqual(DownloadProfile.audioOnly.formatSelector, "ba/b")
        XCTAssertFalse(DownloadProfile.audioOnly.requiresFFmpeg)
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
        XCTAssertEqual(json?["schemaVersion"] as? Int, 2)
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
