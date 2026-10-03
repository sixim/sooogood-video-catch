import XCTest
@testable import MediaFetchCore
@testable import MediaFetchVideo

final class PackageRelocationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("relocate-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A package like the app writes: audio + cover + manifest with SHA-256.
    @discardableResult
    private func makePackage(_ relative: String, in base: URL) throws -> URL {
        let package = base.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let audio = package.appendingPathComponent("歌.flac"), cover = package.appendingPathComponent("歌.jpg")
        try Data(repeating: 7, count: 4096).write(to: audio)
        try Data("jpg".utf8).write(to: cover)
        let files = try [audio, cover].map { ["relativePath": $0.lastPathComponent, "sha256": try ManifestWriter.sha256($0)] }
        try JSONSerialization.data(withJSONObject: ["mediaID": "1", "platform": "netease:song", "title": "歌", "files": files])
            .write(to: package.appendingPathComponent("manifest.json"))
        return package
    }

    func testDestinationKeepsArtistAlbumLayout() {
        let downloads = URL(fileURLWithPath: "/m/Sooogood Music")
        let package = downloads.appendingPathComponent("歌手/专辑/歌手 - 歌 [1]")
        XCTAssertEqual(PackageRelocation.destination(for: package, downloadRoot: downloads, target: URL(fileURLWithPath: "/Volumes/X/音乐")).path,
                       "/Volumes/X/音乐/歌手/专辑/歌手 - 歌 [1]")
        XCTAssertEqual(PackageRelocation.destination(for: URL(fileURLWithPath: "/else/包"), downloadRoot: downloads, target: URL(fileURLWithPath: "/t")).path,
                       "/t/包", "outside the download folder only the package folder moves")
    }

    func testRebaseAndExpectedHashes() {
        let old = URL(fileURLWithPath: "/a/包"), new = URL(fileURLWithPath: "/b/x/包")
        XCTAssertEqual(PackageRelocation.rebase(["/a/包/1.flac", "/a/包2/z", "/other"], from: old, to: new), ["/b/x/包/1.flac", "/a/包2/z", "/other"])
        let manifest = Data(#"{"files":[{"relativePath":"a.flac","sha256":"abc"},{"relativePath":"b.jpg"}]}"#.utf8)
        XCTAssertEqual(PackageRelocation.expectedHashes(manifest: manifest), ["a.flac": "abc"])
    }

    func testVerifyCatchesACorruptedCopy() throws {
        let package = try makePackage("包", in: root)
        let copy = root.appendingPathComponent("copy")
        try FileManager.default.copyItem(at: package, to: copy)
        XCTAssertNoThrow(try PackageMover.verify(copy: copy, of: package))
        var bytes = try Data(contentsOf: copy.appendingPathComponent("歌.flac"))
        bytes[10] = 9
        try bytes.write(to: copy.appendingPathComponent("歌.flac"))
        XCTAssertThrowsError(try PackageMover.verify(copy: copy, of: package)) {
            XCTAssertEqual($0 as? PackageMoveError, .verificationFailed("歌.flac"))
        }
        try FileManager.default.removeItem(at: copy.appendingPathComponent("歌.jpg"))
        XCTAssertThrowsError(try PackageMover.verify(copy: copy, of: package), "a missing file fails too")
    }

    func testEmptyParentsAreRemovedUpToTheRootOnly() throws {
        let downloads = root.appendingPathComponent("dl")
        let album = downloads.appendingPathComponent("歌手/专辑")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try Data().write(to: album.appendingPathComponent(".DS_Store"))
        try makePackage("歌手/另一张/包", in: downloads)
        PackageMover.removeEmptyParents(of: album, stopAt: downloads)
        XCTAssertFalse(FileManager.default.fileExists(atPath: album.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloads.appendingPathComponent("歌手").path), "歌手 still has another album")
        PackageMover.removeEmptyParents(of: downloads, stopAt: downloads)
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloads.path), "the download folder itself is never removed")
    }

