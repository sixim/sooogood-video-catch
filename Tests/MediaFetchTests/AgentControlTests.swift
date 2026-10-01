#if !MEDIAFETCH_STORE_PROFILE
import XCTest
@testable import MediaFetch
@testable import MediaFetchControl
@testable import MediaFetchCore

private struct EchoHandler: ControlHandler {
    func handle(tool: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        switch tool {
        case "list_tasks": return ["tasks": [["id": "1", "kind": "video"]]]
        case "get_task": throw ControlError.notFound("没有找到任务 \(arguments["id"]?.stringValue ?? "")")
        default: return ["tool": .string(tool), "arguments": .object(arguments)]
        }
    }
}

final class AgentControlTests: XCTestCase {
    private func decode(_ line: String?) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(XCTUnwrap(line).utf8))
    }

    // MARK: MCP session

    func testInitializeNegotiatesVersionAndAdvertisesTools() throws {
        let session = MCPSession(version: "9.9") { _, _ in .null }
        let initReply = try decode(session.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{}}}"#))
        XCTAssertEqual(initReply["result"]?["protocolVersion"]?.stringValue, "2025-03-26")
        XCTAssertEqual(initReply["result"]?["serverInfo"]?["version"]?.stringValue, "9.9")
        XCTAssertNotNil(initReply["result"]?["capabilities"]?["tools"])
        let unknownVersion = try decode(session.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        XCTAssertEqual(unknownVersion["result"]?["protocolVersion"]?.stringValue, MCPSession.supportedVersions[0])

        XCTAssertNil(session.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#), "notifications get no reply")

        let list = try decode(session.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#))
        let tools = try XCTUnwrap(list["result"]?["tools"]?.arrayValue)
        XCTAssertEqual(tools.count, ControlTool.all.count)
        for tool in tools {
            XCTAssertEqual(tool["inputSchema"]?["type"]?.stringValue, "object")
            XCTAssertFalse(tool["description"]?.stringValue?.isEmpty ?? true)
        }
        let ping = try decode(session.handle(line: #"{"jsonrpc":"2.0","id":"p","method":"ping"}"#))
        XCTAssertEqual(ping["id"]?.stringValue, "p")
        XCTAssertNotNil(ping["result"])
    }

    func testMusicToolsAreAdvertised() {
        XCTAssertNotNil(ControlTool.named("analyze_music"))
        XCTAssertEqual(ControlTool.named("enqueue_music")?.inputSchema["properties"]?["quality"]?["enum"],
                       ["best", "losslessOnly", "upTo320"])
    }

    func testNoToolCanDeleteAnything() {
        for tool in ControlTool.all {
            XCTAssertFalse(["delete", "remove", "trash", "erase"].contains { tool.name.contains($0) }, tool.name)
        }
    }

    func testToolCallResultsAndErrors() throws {
        let session = MCPSession { tool, arguments in
            if tool == "get_task" { throw ControlError.notFound("没有找到任务 x") }
            return ["echo": .string(tool), "n": .number(Double(arguments.count))]
        }
        let ok = try decode(session.handle(line: #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_tasks","arguments":{"kind":"video"}}}"#))
        XCTAssertEqual(ok["result"]?["isError"]?.boolValue, false)
        XCTAssertEqual(ok["result"]?["structuredContent"]?["echo"]?.stringValue, "list_tasks")
        XCTAssertTrue(ok["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("list_tasks") == true)

        let failed = try decode(session.handle(line: #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_task","arguments":{"id":"x"}}}"#))
        XCTAssertEqual(failed["result"]?["isError"]?.boolValue, true, "tool failures are results, not protocol errors")

        let unknown = try decode(session.handle(line: #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"rm_rf"}}"#))
        XCTAssertEqual(unknown["error"]?["code"]?.intValue, -32602)
        let parse = try decode(session.handle(line: "{nope"))
        XCTAssertEqual(parse["error"]?["code"]?.intValue, -32700)
        let missing = try decode(session.handle(line: #"{"jsonrpc":"2.0","id":8,"method":"resources/list"}"#))
        XCTAssertEqual(missing["error"]?["code"]?.intValue, -32601)
    }

    // MARK: Socket

    private func socketURL() -> URL {
        URL(fileURLWithPath: "/tmp/mf-\(UUID().uuidString.prefix(8)).sock")
    }

    func testSocketRoundTripIsPrivateAndCarriesErrors() throws {
        let url = socketURL()
        let server = ControlServer(socketURL: url, handler: EchoHandler())
        try server.start()
        defer { server.stop() }
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let client = try ControlClient(socketURL: url)
        let result = try client.call("list_tasks")
        XCTAssertEqual(result["tasks"]?.arrayValue?.count, 1)
        let echoed = try client.call("analyze_url", ["url": "https://a.b/中文"])
        XCTAssertEqual(echoed["arguments"]?["url"]?.stringValue, "https://a.b/中文")
        XCTAssertThrowsError(try client.call("get_task", ["id": "zz"])) { error in
            XCTAssertEqual((error as? ControlError)?.code, -32004)
        }
    }

    func testClientFailsCleanlyWhenAppIsNotRunning() {
        XCTAssertThrowsError(try ControlClient(socketURL: socketURL()))
    }

    // MARK: Path policy

    func testAgentPathsOnlyAllowDownloadsMoviesAndChosenFolders() throws {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        XCTAssertTrue(AgentPaths.isAllowed(downloads.appendingPathComponent("a/b.mp4")))
        XCTAssertFalse(AgentPaths.isAllowed(URL(fileURLWithPath: "/etc/hosts")))
        XCTAssertFalse(AgentPaths.isAllowed(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Keychains")))
        XCTAssertFalse(AgentPaths.isAllowed(downloads.appendingPathComponent("../Library")), ".. cannot escape a root")
        XCTAssertFalse(AgentPaths.isAllowed(URL(fileURLWithPath: downloads.path + "-evil/x")), "prefix lookalikes are refused")
        XCTAssertThrowsError(try AgentPaths.validatedFile("/etc/hosts"))
    }

    func testArgumentsValidateTypesAndProfiles() throws {
        let args = Arguments(["urls": ["notaurl", "https://youtu.be/x"], "profile": "mp4", "n": 3])
        XCTAssertEqual(try args.urls("urls").map(\.absoluteString), ["https://youtu.be/x"])
        XCTAssertEqual(try args.profile(), .compatibleMP4)
        XCTAssertThrowsError(try Arguments(["profile": "8k"]).profile())
        XCTAssertThrowsError(try Arguments([:]).string("id"))
        XCTAssertThrowsError(try Arguments(["urls": []]).urls("urls"))
    }

    // MARK: The real helper binary over stdio

    func testBuiltHelperSpeaksMCPOverStdioAndForwardsToApp() throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let helper = products.appendingPathComponent("sooogood-mcp")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw XCTSkip("helper not built at \(helper.path)") }
        let url = socketURL()
        let server = ControlServer(socketURL: url, handler: EchoHandler())
        try server.start()
        defer { server.stop() }

        let process = Process()
        process.executableURL = helper
        process.environment = ["MF_CONTROL_SOCKET": url.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_tasks","arguments":{}}}"#
        ]
        input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let replies = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        XCTAssertEqual(replies.count, 3, String(decoding: data, as: UTF8.self))
        XCTAssertEqual(try decode(replies[0])["result"]?["serverInfo"]?["name"]?.stringValue, MCPSession.serverName)
        XCTAssertEqual(try decode(replies[1])["result"]?["tools"]?.arrayValue?.count, ControlTool.all.count)
        let call = try decode(replies[2])
        XCTAssertEqual(call["id"]?.intValue, 3)
        XCTAssertEqual(call["result"]?["structuredContent"]?["tasks"]?.arrayValue?.count, 1)
    }
}
#endif
