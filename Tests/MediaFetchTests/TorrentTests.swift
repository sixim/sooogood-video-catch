#if !MEDIAFETCH_STORE_PROFILE
import XCTest
@testable import MediaFetchCore
@testable import MediaFetchTorrent

/// Scripted HTTP responses for the RPC client; never touches the network.
final class StubRPCProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            request.httpBody = data
        }
        Self.requests.append(request)
        let (status, headers, body) = Self.handler?(request) ?? (500, [:], Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class TorrentTests: XCTestCase {
    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubRPCProtocol.self]
        return URLSession(configuration: configuration)
    }

    override func setUp() {
        StubRPCProtocol.requests = []
        StubRPCProtocol.handler = nil
    }

    // MARK: Input validation

    func testMagnetValidationAcceptsV1HexBase32AndV2() {
        XCTAssertNotNil(TorrentSource.magnet(from: "magnet:?xt=urn:btih:\(String(repeating: "a", count: 40))&dn=Ubuntu"))
        XCTAssertNotNil(TorrentSource.magnet(from: "  magnet:?xt=urn:btih:\(String(repeating: "B", count: 32)) "))
        XCTAssertNotNil(TorrentSource.magnet(from: "magnet:?xt=urn:btmh:1220\(String(repeating: "c", count: 64))"))
        XCTAssertNil(TorrentSource.magnet(from: "magnet:?xt=urn:btih:tooShort"))
        XCTAssertNil(TorrentSource.magnet(from: "https://example.com/file.torrent"))
        XCTAssertNil(TorrentSource.magnet(from: "magnet:?dn=only-a-name"))
        XCTAssertEqual(TorrentSource.magnet(from: "magnet:?xt=urn:btih:\(String(repeating: "a", count: 40))&dn=Ubuntu")?.displayHint, "Ubuntu")
    }

    func testTorrentFileMustBeBencodedDictionary() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".torrent")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("<html>".utf8).write(to: url)
        XCTAssertThrowsError(try TorrentSource.metainfo(fileAt: url))
        try Data("d4:infod4:name1:xee".utf8).write(to: url)
        XCTAssertNoThrow(try TorrentSource.metainfo(fileAt: url))
    }

    // MARK: RPC client

    func testClientPerformsSessionHandshakeAndSendsBasicAuth() async throws {
        StubRPCProtocol.handler = { request in
            if request.value(forHTTPHeaderField: "X-Transmission-Session-Id") != "abc" {
                return (409, ["X-Transmission-Session-Id": "abc"], Data())
            }
            return (200, [:], Data(#"{"jsonrpc":"2.0","result":{"version":"4.1.3 (x)"},"id":1}"#.utf8))
        }
        let client = TransmissionRPCClient(endpoint: .init(port: 9999, username: "u", password: "p"), session: stubSession())
        let version = try await client.version()
        XCTAssertEqual(version, "4.1.3 (x)")
        XCTAssertEqual(StubRPCProtocol.requests.count, 2)
        let auth = StubRPCProtocol.requests.last?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(auth, "Basic " + Data("u:p".utf8).base64EncodedString())
        XCTAssertEqual(StubRPCProtocol.requests.last?.url?.host, "127.0.0.1")
        let body = try JSONDecoder().decode(JSONValue.self, from: StubRPCProtocol.requests.last!.httpBody!)
        XCTAssertEqual(body["method"]?.stringValue, "session_get")
        XCTAssertEqual(body["jsonrpc"]?.stringValue, "2.0")
    }

    func testClientMapsRPCErrorsAndAuthFailures() async {
        StubRPCProtocol.handler = { _ in
            (200, [:], Data(#"{"jsonrpc":"2.0","error":{"code":7,"message":"bad","data":{"error_string":"invalid or corrupt torrent file"}},"id":1}"#.utf8))
        }
        let client = TransmissionRPCClient(endpoint: .init(port: 9999, username: "u", password: "p"), session: stubSession())
        do { _ = try await client.version(); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? TorrentError, .rpc(code: 7, message: "invalid or corrupt torrent file")) }

        StubRPCProtocol.handler = { _ in (401, [:], Data()) }
        do { _ = try await client.version(); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? TorrentError, .unauthorized) }
    }

    func testAddSendsMagnetOrMetainfoAndRecognisesDuplicates() async throws {
        StubRPCProtocol.handler = { _ in
            (200, [:], Data(#"{"jsonrpc":"2.0","result":{"torrent_duplicate":{"id":3,"hash_string":"ABCDEF","name":"x"}},"id":1}"#.utf8))
        }
        let client = TransmissionRPCClient(endpoint: .init(port: 1, username: "u", password: "p"), session: stubSession())
        let result = try await client.add(.metainfo(fileName: "a.torrent", data: Data("d4:infoe".utf8)),
                                          downloadDirectory: "/tmp/dl", paused: true, sequential: true)
        XCTAssertEqual(result, .init(engineID: 3, hash: "abcdef", name: "x", duplicate: true))
        let body = try JSONDecoder().decode(JSONValue.self, from: StubRPCProtocol.requests.last!.httpBody!)
        XCTAssertEqual(body["method"]?.stringValue, "torrent_add")
        XCTAssertEqual(body["params"]?["metainfo"]?.stringValue, Data("d4:infoe".utf8).base64EncodedString())
        XCTAssertEqual(body["params"]?["paused"]?.boolValue, true)
        XCTAssertEqual(body["params"]?["sequential_download"]?.boolValue, true)
        XCTAssertNil(body["params"]?["filename"])
    }

    func testRemoveNeverDeletesLocalData() async throws {
        StubRPCProtocol.handler = { _ in (200, [:], Data(#"{"jsonrpc":"2.0","result":{},"id":1}"#.utf8)) }
        let client = TransmissionRPCClient(endpoint: .init(port: 1, username: "u", password: "p"), session: stubSession())
        try await client.removeKeepingData("abc")
        let body = try JSONDecoder().decode(JSONValue.self, from: StubRPCProtocol.requests.last!.httpBody!)
        XCTAssertEqual(body["params"]?["delete_local_data"]?.boolValue, false)
    }

    // MARK: Models

    func testSnapshotParsesFilesAndToleratesMissingFields() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"id":1,"hash_string":"ABC","name":"Show","status":4,"percent_done":0.5,"metadata_percent_complete":1,
         "size_when_done":200,"left_until_done":100,"download_dir":"/dl",
         "files":[{"name":"Show/a.mkv","length":150,"bytes_completed":75},{"name":"Show/b.nfo","length":50,"bytes_completed":0}],
         "file_stats":[{"wanted":true,"priority":1},{"wanted":false,"priority":0}]}
        """.utf8))
        let snapshot = try XCTUnwrap(TorrentSnapshot(json: json))
        XCTAssertEqual(snapshot.hash, "abc")
        XCTAssertEqual(snapshot.state, .downloading)
        XCTAssertEqual(snapshot.files.count, 2)
        XCTAssertEqual(snapshot.files[0].progress, 0.5)
        XCTAssertFalse(snapshot.files[1].wanted)
        XCTAssertFalse(snapshot.isComplete)
        XCTAssertEqual(TorrentManifestWriter.manifestURL(for: snapshot).path, "/dl/Show/torrent-manifest.json")
        XCTAssertNil(TorrentSnapshot(json: ["name": "no id"]))
    }

    func testSeedPolicyMapsToTransmissionModes() {
        XCTAssertEqual(SeedPolicy.ratio(1.5).torrentArguments["seed_ratio_limit"], .number(1.5))
        XCTAssertEqual(SeedPolicy.ratio(1.5).torrentArguments["seed_ratio_mode"], 1)
        XCTAssertEqual(SeedPolicy.idleMinutes(30).torrentArguments["seed_idle_limit"], 30)
        XCTAssertEqual(SeedPolicy.stopWhenDone.torrentArguments["seed_ratio_limit"], 0)
    }

    func testDaemonSettingsAreLoopbackAuthenticatedAndPrivate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mf-tr-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"peer_port":51515,"rpc_bind_address":"0.0.0.0","speed_limit_down":100}"#.utf8)
            .write(to: dir.appendingPathComponent("settings.json"))
        let daemon = TransmissionDaemon(configuration: .init(
            executable: URL(fileURLWithPath: "/usr/bin/true"), configDirectory: dir, downloadDirectory: dir))
        try daemon.writeSettings(port: 12345, username: "u", password: "secret")
        let url = dir.appendingPathComponent("settings.json")
        let settings = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        XCTAssertEqual(settings["rpc_bind_address"]?.stringValue, "127.0.0.1")
        XCTAssertEqual(settings["rpc_authentication_required"]?.boolValue, true)
        XCTAssertEqual(settings["rpc_port"]?.intValue, 12345)
        XCTAssertEqual(settings["peer_port"]?.intValue, 51515, "user peer port is preserved")
        XCTAssertEqual(settings["speed_limit_down"]?.intValue, 100, "unrelated settings are preserved")
        XCTAssertEqual(settings["script_torrent_done_enabled"]?.boolValue, false)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
    }

    func testManifestRejectsPathsEscapingTheDownloadFolder() throws {
        let json: JSONValue = [
            "id": 1, "hash_string": "abc", "name": "x", "metadata_percent_complete": 1, "download_dir": "/tmp",
            "files": [["name": "../../etc/passwd", "length": 1, "bytes_completed": 1]],
            "file_stats": [["wanted": true]]
        ]
        let snapshot = try XCTUnwrap(TorrentSnapshot(json: json))
        let record = TorrentRecord(hash: "abc", name: "x", downloadDirectory: "/tmp", magnetLink: nil,
                                   seedPolicy: .default, awaitingFileSelection: false)
        XCTAssertThrowsError(try TorrentManifestWriter.write(snapshot: snapshot, record: record, engineVersion: "t"))
    }

    // MARK: Real engine, fully offline

    @MainActor
    func testRealDaemonVerifiesLocalTorrentAndWritesManifest() async throws {
        guard let daemonURL = TransmissionDaemon.findExecutable() else {
            throw XCTSkip("transmission-daemon not installed")
        }
        let create = daemonURL.deletingLastPathComponent().appendingPathComponent("transmission-create")
        guard FileManager.default.isExecutableFile(atPath: create.path) else { throw XCTSkip("transmission-create missing") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mf-real-" + UUID().uuidString)
        let downloads = root.appendingPathComponent("downloads")
        let payloadDir = downloads.appendingPathComponent("Sample Pack")
        try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try payload.write(to: payloadDir.appendingPathComponent("clip.bin"))
        try Data("notes".utf8).write(to: payloadDir.appendingPathComponent("notes.txt"))

        // Private torrent (-p) with an unreachable loopback tracker: no DHT/PEX, no network.
        let torrentFile = root.appendingPathComponent("sample.torrent")
        let maker = Process()
        maker.executableURL = create
        maker.arguments = ["-p", "-t", "http://127.0.0.1:9/announce", "-o", torrentFile.path, payloadDir.path]
        maker.standardOutput = FileHandle.nullDevice
        maker.standardError = FileHandle.nullDevice
        try maker.run()
        maker.waitUntilExit()
        XCTAssertEqual(maker.terminationStatus, 0)

        let configDir = root.appendingPathComponent("engine")
        let service = TorrentService(
            defaultDownloadDirectory: downloads,
            historyURL: root.appendingPathComponent("history.json"),
            daemonFactory: {
                TransmissionDaemon(configuration: .init(executable: daemonURL, configDirectory: configDir,
                                                        downloadDirectory: downloads, portForwarding: false))
            }
        )
        defer { service.shutdown() }
        service.isObserved = true
        let record = try await service.add(try .metainfo(fileAt: torrentFile), seedPolicy: .stopWhenDone, selectFiles: false)
        var manifestPath: String?
        for _ in 0..<150 {
            await service.refresh()
            if let path = service.record(for: record.hash)?.manifestPath { manifestPath = path; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let path = try XCTUnwrap(manifestPath, "torrent never completed; engine: \(service.engineStatus)")
        XCTAssertEqual(path, payloadDir.appendingPathComponent("torrent-manifest.json").path)
        let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(manifest["kind"]?.stringValue, "torrent")
        XCTAssertEqual(manifest["infoHash"]?.stringValue, record.hash)
        let files = try XCTUnwrap(manifest["files"]?.arrayValue)
        XCTAssertEqual(files.count, 2)
        let clip = try XCTUnwrap(files.first { $0["relativePath"]?.stringValue == "Sample Pack/clip.bin" })
        XCTAssertEqual(clip["sha256"]?.stringValue, try ManifestWriter.sha256(payloadDir.appendingPathComponent("clip.bin")))
        // Removing from the list keeps the data on disk.
        await service.removeKeepingFiles(record.hash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: payloadDir.appendingPathComponent("clip.bin").path))
    }
}
#endif
