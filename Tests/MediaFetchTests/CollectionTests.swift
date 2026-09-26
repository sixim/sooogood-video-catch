import XCTest
@testable import MediaFetchCore
@testable import MediaFetchVideo

final class CollectionTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

    func testParsesYouTubeFlatPlaylistInOrder() throws {
        let outline = try XCTUnwrap(CollectionOutline.parse(json("""
        {"_type":"playlist","id":"PL1","title":"Popular Music Videos","extractor_key":"YoutubeTab","entries":[
         {"_type":"url","ie_key":"Youtube","id":"a","title":"A","url":"https://www.youtube.com/watch?v=a","duration":235,"playlist_index":null},
         {"_type":"url","ie_key":"Youtube","id":"b","title":"B","url":"https://www.youtube.com/watch?v=b"}]}
        """)))
        XCTAssertEqual(outline.entries.map(\.index), [1, 2])
        XCTAssertEqual(outline.entries.first?.duration, 235)
        XCTAssertFalse(outline.isCourse)
        XCTAssertEqual(outline.chapters.count, 1)
    }

    func testParsesUdemyChaptersAndSmuggledURLs() throws {
        let outline = try XCTUnwrap(CollectionOutline.parse(json("""
        {"_type":"playlist","id":"123","title":"Swift: Zero/Hero","extractor_key":"UdemyCourse","entries":[
         {"_type":"url_transparent","ie_key":"Udemy","id":"1","title":"Intro","url":"https://www.udemy.com/course/x/learn/v4/t/lecture/1#__youtubedl_smuggle=%7B%7D","chapter":"Getting Started","chapter_number":1},
         {"_type":"url_transparent","ie_key":"Udemy","id":"2","title":"Setup","url":"https://www.udemy.com/course/x/learn/v4/t/lecture/2","chapter":"Getting Started","chapter_number":1},
         {"_type":"url_transparent","ie_key":"Udemy","id":"3","title":"Optionals","url":"https://www.udemy.com/course/x/learn/v4/t/lecture/3","chapter":"Basics","chapter_number":2}]}
        """)))
        XCTAssertTrue(outline.isCourse)
        XCTAssertEqual(outline.chapters.map(\.title), ["Getting Started", "Basics"])
        XCTAssertEqual(outline.chapters.map { $0.entries.count }, [2, 1])
        XCTAssertTrue(outline.entries[0].url.contains("smuggle"), "smuggled course context is preserved")
        XCTAssertEqual(outline.rootFolderName, "Swift： Zero／Hero")
        let context = outline.context(for: outline.entries[2])
        XCTAssertEqual(context.chapterFolder, "02 Basics")
    }

    func testBilibiliCheeseEntriesWithoutURLGetEpisodeLinks() throws {
        let outline = try XCTUnwrap(CollectionOutline.parse(json("""
        {"_type":"playlist","id":"5918","title":"课程","extractor_key":"BilibiliCheeseSeason","entries":[
         {"id":"229832","title":"1 - 课程先导片","episode_number":1,"extractor_key":"BilibiliCheese","duration":221}]}
        """)))
        XCTAssertEqual(outline.entries.first?.url, "https://www.bilibili.com/cheese/play/ep229832")
        XCTAssertTrue(outline.isCourse)
        XCTAssertNil(CollectionOutline.parse(try json(#"{"_type":"video","id":"x"}"#)))
    }

    func testDetector() {
        func check(_ string: String) -> Bool { CollectionDetector.looksLikeCollection(URL(string: string)!) }
        XCTAssertTrue(check("https://www.youtube.com/playlist?list=PL1"))
        XCTAssertFalse(check("https://www.youtube.com/watch?v=a&list=PL1"))
        XCTAssertTrue(CollectionDetector.hasPlaylistContext(URL(string: "https://www.youtube.com/watch?v=a&list=PL1")!))
        XCTAssertTrue(check("https://www.udemy.com/course/swift-bootcamp/"))
        XCTAssertFalse(check("https://www.udemy.com/course/x/learn/lecture/5"))
        XCTAssertTrue(check("https://www.bilibili.com/cheese/play/ss5918"))
        XCTAssertFalse(check("https://www.bilibili.com/video/BV1xx"))
        XCTAssertEqual(StreamingPlatform.detect(URL(string: "https://www.udemy.com/course/x/")!), .udemy)
        XCTAssertEqual(SiteSessionCookies.domains(for: .udemy), ["udemy.com"])
    }

    func testOutputTemplateNestsChaptersAndEscapesPercent() {
        let context = CollectionContext(collectionID: "1", collectionTitle: "100% Swift", extractor: "UdemyCourse",
                                        rootFolderName: CollectionPaths.safeComponent("100% Swift"), index: 7,
                                        chapterNumber: 3, chapterTitle: "Closures: basics")
        XCTAssertEqual(CollectionPaths.outputTemplate(for: context, separateStreams: false),
                       "100%% Swift/03 Closures： basics/007 - %(title).150B [%(id)s]/007 - %(title).150B [%(id)s].%(ext)s")
        XCTAssertEqual(CollectionPaths.safeComponent("../../etc"), "／..／etc")
        XCTAssertFalse(CollectionPaths.safeComponent("../../etc").contains("/"))
        XCTAssertFalse(CollectionPaths.safeComponent("..hidden").hasPrefix("."))
    }

    func testBuilderUsesCollectionTemplateAndPacesCoursePlatforms() {
        var job = DownloadJob(sourceURL: "https://www.udemy.com/course/x/learn/v4/t/lecture/1", profile: .highest,
                              destination: URL(fileURLWithPath: "/tmp"), includeSidecars: false, includeSubtitles: false,
                              browserCookieSource: nil)
        job.collection = CollectionContext(collectionID: "1", collectionTitle: "C", extractor: "UdemyCourse",
                                           rootFolderName: "C", index: 1, chapterNumber: nil, chapterTitle: nil)
        let args = YtDLPArgumentBuilder.downloadArguments(job: job, destination: URL(fileURLWithPath: "/tmp"), ffmpegPath: nil,
                                                          state: EngineAttemptState(), sessionRateLimitCount: 0, cookieArguments: [])
        XCTAssertEqual(args[args.firstIndex(of: "--output")! + 1], "C/001 - %(title).150B [%(id)s]/001 - %(title).150B [%(id)s].%(ext)s")
        XCTAssertTrue(args.contains("--sleep-requests"), "course platforms are always paced")
        XCTAssertTrue(YtDLPArgumentBuilder.expansionArguments(url: "https://www.youtube.com/playlist?list=1", cookieArguments: [])
            .starts(with: ["--flat-playlist", "--dump-single-json"]))
    }

    func testCollectionManifestUpsertsEntries() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mf-coll-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = CollectionContext(collectionID: "9", collectionTitle: "Course", extractor: "UdemyCourse",
                                        rootFolderName: "Course", index: 2, chapterNumber: 1, chapterTitle: "Intro")
        let package = dir.appendingPathComponent("Course/01 Intro/002 - Lesson [2]/manifest.json")
        try CollectionManifestWriter.record(destination: dir, context: context, sourceURL: "u", title: "Lesson",
                                            status: .failed, packageManifest: nil, note: "x")
        try CollectionManifestWriter.record(destination: dir, context: context, sourceURL: "u", title: "Lesson",
                                            status: .completed, packageManifest: package)
        var drm = context
        drm = CollectionContext(collectionID: "9", collectionTitle: "Course", extractor: "UdemyCourse", rootFolderName: "Course",
                                index: 1, chapterNumber: 1, chapterTitle: "Intro")
        try CollectionManifestWriter.record(destination: dir, context: drm, sourceURL: "v", title: "Protected",
                                            status: .drmSkipped, packageManifest: nil)
        let manifest = try json(String(contentsOf: dir.appendingPathComponent("Course/collection-manifest.json"), encoding: .utf8))
        let entries = try XCTUnwrap(manifest["entries"]?.arrayValue)
        XCTAssertEqual(entries.map { $0["index"]?.intValue }, [1, 2], "sorted, one row per index")
        XCTAssertEqual(entries[0]["status"]?.stringValue, "drm_skipped")
        XCTAssertEqual(entries[1]["status"]?.stringValue, "completed")
        XCTAssertEqual(entries[1]["packageManifest"]?.stringValue, "01 Intro/002 - Lesson [2]/manifest.json")
    }
}
