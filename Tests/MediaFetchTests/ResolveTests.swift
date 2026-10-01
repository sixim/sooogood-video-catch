#if !MEDIAFETCH_STORE_PROFILE
import XCTest
@testable import MediaFetchCore
@testable import MediaFetchResolve
@testable import MediaFetchTools

final class ResolveTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mf-resolve-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makePackage() throws -> URL {
        let package = root.appendingPathComponent("Clip Title [abc]")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let mp4 = Data([0, 0, 0, 0x18]) + Data("ftypisom".utf8) + Data(count: 32)
        try mp4.write(to: package.appendingPathComponent("Clip Title [abc].mp4"))
        try Data("1\n00:00:01,000 --> 00:00:02,000\nhi\n".utf8).write(to: package.appendingPathComponent("Clip Title [abc].en.srt"))
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: package.appendingPathComponent("Clip Title [abc].jpg"))
        try Data("<!doctype html>".utf8).write(to: package.appendingPathComponent("broken.mp4"))
        let manifest: JSONValue = [
            "schemaVersion": 2, "sourceURL": "https://www.youtube.com/watch?v=abc", "title": "Clip Title",
            "platform": "youtube", "mediaID": "abc",
            "files": [["relativePath": "Clip Title [abc].mp4", "byteSize": 44, "sha256": "deadbeef"]]
        ]
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
        return package
    }

    func testPlannerPicksMediaAndSubtitlesWithProvenance() throws {
        let package = try makePackage()
        let request = try ResolveImportPlanner.plan(packageDirectory: package, timelineName: "T")
        XCTAssertEqual(request.binPath, ["Sooogood", "Clip Title [abc]"])
        XCTAssertEqual(request.clips.map { ($0.path as NSString).lastPathComponent }, ["Clip Title [abc].mp4"],
                       "thumbnail, manifest and HTML disguised as mp4 are skipped")
        XCTAssertEqual(request.subtitles.count, 1)
        let clip = try XCTUnwrap(request.clips.first)
        XCTAssertEqual(clip.metadata["Comments"], "Source: https://www.youtube.com/watch?v=abc")
        XCTAssertEqual(clip.metadata["Description"], "Clip Title")
        XCTAssertEqual(clip.metadata["Keywords"], "youtube,Sooogood")
        XCTAssertEqual(clip.thirdParty["Sooogood SHA-256"], "deadbeef")
        XCTAssertEqual(request.timelineName, "T")
    }

    func testProxyIsLinkedNotImportedAsSeparateClip() throws {
        let package = try makePackage()
        let original = package.appendingPathComponent("Clip Title [abc].mp4").path
        let proxy = package.appendingPathComponent("proxy.mov")
        try (Data([0, 0, 0, 0x14]) + Data("ftypqt  ".utf8) + Data(count: 16)).write(to: proxy)
        let request = try ResolveImportPlanner.plan(packageDirectory: package, proxies: [original: proxy.path])
        XCTAssertEqual(request.clips.count, 1)
        XCTAssertEqual(request.clips.first?.proxy, proxy.path)
    }

    func testFileListPlanForSingleFileTorrentStaysScoped() throws {
        let file = root.appendingPathComponent("movie.mkv")
        try Data([0x1A, 0x45, 0xDF, 0xA3, 0, 0]).write(to: file)
        try Data([0x1A, 0x45, 0xDF, 0xA3, 0, 0]).write(to: root.appendingPathComponent("unrelated.mkv"))
        let request = ResolveImportPlanner.plan(files: [file], binName: "movie.mkv", provenance: nil)
        XCTAssertEqual(request.clips.map(\.path), [file.path])
        XCTAssertEqual(request.binPath, ["Sooogood", "movie.mkv"])
    }

    func testOpusAudioIsSkippedAndWarnedUntilAnEditableVersionExists() throws {
        let package = root.appendingPathComponent("Opus Pack")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data([0x1A, 0x45, 0xDF, 0xA3, 0, 0]).write(to: package.appendingPathComponent("v.mkv"))
        try Data("OggS".utf8).write(to: package.appendingPathComponent("v.audio.ogg"))
        let manifest: JSONValue = ["selectedFormats": [["audioCodec": "opus", "videoCodec": "av01", "formatID": "1", "resolution": "x", "container": "mkv"]]]
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
        let request = try ResolveImportPlanner.plan(packageDirectory: package)
        XCTAssertEqual(request.clips.map { ($0.path as NSString).lastPathComponent }, ["v.mkv"], ".ogg is never sent to Resolve")
        XCTAssertEqual(ResolveImportPlanner.compatibilityWarnings(packageDirectory: package).count, 1)
        try DerivativeLog.append(DerivativeRecord(
            tool: "ffmpeg", preset: "wavForEdit", role: .audio,
            source: .init(relativePath: "v.mkv", byteSize: 6, sha256: "a"),
            output: .init(relativePath: "v.edit.wav", byteSize: 1, sha256: "b"),
            command: [], engineVersion: "8", elapsedSeconds: 0), in: package)
        XCTAssertTrue(ResolveImportPlanner.compatibilityWarnings(packageDirectory: package).isEmpty)
    }

    func testMusicPackagesGoToAlbumBinWithArtistAndMeasuredQuality() throws {
        let package = root.appendingPathComponent("马也_Crabbit - 海屿你 [1973665667]")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try (Data("ID3".utf8) + Data([3, 0, 0, 0, 0, 0, 0]) + Data([0xFF, 0xFB, 0x90, 0x64])).write(to: package.appendingPathComponent("a.mp3"))
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: package.appendingPathComponent("a.jpg"))
        try Data("[00:00.00]x".utf8).write(to: package.appendingPathComponent("a.lyrics.lrc"))
        let manifest: JSONValue = [
            "schemaVersion": 4, "sourceURL": "https://music.163.com/song?id=1973665667", "title": "海屿你", "platform": "netease:song",
            "mediaID": "1973665667", "musicQualityPreference": "best",
            "music": ["artist": "马也_Crabbit", "album": "海屿你/单曲"],
            "audio": ["codec": "mp3", "sampleRate": 48000, "bitrate": 320000, "tier": 3],
            "files": [["relativePath": "a.mp3", "sha256": "abc"]]
        ]
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
        let request = try ResolveImportPlanner.plan(packageDirectory: package)
        XCTAssertEqual(request.binPath, ["Sooogood", "音乐", "海屿你／单曲"])
        XCTAssertEqual(request.clips.map { ($0.path as NSString).lastPathComponent }, ["a.mp3"], "cover and .lrc are not media clips")
        let clip = try XCTUnwrap(request.clips.first)
        XCTAssertEqual(clip.metadata["Description"], "马也_Crabbit - 海屿你")
        XCTAssertTrue(clip.metadata["Keywords"]?.contains("Music") == true)
        XCTAssertEqual(clip.thirdParty["Sooogood Artist"], "马也_Crabbit")
        XCTAssertEqual(clip.thirdParty["Sooogood Audio Quality"], "MP3 · 48.0 kHz · 320 kbps")
    }

    func testBinNameStripsPathSeparators() {
        XCTAssertEqual(ResolveImportPlanner.binName(for: URL(fileURLWithPath: "/x/a:b")), "a-b")
    }

    func testErrorMappingAndLaunchHint() {
        XCTAssertEqual(ResolveBridge.mapError(["ok": false, "error": "not_connected"]), .notConnected)
        XCTAssertEqual(ResolveBridge.mapError(["ok": false, "error": "no_project"]), .noProject)
        XCTAssertEqual(ResolveBridge.mapError(["ok": false, "error": "not_ready"]), .notReady)
        XCTAssertTrue(ResolveBridgeError.notRunning.suggestsLaunching)
        XCTAssertFalse(ResolveBridgeError.notConnected.suggestsLaunching)
    }

    func testImportLogAppends() throws {
        let result = ResolveImportResult(product: "DaVinci Resolve Studio", version: "21", project: "P", bin: ["Sooogood", "x"],
                                         clips: [.init(path: "/a/b.mp4", name: "b.mp4", reused: false, metadataFailures: [], proxyLinked: nil)],
                                         subtitles: [], failed: [], timeline: nil)
        try ResolveImportLog.append(result, to: root)
        try ResolveImportLog.append(result, to: root)
        let entries = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("resolve-imports.json")))
        XCTAssertEqual(entries.arrayValue?.count, 2)
        XCTAssertEqual(entries.arrayValue?.first?["clips"], ["b.mp4"])
    }

    // MARK: The real Python bridge against a fake scripting module

    private static let fakeModule = #"""
