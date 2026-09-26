import Foundation
import XCTest
@testable import MediaFetch
@testable import MediaFetchCore
@testable import MediaFetchMusic

final class SpotifyBridgeCoreTests: XCTestCase {
    func testDemoFixtureContainsSyntheticMetadataOnly() {
        XCTAssertEqual(SpotifyDemoFixture.collection.tracks.count, 4)
        XCTAssertNil(SpotifyDemoFixture.collection.coverURL)
        XCTAssertTrue(SpotifyDemoFixture.tracks.allSatisfy { $0.externalURL == nil })
        XCTAssertTrue(SpotifyDemoFixture.emptyItems.allSatisfy { $0.source == nil })
    }

    func testDemoAudioFactoryWritesLocalSilentWAVs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaFetch-demo-audio-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let urls = try SpotifyDemoAudioFactory.prepare(
            in: directory,
            tracks: SpotifyDemoFixture.tracks
        )

        XCTAssertEqual(urls.count, 2)
        for url in urls {
            let bytes = try Data(contentsOf: url)
            XCTAssertGreaterThan(bytes.count, 44)
            XCTAssertEqual(Data(bytes.prefix(4)), Data("RIFF".utf8))
            XCTAssertEqual(url.pathExtension, "wav")
        }
    }

    func testUniqueHighConfidenceMatchBecomesReady() {
        let track = makeTrack(id: "track-a", title: "First Light", album: "Album One", durationMS: 180_000)
        let strong = makeCandidate(
            name: "strong.m4a",
            title: "First Light",
            album: "Album One",
            durationMS: 181_000
        )
        let weak = makeCandidate(
            name: "weak.m4a",
            title: "First Light",
            album: nil,
            durationMS: nil
        )

        let item = SpotifyMatcher().match(track: track, candidates: [weak, strong])

        XCTAssertEqual(item.status, .ready)
        XCTAssertEqual(item.evidence?.score, 95)
        XCTAssertEqual(item.matches.map(\.evidence.score), [95, 85])
        XCTAssertEqual(item.source, .localFile(strong.url))
    }

    func testHighConfidenceMatchNeedsTenPointLead() {
        let track = makeTrack(id: "track-a", title: "First Light", album: "Album One", durationMS: 180_000)
        let score95 = makeCandidate(
            name: "score95.m4a",
            title: "First Light",
            album: "Album One",
            durationMS: 180_100
        )
        let score90 = makeCandidate(
            name: "score90.m4a",
            title: "First Light",
            album: "Different Album",
            durationMS: 180_100
        )

        let item = SpotifyMatcher().match(track: track, candidates: [score95, score90])

        XCTAssertEqual(item.status, .ambiguous)
        XCTAssertNil(item.source)
        XCTAssertEqual(item.matches.map(\.evidence.score), [95, 90])
    }

    func testISRCMatchScoresOneHundred() {
        let track = makeTrack(id: "track-a", title: "Different Metadata", isrc: "US-RC1-23-00001")
        let candidate = makeCandidate(
            name: "isrc.flac",
            title: "Not The Same Title",
            artists: ["Another Artist"],
            isrc: "usrc12300001"
        )

        let item = SpotifyMatcher().match(track: track, candidates: [candidate])

        XCTAssertEqual(item.status, .ready)
        XCTAssertEqual(item.evidence?.score, 100)
        XCTAssertEqual(item.evidence?.matchedFields, [.isrc])
    }

    func testMatchingISRCDoesNotOverrideExplicitCleanConflict() {
        let track = makeTrack(id: "explicit-isrc", title: "Same Song", isExplicit: true, isrc: "USAAA2600001")
        let candidate = makeCandidate(
            name: "same-clean.m4a",
            title: "Same Song",
            isrc: "USAAA2600001",
            isExplicit: false
        )

        let result = SpotifyMatcher().match(track: track, candidates: [candidate])

        XCTAssertEqual(result.status, .ambiguous)
        XCTAssertEqual(result.evidence?.score, 85)
        XCTAssertEqual(result.evidence?.versionConflict, true)
        XCTAssertNil(result.source)
    }

    func testMatchingISRCDoesNotOverrideLiveStudioConflict() {
        let track = makeTrack(id: "live-isrc", title: "First Light (Live)", isrc: "USAAA2600002")
        let candidate = makeCandidate(
            name: "studio.m4a",
            title: "First Light",
            isrc: "USAAA2600002"
        )

        let result = SpotifyMatcher().match(track: track, candidates: [candidate])

        XCTAssertEqual(result.status, .ambiguous)
        XCTAssertEqual(result.evidence?.score, 85)
        XCTAssertEqual(result.evidence?.versionConflict, true)
        XCTAssertNil(result.source)
    }

    func testVersionDifferenceIsCandidateOnly() {
        let track = makeTrack(id: "track-a", title: "First Light (Live)", durationMS: 180_000)
        let studio = makeCandidate(
            name: "studio.m4a",
            title: "First Light",
            durationMS: 180_000
        )

        var item = SpotifyMatcher().match(track: track, candidates: [studio])

        XCTAssertEqual(item.status, .ambiguous)
        XCTAssertNil(item.source)
        XCTAssertEqual(item.evidence?.score, 85)
        XCTAssertEqual(item.evidence?.versionConflict, true)

        item.confirm(candidate: studio)
        XCTAssertEqual(item.status, .ready)
        XCTAssertEqual(item.evidence?.userConfirmed, true)
    }

    func testExplicitAndCleanMetadataConflictNeverAutomaticallyMatches() {
        let track = makeTrack(id: "explicit", title: "Same Song", isExplicit: true)
        let cleanCandidate = makeCandidate(
            name: "same-song.flac",
            title: "Same Song",
            isExplicit: false
        )

        let result = SpotifyMatcher().match(track: track, candidates: [cleanCandidate])

        XCTAssertEqual(result.status, .ambiguous)
        XCTAssertEqual(result.evidence?.versionConflict, true)
        XCTAssertLessThan(result.evidence?.score ?? 100, 95)
    }

    func testMissingLocalExplicitEvidenceRequiresManualConfirmation() {
        let track = makeTrack(id: "explicit-unknown", title: "Same Song", isExplicit: true)
        let untaggedCandidate = makeCandidate(name: "same-song.flac", title: "Same Song")

        let result = SpotifyMatcher().match(track: track, candidates: [untaggedCandidate])

        XCTAssertEqual(result.status, .ambiguous)
        XCTAssertEqual(result.evidence?.score, 90)
        XCTAssertTrue(result.evidence?.reasons.joined().contains("Explicit/Clean") == true)
    }

    func testMatchingExplicitEvidenceCanReachAutomaticThreshold() {
        let track = makeTrack(id: "explicit-match", title: "Same Song", isExplicit: true)
        let explicitCandidate = makeCandidate(
            name: "same-song.flac",
            title: "Same Song",
            isExplicit: true
        )

        XCTAssertEqual(
            SpotifyMatcher().match(track: track, candidates: [explicitCandidate]).status,
            .ready
        )
    }

    func testFilenameFallbackNeverAutomaticallyMatches() {
        let track = makeTrack(id: "track-a", title: "First Light", durationMS: 180_000)
        let candidate = makeCandidate(
            name: "filename.m4a",
            title: "Example Artist - First Light",
            artists: [],
            durationMS: 180_000,
            titleWasFilenameFallback: true
        )

        let item = SpotifyMatcher().match(track: track, candidates: [candidate])

        XCTAssertEqual(item.status, .ambiguous)
        XCTAssertLessThan(item.evidence?.score ?? 100, 95)
        XCTAssertTrue(item.evidence?.matchedFields.contains(.filenameFallback) == true)
    }

