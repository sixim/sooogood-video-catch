import XCTest
@testable import MediaFetchCore

final class LyricsTaggingTests: XCTestCase {
    func testLRCToPlainTextDropsTimestampsAndHeaders() {
        let lrc = "[ti:晴天]\n[ar:周杰伦]\n[00:00.00] 作词 : 周杰伦\n[00:12.34][01:02.03]故事的小黄花\n\n\n[00:20.5]从出生那年就飘着\n"
        XCTAssertEqual(LRCText.plainText(lrc), "作词 : 周杰伦\n故事的小黄花\n\n从出生那年就飘着")
    }

    /// Minimal ID3v2.3 tag + fake MPEG frame bytes.
    private func mp3(withFrames frames: [(String, [UInt8])], major: UInt8 = 3, padding: Int = 16) -> Data {
        var body: [UInt8] = []
        for (id, content) in frames {
            body += Array(id.utf8)
            body += major == 4 ? ID3LyricsWriter.encodeSyncsafe(content.count) : ID3LyricsWriter.encodeBigEndian(content.count)
            body += [0, 0] + content
        }
        body += Array(repeating: 0, count: padding)
        let header: [UInt8] = [0x49, 0x44, 0x33, major, 0, 0] + ID3LyricsWriter.encodeSyncsafe(body.count)
        return Data(header + body + [0xFF, 0xFB, 0x90, 0x64, 1, 2, 3])
    }

    private func frames(in data: Data) -> [(String, Int)] {
        let b = [UInt8](data)
        let major = b[3]
        let end = 10 + ID3LyricsWriter.syncsafe(b[6...9])
        var out: [(String, Int)] = []
        var i = 10
        while i + 10 <= end, b[i] != 0 {
            let size = major == 4 ? ID3LyricsWriter.syncsafe(b[i + 4...i + 7]) : ID3LyricsWriter.bigEndian(b[i + 4...i + 7])
            out.append((String(decoding: b[i..<i + 4], as: UTF8.self), size))
            i += 10 + size
        }
        return out
    }

    func testUSLTIsAddedOnceAndAudioBytesUntouched() throws {
        let original = mp3(withFrames: [("TIT2", [0x03] + Array("晴天".utf8)), ("USLT", [0x00, 0x65, 0x6E, 0x67, 0x00, 0x6F, 0x6C, 0x64])])
        let tagged = try ID3LyricsWriter.embed(lyrics: "故事的小黄花", into: original)
        XCTAssertEqual(frames(in: tagged).map(\.0), ["TIT2", "USLT"], "old USLT replaced, not duplicated")
        XCTAssertEqual(Array(tagged.suffix(7)), [0xFF, 0xFB, 0x90, 0x64, 1, 2, 3], "audio after the tag is untouched")
        let again = try ID3LyricsWriter.embed(lyrics: "第二次", into: tagged)
        XCTAssertEqual(frames(in: again).filter { $0.0 == "USLT" }.count, 1)
        // v2.4 uses syncsafe frame sizes.
        let v24 = try ID3LyricsWriter.embed(lyrics: "x", into: mp3(withFrames: [("TIT2", [3, 0x41])], major: 4))
        XCTAssertEqual(frames(in: v24).map(\.0), ["TIT2", "USLT"])
        XCTAssertThrowsError(try ID3LyricsWriter.embed(lyrics: "x", into: Data([0xFF, 0xFB, 0x90])))
    }

    func testRealPlayerReadableLyricsWithFFprobe() throws {
        let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"), ffprobe = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else { throw XCTSkip("ffmpeg missing") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mf-lyr-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.mp3")
        let make = Process()
        make.executableURL = ffmpeg
        make.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=duration=1", "-c:a", "libmp3lame",
                          "-id3v2_version", "3", "-metadata", "title=晴天", file.path]
        try make.run(); make.waitUntilExit()
        let tagged = try ID3LyricsWriter.embed(lyrics: "故事的小黄花\n从出生那年就飘着", into: Data(contentsOf: file))
        try tagged.write(to: file)
        let probe = Process()
        let pipe = Pipe()
        probe.executableURL = ffprobe
        probe.arguments = ["-v", "error", "-show_entries", "format_tags", "-of", "json", file.path]
        probe.standardOutput = pipe
        try probe.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        let tags = try JSONDecoder().decode(JSONValue.self, from: output)["format"]?["tags"]?.objectValue ?? [:]
        XCTAssertEqual(tags["title"]?.stringValue, "晴天", "existing tags survive")
        XCTAssertTrue(tags.contains { $0.key.lowercased().hasPrefix("lyrics") && ($0.value.stringValue ?? "").contains("故事的小黄花") }, "\(tags)")
    }

    func testCustomTemplateIsSafeAndKeepsID() {
        let template = MusicNameTemplate("{artist}/../{album}/ 100% {title} ")
        let yt = template.ytDLPTemplate(collection: nil)
        XCTAssertFalse(yt.contains("/../"))
        XCTAssertTrue(yt.contains("100%% %(title).120B [%(id)s]"), yt)
        XCTAssertTrue(yt.hasSuffix(".%(ext)s"))
        XCTAssertEqual(MusicNameTemplate("{artist} - {title} [{id}]").preview(), "周杰伦 - 晴天 [0039MnYb0qxYhV]/周杰伦 - 晴天 [0039MnYb0qxYhV].flac")
        XCTAssertEqual(MusicNameTemplate("").ytDLPTemplate(collection: nil).split(separator: "/").count, 4, "empty falls back to default")
        let context = CollectionContext(collectionID: "1", collectionTitle: "t", extractor: "x", rootFolderName: "t", index: 7, chapterNumber: nil, chapterTitle: nil)
        XCTAssertTrue(MusicNameTemplate("{index} {title}").ytDLPTemplate(collection: context).hasPrefix("007 %(title)"))
    }
}