import json, os
LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "fake.log")
def log(*event):
    with open(LOG, "a") as f:
        f.write(json.dumps(event) + "\n")

class Clip:
    def __init__(self, path): self.path = path
    def GetName(self): return os.path.basename(self.path)
    def GetClipProperty(self, key): return self.path if key == "File Path" else ""
    def SetMetadata(self, k, v):
        log("meta", k, v); return k != "Bogus"
    def SetThirdPartyMetadata(self, k, v):
        log("third", k, v); return True
    def LinkProxyMedia(self, p):
        log("proxy", p); return True

class Folder:
    def __init__(self, name): self.name, self.subs, self.clips = name, [], []
    def GetName(self): return self.name
    def GetSubFolderList(self): return self.subs
    def GetClipList(self): return self.clips

class Timeline:
    def __init__(self, n): self.n = n
    def GetName(self): return self.n

class Pool:
    def __init__(self):
        self.root = Folder("Master"); self.current = self.root
        existing = Folder("Sooogood"); self.root.subs.append(existing)
    def GetRootFolder(self): return self.root
    def AddSubFolder(self, parent, name):
        f = Folder(name); parent.subs.append(f); log("bin", name); return f
    def SetCurrentFolder(self, f): self.current = f; return True
    def ImportMedia(self, paths):
        log("import", paths)
        if paths[0].endswith("reject.mp4"): return []
        clips = [Clip(p) for p in paths]; self.current.clips.extend(clips); return clips
    def CreateTimelineFromClips(self, name, clips):
        log("timeline", name, len(clips)); return Timeline(name)

