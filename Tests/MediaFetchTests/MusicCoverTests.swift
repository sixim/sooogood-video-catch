import XCTest
@testable import MediaFetchCore
@testable import MediaFetchVideo

final class MusicCoverTests: XCTestCase {
    private let audio = URL(fileURLWithPath: "/m/歌手/专辑/歌手 - 歌 [1]/歌手 - 歌 [1].flac")

    func testSidecarMatchesSameBaseNameImageOnly() {
        let dir = audio.deletingLastPathComponent()
        let files = ["歌手 - 歌 [1].lyrics.lrc", "manifest.json", "other.jpg", "歌手 - 歌 [1].jpg"].map { dir.appendingPathComponent($0) }
        XCTAssertEqual(MusicCover.sidecar(for: audio, in: files)?.lastPathComponent, "歌手 - 歌 [1].jpg")
        XCTAssertNil(MusicCover.sidecar(for: audio, in: Array(files.prefix(3))))
    }

    func testAttachedPictureDetection() {
        let with = #"{"streams":[{"codec_type":"audio"},{"codec_type":"video","disposition":{"attached_pic":1}}]}"#
        let without = #"{"streams":[{"codec_type":"audio","disposition":{"attached_pic":0}}]}"#
        XCTAssertTrue(MusicCover.hasAttachedPicture(ffprobeJSON: Data(with.utf8)))
        XCTAssertFalse(MusicCover.hasAttachedPicture(ffprobeJSON: Data(without.utf8)))
        XCTAssertFalse(MusicCover.hasAttachedPicture(ffprobeJSON: Data("oops".utf8)))
    }

    func testEmbedArgumentsPerContainer() throws {
        let image = URL(fileURLWithPath: "/m/c.jpg"), out = URL(fileURLWithPath: "/m/.t.mp3")
        let mp3 = try XCTUnwrap(MusicCover.embedArguments(audio: URL(fileURLWithPath: "/m/a.mp3"), image: image, output: out))
        XCTAssertTrue(mp3.contains("attached_pic") && mp3.contains("-id3v2_version"))
        XCTAssertEqual(mp3.last, out.path)
        XCTAssertFalse(try XCTUnwrap(MusicCover.embedArguments(audio: audio, image: image, output: out)).contains("-id3v2_version"))
        XCTAssertNil(MusicCover.embedArguments(audio: URL(fileURLWithPath: "/m/a.opus"), image: image, output: out))
    }

    func testCoverOnlyEngineArguments() {
        let weird = URL(fileURLWithPath: "/m/x/100% 纯音乐 [2].mp3")
        XCTAssertEqual(MusicCover.thumbnailTemplate(for: weird), "100%% 纯音乐 [2].%(ext)s")
        let args = YtDLPArgumentBuilder.coverArguments(url: "https://music.163.com/song?id=2", audio: weird,
                                                       ffmpegPath: "/x/ffmpeg", cookieArguments: ["--cookies-from-browser", "chrome"])
        XCTAssertTrue(args.contains("--skip-download") && args.contains("--write-thumbnail"))
        XCTAssertEqual(args[args.firstIndex(of: "--paths")! + 1], "/m/x")
        XCTAssertEqual(args[args.firstIndex(of: "--output")! + 1], "thumbnail:100%% 纯音乐 [2].%(ext)s")
        XCTAssertTrue(args.contains("chrome"))
        XCTAssertEqual(args.last, "https://music.163.com/song?id=2")
    }

    /// Real ffmpeg: a cover is embedded into FLAC and MP3 without touching the audio.
    func testEmbedCoverKeepsAudioBitExact() throws {
        let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"), ffprobe = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else { throw XCTSkip("ffmpeg not installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = ProcessInfo.processInfo.environment
        let image = dir.appendingPathComponent("c.jpg")
        XCTAssertEqual(ProcessRunner.run(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "color=red:s=64x64", "-frames:v", "1", image.path], environment: env).status, 0)
        for (ext, codec) in [("flac", "flac"), ("mp3", "libmp3lame")] {
            let track = dir.appendingPathComponent("t.\(ext)")
            XCTAssertEqual(ProcessRunner.run(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "sine=d=1", "-c:a", codec, track.path], environment: env).status, 0)
            let before = ProcessRunner.run(ffmpeg, ["-v", "error", "-i", track.path, "-map", "0:a", "-c", "copy", "-f", "md5", "-"], environment: env).stdout
            XCTAssertFalse(MusicTagger.hasEmbeddedCover(track, ffprobe: ffprobe, environment: env))
            XCTAssertTrue(MusicTagger.embedCover(audio: track, image: image, ffmpeg: ffmpeg, environment: env), ext)
            XCTAssertTrue(MusicTagger.hasEmbeddedCover(track, ffprobe: ffprobe, environment: env), ext)
            let after = ProcessRunner.run(ffmpeg, ["-v", "error", "-i", track.path, "-map", "0:a", "-c", "copy", "-f", "md5", "-"], environment: env).stdout
            XCTAssertEqual(before, after, "\(ext) audio must be untouched")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".") }, [], "no temp files left")
    }
}
