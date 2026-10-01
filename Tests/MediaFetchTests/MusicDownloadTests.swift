import XCTest
@testable import MediaFetchCore
@testable import MediaFetchVideo

final class MusicDownloadTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

    func testParsesNetEaseTrackShapeFromYtDlp() throws {
        // Shape captured from yt-dlp 2026.08.19 (netease:song, not logged in).
        let track = try XCTUnwrap(MusicTrackInfo.parse(json("""
        {"id":"1973665667","title":"海屿你","creators":["马也_Crabbit"],"artists":null,"album":"海屿你",
         "album_artists":["马也_Crabbit"],"duration":295,"thumbnail":"http://p2.music.126.net/x.jpg",
         "subtitles":{"lyrics":[{"ext":"lrc"}]},
         "formats":[{"format_id":"standard","ext":"mp3","acodec":"mp3","vcodec":"none","abr":128,"filesize":4735917},
                    {"format_id":"higher","ext":"mp3","acodec":"mp3","vcodec":"none","abr":192},
                    {"format_id":"exhigh","ext":"mp3","acodec":"mp3","vcodec":"none","abr":320}]}
        """)))
        XCTAssertEqual(track.artistLine, "马也_Crabbit")
        XCTAssertEqual(track.album, "海屿你")
        XCTAssertTrue(track.hasLyrics)
        XCTAssertEqual(track.availableTiers, [.standard, .higher, .high])
        XCTAssertEqual(track.bestTier, .high)
        XCTAssertEqual(track.formats.first?.fileSize, 4735917)
    }

    func testClassifiesQQAndLosslessFormats() {
        XCTAssertEqual(MusicQualityTier.classify(formatID: "flac", codec: nil, ext: "flac", bitrate: nil, sampleRate: nil), .lossless)
        XCTAssertEqual(MusicQualityTier.classify(formatID: "ape", codec: nil, ext: "ape", bitrate: nil, sampleRate: nil), .lossless)
        XCTAssertEqual(MusicQualityTier.classify(formatID: "320mp3", codec: "mp3", ext: "mp3", bitrate: 320, sampleRate: nil), .high)
        XCTAssertEqual(MusicQualityTier.classify(formatID: "96aac", codec: "aac", ext: "m4a", bitrate: 96, sampleRate: nil), .low)
        XCTAssertEqual(MusicQualityTier.classify(formatID: "x", codec: "flac", ext: "flac", bitrate: nil, sampleRate: 96_000), .hires)
        XCTAssertEqual(MusicQualityTier.classify(formatID: "jymaster", codec: "flac", ext: "flac", bitrate: nil, sampleRate: nil), .hires)
        XCTAssertTrue(MusicQualityTier.lossless > .high)
    }

    func testPreferencesPickExpectedTierOrNone() {
        let free: [MusicQualityTier] = [.standard, .higher, .high]
        let vip: [MusicQualityTier] = [.standard, .high, .lossless, .hires]
        XCTAssertEqual(MusicQualityPreference.best.expectedTier(from: vip), .hires)
        XCTAssertEqual(MusicQualityPreference.losslessOnly.expectedTier(from: vip), .hires)
        XCTAssertNil(MusicQualityPreference.losslessOnly.expectedTier(from: free), "no lossless → skip, never fake it")
        XCTAssertEqual(MusicQualityPreference.upTo320.expectedTier(from: vip), .high)
        XCTAssertTrue(MusicQualityPreference.upTo320.formatSelector.contains("[acodec!=flac]"))
    }

    func testLayoutsBuildSafeTemplates() {
        XCTAssertTrue(MusicLayout.artistAlbum.outputTemplate(collection: nil).hasPrefix("%(creators.0,artists.0,artist"))
        XCTAssertEqual(MusicLayout.artistAlbum.outputTemplate(collection: nil).split(separator: "/").count, 4)
        let context = CollectionContext(collectionID: "1", collectionTitle: "100% 热歌", extractor: "NetEaseMusicPlaylist",
                                        rootFolderName: "100% 热歌", index: 3, chapterNumber: nil, chapterTitle: nil)
        let template = MusicLayout.collection.outputTemplate(collection: context)
        XCTAssertTrue(template.hasPrefix("100%% 热歌/003 - "), template)
    }

    func testMusicJobArgumentsUsePreferenceTagsAndNoVideoOptions() {
        var job = DownloadJob(sourceURL: "https://music.163.com/song?id=1", profile: .audioOnly,
                              destination: URL(fileURLWithPath: "/tmp/m"), includeSidecars: false, includeSubtitles: false,
                              browserCookieSource: nil)
        job.musicQuality = .losslessOnly
        job.musicLayout = .flat
        let args = YtDLPArgumentBuilder.downloadArguments(job: job, destination: URL(fileURLWithPath: "/tmp/m"), ffmpegPath: "/x/ffmpeg",
                                                          state: EngineAttemptState(), sessionRateLimitCount: 0, cookieArguments: [])
        XCTAssertEqual(args[args.firstIndex(of: "--format")! + 1], MusicQualityPreference.losslessOnly.formatSelector)
        for flag in ["--embed-metadata", "--embed-thumbnail", "--write-thumbnail", "--write-subs"] { XCTAssertTrue(args.contains(flag), flag) }
        XCTAssertEqual(args[args.firstIndex(of: "--sub-langs")! + 1], "lyrics,lrc")
        XCTAssertFalse(args.contains("--merge-output-format"))
        XCTAssertEqual(args[args.lastIndex(of: "--socket-timeout")! + 1], "15", "music uses the shorter timeout")
        XCTAssertTrue(args[args.firstIndex(of: "--output")! + 1].contains(" - %(title).120B [%(id)s]"))
    }

    func testShareTextRoutesToMusicPage() {
        let items = InputClassifier.classify("分享周杰伦的单曲《晴天》https://y.qq.com/n/ryqq/songDetail/0039MnYb0qxYhV（来自@QQ音乐）")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.destination, .music)
        XCTAssertEqual(InputClassifier.classify("http://163cn.tv/abc").first?.destination, .music)
        XCTAssertEqual(InputClassifier.classify("https://www.youtube.com/watch?v=x").first?.destination, .video)
        XCTAssertEqual(InputClassifier.primaryDestination(of: items), .music)
    }

    func testAudioQualityReportMeasuresRealFileNotLabel() throws {
        // ffprobe shapes captured from a 320k NetEase MP3 (with cover stream) and a 96 kHz / 24-bit FLAC.
        let mp3 = Data(#"{"streams":[{"codec_type":"audio","codec_name":"mp3","sample_rate":"44100","bits_per_sample":0,"bit_rate":"320000","channels":2},{"codec_type":"video","codec_name":"mjpeg"}],"format":{"duration":"166.4","bit_rate":"346374"}}"#.utf8)
        let report = try XCTUnwrap(AudioQualityReport.parse(ffprobeJSON: mp3, expectedTier: .high))
        XCTAssertEqual(report.tier, .high)
        XCTAssertTrue(report.meetsExpectation)
        XCTAssertEqual(report.summary, "MP3 · 44.1 kHz · 320 kbps")

        let flac = Data(#"{"streams":[{"codec_type":"audio","codec_name":"flac","sample_rate":"96000","bits_per_raw_sample":"24"}],"format":{"duration":"1.0"}}"#.utf8)
        let hires = try XCTUnwrap(AudioQualityReport.parse(ffprobeJSON: flac, expectedTier: .lossless))
        XCTAssertEqual(hires.tier, .hires)
        XCTAssertEqual(hires.summary, "FLAC · 96.0 kHz · 24-bit")

        // Platform said lossless, file is a 128k MP3: flagged.
        let fake = Data(#"{"streams":[{"codec_type":"audio","codec_name":"mp3","sample_rate":"44100","bit_rate":"128000"}],"format":{}}"#.utf8)
        XCTAssertFalse(try XCTUnwrap(AudioQualityReport.parse(ffprobeJSON: fake, expectedTier: .lossless)).meetsExpectation)
    }
}