class Project:
    pool = Pool()
    def GetName(self): return "Fake Project"
    def GetMediaPool(self): return self.pool

class PM:
    def GetCurrentProject(self): return Project()

class Resolve:
    def GetProductName(self): return "DaVinci Resolve Studio"
    def GetVersionString(self): return "21.0.4.5"
    def GetCurrentPage(self): return "media"
    def GetProjectManager(self): return PM()

def scriptapp(name): return Resolve()
"""#

    func testPythonBridgeImportsIntoNestedBinWithMetadataProxyAndTimeline() async throws {
        let modules = root.appendingPathComponent("api/Modules")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data(Self.fakeModule.utf8).write(to: modules.appendingPathComponent("DaVinciResolveScript.py"))
        let log = root.appendingPathComponent("fake.log")
        guard let python = ResolveBridge.Environment.findPython() else { throw XCTSkip("no python3") }
        var bridge = ResolveBridge(environment: .init(
            appURL: root, scriptAPI: root.appendingPathComponent("api"),
            scriptLibrary: root.appendingPathComponent("none.so"), python: python))
        bridge.requiresRunningApp = false

        let request = ResolveImportRequest(
            binPath: ["Sooogood", "Pkg 中文"],
            clips: [
                .init(path: "/m/a.mp4", metadata: ["Comments": "Source: x", "Bogus": "y"], thirdParty: ["Sooogood SHA-256": "h"], proxy: "/m/a_proxy.mov"),
                .init(path: "/m/reject.mp4")
            ],
            subtitles: ["/m/a.srt"],
            timelineName: "Pkg 中文"
        )
        let result = try await bridge.importMedia(request)
        XCTAssertEqual(result.project, "Fake Project")
        XCTAssertEqual(result.bin, ["Sooogood", "Pkg 中文"])
        XCTAssertEqual(result.clips.map(\.name), ["a.mp4"])
        XCTAssertEqual(result.clips.first?.metadataFailures, ["Bogus"])
        XCTAssertEqual(result.clips.first?.proxyLinked, true)
        XCTAssertEqual(result.failed, ["/m/reject.mp4"])
        XCTAssertEqual(result.subtitles, ["/m/a.srt"])
        XCTAssertEqual(result.timeline, "Pkg 中文")
        let events = try String(contentsOf: log, encoding: .utf8)
        XCTAssertFalse(events.contains(#"["bin", "Sooogood"]"#), "existing bin is reused, not duplicated")
        XCTAssertTrue(events.contains("Pkg \\u4e2d\\u6587") || events.contains("Pkg 中文"))

        let status = try await bridge.status()
        XCTAssertEqual(status, ResolveStatus(product: "DaVinci Resolve Studio", version: "21.0.4.5", project: "Fake Project"))
        XCTAssertTrue(status.isStudio)
    }

    /// Read-only check against the user's real Resolve. Opt-in: MF_LIVE_RESOLVE=1.
    func testLiveResolveStatusIsReadOnly() async throws {
        guard ProcessInfo.processInfo.environment["MF_LIVE_RESOLVE"] == "1" else {
            throw XCTSkip("set MF_LIVE_RESOLVE=1 to query the running DaVinci Resolve")
        }
        let status = try await ResolveBridge(environment: try .discover()).status()
        print("LIVE RESOLVE:", status.product, status.version, status.project ?? "-")
        XCTAssertFalse(status.version.isEmpty)
    }

    /// Imports real packages into the user's open Resolve project. Opt-in only:
    /// MF_LIVE_RESOLVE_IMPORT=<package dir>[:<package dir>...]
    @MainActor
    func testLiveResolveImport() async throws {
        guard let list = ProcessInfo.processInfo.environment["MF_LIVE_RESOLVE_IMPORT"] else {
            throw XCTSkip("set MF_LIVE_RESOLVE_IMPORT to import into the running DaVinci Resolve")
        }
        let service = ResolveService()
        for path in list.split(separator: ":").map(String.init) {
            let package = URL(fileURLWithPath: path)
            if ProcessInfo.processInfo.environment["MF_LIVE_MAKE_WAV"] == "1",
               let mkv = try FileManager.default.contentsOfDirectory(at: package, includingPropertiesForKeys: nil)
                   .first(where: { $0.pathExtension == "mkv" }) {
                let tools = ToolService(toolchain: .local(), historyURL: package.deletingLastPathComponent().appendingPathComponent("t.json"),
                                        modelDirectory: package.deletingLastPathComponent().appendingPathComponent("m"))
                tools.enqueue(inputs: [mkv], presets: [.wavForEdit])
                while tools.jobs.contains(where: { [.queued, .running].contains($0.status) }) { try await Task.sleep(nanoseconds: 100_000_000) }
                print("LIVE WAV:", tools.jobs.first?.status.rawValue ?? "-", tools.jobs.first?.errorMessage ?? "")
            }
            print("LIVE WARNINGS:", ResolveImportPlanner.compatibilityWarnings(packageDirectory: package))
            let request = try ResolveImportPlanner.plan(packageDirectory: package)
            print("LIVE PLAN:", package.lastPathComponent, "clips", request.clips.map { ($0.path as NSString).lastPathComponent },
                  "subtitles", request.subtitles.map { ($0 as NSString).lastPathComponent },
                  "proxies", request.clips.compactMap { $0.proxy.map { ($0 as NSString).lastPathComponent } })
            let sent = await service.send(packageDirectory: package)
            let result = try XCTUnwrap(sent, service.errorMessage ?? "send failed")
            print("LIVE RESULT:", result.project, result.bin.joined(separator: " › "),
                  "clips", result.clips.map { "\($0.name) reused=\($0.reused) proxy=\($0.proxyLinked.map(String.init) ?? "-") metaFail=\($0.metadataFailures)" },
                  "subs", result.subtitles.map { ($0 as NSString).lastPathComponent }, "failed", result.failed)
            XCTAssertTrue(result.failed.isEmpty, "\(result.failed)")
        }
    }
}
#endif