#if !MEDIAFETCH_STORE_PROFILE
    @MainActor
    func testRelocateMovesPackageAndUpdatesEveryHistoryEntry() async throws {
        let downloads = root.appendingPathComponent("dl"), target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let package = try makePackage("歌手/专辑/包", in: downloads)
        let manifest = package.appendingPathComponent("manifest.json").path
        func job() -> DownloadJob {
            var job = DownloadJob(sourceURL: "https://music.163.com/song?id=1", profile: .audioOnly, destination: downloads,
                                  includeSidecars: true, includeSubtitles: false, browserCookieSource: nil)
            job.status = .completed
            job.title = "歌"
            job.musicQuality = .best
            job.manifestPath = manifest
            job.completedFiles = [package.appendingPathComponent("歌.flac").path, manifest]
            return job
        }
        var saved: [DownloadJob] = []
        let downloader = DownloaderService(jobs: [job(), job()], toolchain: .local(), historyWriter: { saved = $0 })
        let items = downloader.relocatablePackages(musicOnly: true)
        XCTAssertEqual(items.count, 1, "two history entries, one package")

        let report = await downloader.relocatePackages(items, to: target)
        XCTAssertEqual(report.moved, ["歌"])
        let moved = target.appendingPathComponent("歌手/专辑/包")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("歌.flac").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloads.appendingPathComponent("歌手").path), "emptied folders are cleaned up")
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloads.path))
        for entry in downloader.jobs {
            XCTAssertEqual(entry.manifestPath, moved.appendingPathComponent("manifest.json").path)
            XCTAssertEqual(entry.completedFiles.first, moved.appendingPathComponent("歌.flac").path)
            XCTAssertEqual(entry.destinationPath, target.path)
        }
        XCTAssertEqual(saved.count, 2, "history persisted")

        // Moving again to the same place is a no-op, and an existing target is never overwritten.
        let again = await downloader.relocatePackages(downloader.relocatablePackages(musicOnly: true), to: target)
        XCTAssertEqual(again.moved, [])
        XCTAssertEqual(again.skipped.first?.reason, PackageRelocation.Skip.alreadyThere.message)
        let other = root.appendingPathComponent("other")
        try makePackage("歌手/专辑/包", in: other)
        let clash = await downloader.relocatePackages(downloader.relocatablePackages(musicOnly: true), to: other)
        XCTAssertEqual(clash.moved, [])
        XCTAssertTrue(clash.skipped.first?.reason.contains("未覆盖") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path), "source kept when the target exists")

        // Moved packages still count as "already have".
        let index = LocalMusicIndex(items: LocalMusicIndex.manifestItems(packages: [moved], except: downloads))
        XCTAssertNotNil(index.existingPath(platform: .netease, mediaID: "1"))
    }
#endif

    /// Opt-in: MF_TEST_OTHER_VOLUME points at a folder on another disk (e.g. a mounted .dmg).
    func testCrossVolumeMoveCopiesVerifiesThenRemoves() throws {
        guard let other = ProcessInfo.processInfo.environment["MF_TEST_OTHER_VOLUME"] else { throw XCTSkip("set MF_TEST_OTHER_VOLUME") }
        let package = try makePackage("包", in: root)
        let destination = URL(fileURLWithPath: other).appendingPathComponent("relocate-\(UUID().uuidString)/包")
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        XCTAssertFalse(PackageMover.sameVolume(package, URL(fileURLWithPath: other)))
        XCTAssertTrue(try PackageMover.move(package: package, to: destination), "copied across volumes")
        XCTAssertNoThrow(try ManifestWriter.sha256(destination.appendingPathComponent("歌.flac")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path), "original removed after verification")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path).filter { $0.hasPrefix(".sooogood-move") }
        XCTAssertEqual(leftovers, [], "no staging folder left")
    }
}
