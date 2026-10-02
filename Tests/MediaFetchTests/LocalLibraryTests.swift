import XCTest
@testable import MediaFetchCore
@testable import MediaFetchMusic

final class LocalLibraryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mf-lib-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testCacheHitsUnchangedFilesAndMissesModifiedOnes() throws {
        let file = root.appendingPathComponent("a.mp3")
        try Data("one".utf8).write(to: file)
        let cacheURL = root.appendingPathComponent("cache.json")
        let cache = AudioMetadataCache(url: cacheURL)
        var probes = 0
        let make = { () -> LocalAudioCandidate in probes += 1; return LocalAudioCandidate(url: file, title: "A", artists: ["X"], durationMS: 1000) }
        _ = cache.candidate(for: file, probe: make)
        _ = cache.candidate(for: file, probe: make)
        XCTAssertEqual(probes, 1, "second scan of an unchanged file is served from cache")
        cache.save()
        // A new process (new cache instance) still hits.
        let reloaded = AudioMetadataCache(url: cacheURL)
        XCTAssertEqual(reloaded.cached(for: file)?.title, "A")
        // Changing the file invalidates the entry.
        try Data("two-longer".utf8).write(to: file)
        XCTAssertNil(reloaded.cached(for: file))
        // Failed probes are never cached.
        let other = root.appendingPathComponent("b.mp3")
        try Data("x".utf8).write(to: other)
        reloaded.store(LocalAudioCandidate(url: other, title: "b", probeWarning: "ffprobe failed"), for: other)
        XCTAssertNil(reloaded.cached(for: other))
    }

    func testIndexMatchingIsStrict() {
        let index = LocalMusicIndex(items: [
            .init(path: "/m/qingtian.flac", platform: "qqmusic", mediaID: "0039MnYb0qxYhV", title: "晴天", artists: ["周杰伦"], durationSeconds: 269),
            .init(path: "/m/haiyu.mp3", platform: nil, mediaID: nil, title: "海屿你", artists: ["马也_Crabbit"], durationSeconds: 295)
        ])
        XCTAssertEqual(index.match(platform: "qqmusic", mediaID: "0039MnYb0qxYhV", title: "whatever", artists: [], durationSeconds: nil),
                       .sameTrack(path: "/m/qingtian.flac"))
        XCTAssertEqual(index.match(platform: "netease", mediaID: "1973665667", title: "海屿你", artists: ["马也_Crabbit"], durationSeconds: 296),
                       .likely(path: "/m/haiyu.mp3"))
        XCTAssertEqual(index.match(platform: nil, mediaID: nil, title: "海屿你 ", artists: ["马也＿Crabbit"], durationSeconds: nil)?.path, "/m/haiyu.mp3",
                       "full-width and spacing differences still match")
        XCTAssertNil(index.match(platform: nil, mediaID: nil, title: "海屿你", artists: ["马也_Crabbit"], durationSeconds: 340), "different length (live/remix) is not the same")
        XCTAssertNil(index.match(platform: nil, mediaID: nil, title: "海屿你", artists: ["别人"], durationSeconds: 295), "same title, other artist")
        XCTAssertNil(index.match(platform: nil, mediaID: nil, title: "海屿你", artists: [], durationSeconds: 295), "no artist → no guess")
    }

    func testManifestItemsComeFromPackages() throws {
        let package = root.appendingPathComponent("马也_Crabbit/海屿你/马也_Crabbit - 海屿你 [1973665667]")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let manifest: JSONValue = ["mediaID": "1973665667", "platform": "netease:song", "title": "海屿你",
                                   "audio": ["durationSeconds": 295.0],
                                   "files": [["relativePath": "马也_Crabbit - 海屿你 [1973665667].mp3"], ["relativePath": "cover.jpg"]]]
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
        let items = LocalMusicIndex.manifestItems(under: root)
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].path.hasSuffix(".mp3"))
        let index = LocalMusicIndex(items: items)
        XCTAssertEqual(index.match(platform: StreamingPlatform.netease.extractorFamily, mediaID: "1973665667", title: "", artists: [], durationSeconds: nil)?.isExact, true)
    }

    func testExistingPathIsExactAndRequiresTheFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("existing-\(UUID().uuidString)")
        let package = root.appendingPathComponent("A/B/A - 晴天 [186016]")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = package.appendingPathComponent("A - 晴天 [186016].flac")
        try Data("x".utf8).write(to: audio)
        let manifest = #"{"platform":"netease:song","mediaID":"186016","title":"晴天","files":[{"relativePath":"A - 晴天 [186016].flac"}]}"#
        try Data(manifest.utf8).write(to: package.appendingPathComponent("manifest.json"))
        let index = LocalMusicIndex(items: LocalMusicIndex.manifestItems(under: root))
        XCTAssertEqual(index.existingPath(platform: .netease, mediaID: "186016").map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       audio.resolvingSymlinksInPath().path)
        XCTAssertNil(index.existingPath(platform: .qqmusic, mediaID: "186016"), "same id on another platform is a different track")
        XCTAssertNil(index.existingPath(platform: .netease, mediaID: "1"))
        try FileManager.default.removeItem(at: audio)
        XCTAssertNil(index.existingPath(platform: .netease, mediaID: "186016"), "a deleted file is not 'already have'")
    }
}