#if !MEDIAFETCH_STORE_PROFILE
    func testScannerUsesRealFFprobeAndSkipsHiddenPackagesAndEscapingSymlinks() throws {
        let ffmpeg = availableExecutable(["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"])
        let ffprobe = availableExecutable(["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"])
        guard let ffmpeg, let ffprobe else {
            throw XCTSkip("需要 Homebrew ffmpeg/ffprobe 执行真实音频扫描验收")
        }

        let root = temporaryDirectory(prefix: "spotify-scan-root")
        let outside = temporaryDirectory(prefix: "spotify-scan-outside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let audio = root.appendingPathComponent("clip;touch-never-runs.m4a")
        try runProcess(ffmpeg, arguments: [
            "-v", "error",
            "-f", "lavfi",
            "-i", "anullsrc=r=44100:cl=stereo",
            "-t", "0.20",
            "-c:a", "aac",
            "-metadata", "title=First Light",
            "-metadata", "artist=Example Artist",
            "-metadata", "album=Album One",
            "-metadata", "track=3/10",
            "-metadata", "disc=1/1",
            "-y", audio.path
        ])

        let hidden = root.appendingPathComponent(".hidden.m4a")
        try FileManager.default.copyItem(at: audio, to: hidden)
        let package = root.appendingPathComponent("Ignore.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: audio, to: package.appendingPathComponent("inside.m4a"))
        let outsideAudio = outside.appendingPathComponent("outside.m4a")
        try FileManager.default.copyItem(at: audio, to: outsideAudio)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape.m4a"),
            withDestinationURL: outsideAudio
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("duplicate.m4a"),
            withDestinationURL: audio
        )

        let candidates = try LocalAudioScanner(ffprobePath: ffprobe).scan(directory: root)

        XCTAssertEqual(candidates.count, 1)
        let result = try XCTUnwrap(candidates.first)
        XCTAssertEqual(result.url, audio)
        XCTAssertEqual(result.title, "First Light")
        XCTAssertEqual(result.artists, ["Example Artist"])
        XCTAssertEqual(result.album, "Album One")
        XCTAssertEqual(result.trackNumber, 3)
        XCTAssertEqual(result.discNumber, 1)
        XCTAssertEqual(result.codec, "aac")
        XCTAssertGreaterThan(result.durationMS ?? 0, 0)
        XCTAssertGreaterThan(result.byteSize, 0)
        XCTAssertNil(result.probeWarning)
    }
#endif

    func testNativeScannerReadsAudioWithoutExternalHelper() async throws {
        let root = temporaryDirectory(prefix: "spotify-native-scan")
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = root.appendingPathComponent("native-track.wav")
        try makeSilentWAV(durationMilliseconds: 1_000).write(to: audio)

        let candidates = try await NativeAudioScanner().scan(directory: root)

        XCTAssertEqual(candidates.count, 1)
        let result = try XCTUnwrap(candidates.first)
        XCTAssertEqual(result.url, audio.standardizedFileURL)
        XCTAssertGreaterThanOrEqual(result.durationMS ?? 0, 900)
        XCTAssertGreaterThan(result.byteSize, 44)
        XCTAssertNil(result.probeWarning)
    }

    func testBridgeCopiesBytesPreservesOrderAndWritesV2Manifest() async throws {
        let sourceDirectory = temporaryDirectory(prefix: "spotify-source")
        let packageDirectory = temporaryDirectory(prefix: "spotify-package")
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: packageDirectory)
        }

        let firstSource = sourceDirectory.appendingPathComponent("first.m4a")
        let secondSource = sourceDirectory.appendingPathComponent("second.m4a")
        try Data("first-original-audio".utf8).write(to: firstSource)
        try Data("second-original-audio".utf8).write(to: secondSource)
        let firstOriginalHash = try ManifestWriter.sha256(firstSource)
        let secondOriginalHash = try ManifestWriter.sha256(secondSource)

        let firstTrack = makeTrack(id: "first-id", title: "Same Name", trackNumber: 1)
        let secondTrack = makeTrack(id: "second-id", title: "Same Name", trackNumber: 1)
        let collection = makeCollection(tracks: [firstTrack, secondTrack])
        var firstItem = SpotifyBridgeItem(track: firstTrack)
        firstItem.confirm(source: .localFile(firstSource))
        var secondItem = SpotifyBridgeItem(track: secondTrack)
        secondItem.confirm(source: .localFile(secondSource))

        let result = try await SpotifyBridgeService().save(
            collection: collection,
            items: [firstItem, secondItem],
            packageDirectory: packageDirectory
        )

        XCTAssertEqual(result.completedCount, 2)
        XCTAssertEqual(try ManifestWriter.sha256(firstSource), firstOriginalHash)
        XCTAssertEqual(try ManifestWriter.sha256(secondSource), secondOriginalHash)
        XCTAssertEqual(result.items[0].sourceSHA256, result.items[0].outputSHA256)
        XCTAssertEqual(result.items[1].sourceSHA256, result.items[1].outputSHA256)

        let firstRelativePath = try XCTUnwrap(result.items[0].outputRelativePath)
        let secondRelativePath = try XCTUnwrap(result.items[1].outputRelativePath)
        XCTAssertTrue(firstRelativePath.hasPrefix("audio/01-01 Example Artist - Same Name"))
        XCTAssertTrue(secondRelativePath.hasPrefix("audio/01-01 Example Artist - Same Name"))
        XCTAssertTrue(secondRelativePath.contains("[second-id]"))

        let playlist = try String(contentsOf: result.playlistURL, encoding: .utf8)
        let firstRange = try XCTUnwrap(playlist.range(of: firstRelativePath))
        let secondRange = try XCTUnwrap(playlist.range(of: secondRelativePath))
        XCTAssertLessThan(firstRange.lowerBound, secondRange.lowerBound)

        let manifestObject = try JSONSerialization.jsonObject(
            with: Data(contentsOf: result.manifestURL)
        ) as? [String: Any]
        XCTAssertEqual(manifestObject?["schemaVersion"] as? Int, 2)
        let records = manifestObject?["items"] as? [[String: Any]]
        XCTAssertEqual(records?.count, 2)
        XCTAssertEqual(records?.first?["sourceFileName"] as? String, "first.m4a")
        XCTAssertEqual(records?.first?["status"] as? String, "completed")
    }

    func testBridgeSkipsUnmatchedItems() async throws {
        let sourceDirectory = temporaryDirectory(prefix: "spotify-partial-source")
        let packageDirectory = temporaryDirectory(prefix: "spotify-partial-package")
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: packageDirectory)
        }
        let source = sourceDirectory.appendingPathComponent("owned.m4a")
        try Data("owned".utf8).write(to: source)
        let availableTrack = makeTrack(id: "available", title: "Available", trackNumber: 1)
        let missingTrack = makeTrack(id: "missing", title: "Missing", trackNumber: 2)
        var available = SpotifyBridgeItem(track: availableTrack)
        available.confirm(source: .localFile(source))
        let missing = SpotifyBridgeItem(track: missingTrack, status: .unmatched)

        let result = try await SpotifyBridgeService().save(
            collection: makeCollection(tracks: [availableTrack, missingTrack]),
            items: [available, missing],
            packageDirectory: packageDirectory
        )

        XCTAssertEqual(result.completedCount, 1)
        XCTAssertEqual(result.items[1].status, .unmatched)
        let playlist = try String(contentsOf: result.playlistURL, encoding: .utf8)
        XCTAssertTrue(playlist.contains("Available"))
        XCTAssertFalse(playlist.contains("Missing"))
    }

    func testNewPackageRecopiesPreviouslyCompletedItemsWithoutDanglingPlaylistPaths() async throws {
        let temporaryDirectory = temporaryDirectory(prefix: "spotify-retry-package")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let firstSource = temporaryDirectory.appendingPathComponent("first.flac")
        let secondSource = temporaryDirectory.appendingPathComponent("second.flac")
        try Data("first-audio".utf8).write(to: firstSource)
        try Data("second-audio".utf8).write(to: secondSource)

        let firstTrack = makeTrack(id: "track-first", title: "First", trackNumber: 1)
        let secondTrack = makeTrack(id: "track-second", title: "Second", trackNumber: 2)
        let collection = SpotifyCollection(
            id: "playlist-retry",
            kind: .playlist,
            uri: "spotify:playlist:playlist-retry",
            externalURL: nil,
            title: "Retry",
            tracks: [firstTrack, secondTrack]
        )
        let staleItem = SpotifyBridgeItem(
            track: firstTrack,
            source: .localFile(firstSource),
            evidence: MatchEvidence(score: 100, matchedFields: [.isrc]),
            status: .completed,
            outputRelativePath: "audio/from-an-older-package.flac",
            sourceSHA256: "old-source-hash",
            outputSHA256: "old-output-hash"
        )
        let retryItem = SpotifyBridgeItem(
            track: secondTrack,
            source: .localFile(secondSource),
            evidence: MatchEvidence(score: 0, matchedFields: [], userConfirmed: true),
            status: .ready
        )
        let packageDirectory = temporaryDirectory.appendingPathComponent("new-package", isDirectory: true)

        let result = try await SpotifyBridgeService().save(
            collection: collection,
            items: [staleItem, retryItem],
            packageDirectory: packageDirectory
        )

        XCTAssertEqual(result.completedCount, 2)
        for item in result.items {
            let relativePath: String = try XCTUnwrap(item.outputRelativePath)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: packageDirectory.appendingPathComponent(relativePath).path
            ))
            XCTAssertEqual(item.sourceSHA256, item.outputSHA256)
        }
        let playlist = try String(contentsOf: result.playlistURL, encoding: .utf8)
        XCTAssertFalse(playlist.contains("from-an-older-package.flac"))
    }

    func testSpotifyHistoryIsSeparateFromVideoHistoryAndRoundTrips() throws {
        XCTAssertNotEqual(SpotifyHistoryStore.historyURL, JobHistoryStore.historyURL)
        XCTAssertEqual(SpotifyHistoryStore.historyURL.lastPathComponent, "spotify-history.json")

        let record = SpotifyBridgeHistoryRecord(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000099")!,
            createdAt: Date(timeIntervalSince1970: 1_000),
            collectionID: "playlist-history",
            collectionKind: .playlist,
            collectionTitle: "History",
            packagePath: "/tmp/music-package",
            manifestPath: "/tmp/music-package/manifest.json",
            savedCount: 8
        )

        let data = try SpotifyHistoryStore.encoded([record])
        XCTAssertEqual(try SpotifyHistoryStore.decoded(data), [record])
    }

    func testTenTrackAcceptanceOutputsOnlyEightAvailableSourcesInOrder() async throws {
        let root = temporaryDirectory(prefix: "spotify-ten-track-acceptance")
        defer { try? FileManager.default.removeItem(at: root) }

        let tracks = (1...10).map { index in
            makeTrack(
                id: "acceptance-track-\(index)",
                title: "Track \(index)",
                trackNumber: index,
                durationMS: 180_000 + index * 1_000,
                isrc: "USACC2600\(String(format: "%03d", index))"
            )
        }
        var items: [SpotifyBridgeItem] = []
        for (offset, track) in tracks.enumerated() {
            guard offset < 8 else {
                items.append(SpotifyBridgeItem(track: track, status: .unmatched))
                continue
            }
            let source = root.appendingPathComponent("source-\(offset + 1).flac")
            try Data("owned-audio-\(offset + 1)".utf8).write(to: source)
            items.append(SpotifyBridgeItem(
                track: track,
                source: .localFile(source),
                evidence: MatchEvidence(score: 100, matchedFields: [.isrc]),
                status: .ready
            ))
        }

        let packageDirectory = root.appendingPathComponent("package", isDirectory: true)
        let result = try await SpotifyBridgeService().save(
            collection: makeCollection(tracks: tracks),
            items: items,
            packageDirectory: packageDirectory
        )

        XCTAssertEqual(result.completedCount, 8)
        XCTAssertEqual(result.items.filter { $0.status == .unmatched }.count, 2)
        let playlistLines = try String(contentsOf: result.playlistURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasPrefix("#") }
        XCTAssertEqual(playlistLines.count, 8)
        for index in 1...8 {
            XCTAssertTrue(playlistLines[index - 1].contains(String(format: "01-%02d", index)))
        }

        let manifestData = try Data(contentsOf: result.manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(SpotifyBridgeManifestV2.self, from: manifestData)
        XCTAssertEqual(manifest.items.count, 10)
        XCTAssertEqual(manifest.items.filter { $0.status == .completed }.count, 8)
        for item in manifest.items where item.status == .completed {
            XCTAssertEqual(item.sourceSHA256, item.outputSHA256)
        }
    }

    func testAuthorizedDirectURLPolicyRejectsSpotifyAndAllowsUnrelatedHTTPS() {
        let forbidden = [
            "https://spotify.com/audio.m4a",
            "https://open.spotify.com/audio.m4a",
            "https://audio.scdn.co/file.m4a",
            "https://deep.audio.scdn.co/file.m4a"
        ]
        for value in forbidden {
            XCTAssertThrowsError(try SpotifyBridgeService.validateAuthorizedDirectURL(URL(string: value)!))
        }
        XCTAssertThrowsError(
            try SpotifyBridgeService.validateAuthorizedDirectURL(URL(string: "http://media.example/audio.m4a")!)
        )
        XCTAssertNoThrow(
            try SpotifyBridgeService.validateAuthorizedDirectURL(
                URL(string: "https://spotify.com.evil.example/audio.m4a")!
            )
        )
        XCTAssertThrowsError(
            try SpotifyBridgeService.validateRedirectDestination(
                URL(string: "https://audio-fa.scdn.co/file.opus")!
            )
        )
        XCTAssertThrowsError(
            try SpotifyBridgeService.validateRedirectDestination(
                URL(string: "http://media.example/file.flac")!
            )
        )
        XCTAssertNoThrow(
            try SpotifyBridgeService.validateRedirectDestination(
                URL(string: "https://cdn.example.com/file.flac")!
            )
        )
    }

    func testAuthorizedDirectURLUsesInjectedDownloaderWithoutTranscoding() async throws {
        let sourceDirectory = temporaryDirectory(prefix: "spotify-direct-source")
        let packageDirectory = temporaryDirectory(prefix: "spotify-direct-package")
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: packageDirectory)
        }
        let downloadedFile = sourceDirectory.appendingPathComponent("downloaded.m4a")
        try Data("authorized-direct-bytes".utf8).write(to: downloadedFile)
        let sourceHash = try ManifestWriter.sha256(downloadedFile)
        let track = makeTrack(id: "direct", title: "Authorized")
        var item = SpotifyBridgeItem(track: track)
        item.confirm(source: .authorizedDirectURL(URL(string: "https://media.example/audio?id=1")!))

        let service = SpotifyBridgeService { _ in
            SpotifyDirectDownload(
                temporaryURL: downloadedFile,
                finalURL: URL(string: "https://cdn.example/final")!,
                suggestedFilename: "owned.m4a",
                mimeType: "audio/mp4"
            )
        }
        let result = try await service.save(
            collection: makeCollection(tracks: [track]),
            items: [item],
            packageDirectory: packageDirectory
        )

        XCTAssertEqual(result.completedCount, 1)
        XCTAssertEqual(result.items.first?.sourceSHA256, sourceHash)
        XCTAssertEqual(result.items.first?.sourceSHA256, result.items.first?.outputSHA256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadedFile.path))
    }

    func testAuthorizedDirectURLRejectsHTTPSRedirectToHTTP() async throws {
        let sourceDirectory = temporaryDirectory(prefix: "spotify-insecure-redirect-source")
        let packageDirectory = temporaryDirectory(prefix: "spotify-insecure-redirect-package")
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: packageDirectory)
        }
        let downloadedFile = sourceDirectory.appendingPathComponent("downloaded.m4a")
        try Data("must-not-be-copied".utf8).write(to: downloadedFile)
        let track = makeTrack(id: "insecure", title: "Insecure Redirect")
        var item = SpotifyBridgeItem(track: track)
        item.confirm(source: .authorizedDirectURL(URL(string: "https://media.example/audio.m4a")!))
        let service = SpotifyBridgeService { _ in
            SpotifyDirectDownload(
                temporaryURL: downloadedFile,
                finalURL: URL(string: "http://cdn.example/audio.m4a")!
            )
        }

        let result = try await service.save(
            collection: makeCollection(tracks: [track]),
            items: [item],
            packageDirectory: packageDirectory
        )

        XCTAssertEqual(result.items.first?.status, .failed)
        XCTAssertTrue(result.items.first?.failureReason?.contains("非 HTTPS") == true)
        let outputs = try FileManager.default.contentsOfDirectory(
            at: packageDirectory.appendingPathComponent("audio"),
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(outputs.isEmpty)
    }

    private func makeTrack(
        id: String,
        title: String,
        artists: [String] = ["Example Artist"],
        album: String? = "Album One",
        discNumber: Int = 1,
        trackNumber: Int = 1,
        durationMS: Int = 180_000,
        isExplicit: Bool? = nil,
        isrc: String? = nil
    ) -> SpotifyTrackReference {
        SpotifyTrackReference(
            id: id,
            uri: "spotify:track:\(id)",
            externalURL: URL(string: "https://open.spotify.com/track/\(id)"),
            title: title,
            artists: artists,
            album: album,
            discNumber: discNumber,
            trackNumber: trackNumber,
            durationMS: durationMS,
            isExplicit: isExplicit,
            isrc: isrc
        )
    }

    private func makeCandidate(
        name: String,
        title: String,
        artists: [String] = ["Example Artist"],
        album: String? = "Album One",
        durationMS: Int? = 180_000,
        isrc: String? = nil,
        isExplicit: Bool? = nil,
        titleWasFilenameFallback: Bool = false
    ) -> LocalAudioCandidate {
        LocalAudioCandidate(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            title: title,
            artists: artists,
            album: album,
            durationMS: durationMS,
            isrc: isrc,
            isExplicit: isExplicit,
            byteSize: 100,
            titleWasFilenameFallback: titleWasFilenameFallback
        )
    }

    private func makeCollection(tracks: [SpotifyTrackReference]) -> SpotifyCollection {
        SpotifyCollection(
            id: "collection-id",
            kind: .playlist,
            uri: "spotify:playlist:collection-id",
            externalURL: URL(string: "https://open.spotify.com/playlist/collection-id"),
            title: "Test Collection",
            tracks: tracks
        )
    }

    private func temporaryDirectory(prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func availableExecutable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func runProcess(_ executable: String, arguments: [String]) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "process failed"
            XCTFail(message)
            throw NSError(domain: "SpotifyBridgeCoreTests", code: Int(process.terminationStatus))
        }
    }

    private func makeSilentWAV(durationMilliseconds: Int) -> Data {
        let sampleRate: UInt32 = 8_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let sampleCount = Int(sampleRate) * durationMilliseconds / 1_000
        let dataLength = UInt32(sampleCount * Int(channels) * Int(bitsPerSample / 8))
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(UInt32(36) + dataLength)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(dataLength)
        data.append(contentsOf: repeatElement(UInt8(0), count: Int(dataLength)))
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
