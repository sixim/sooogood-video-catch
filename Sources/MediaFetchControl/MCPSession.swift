import Foundation
import MediaFetchCore

#if !MEDIAFETCH_STORE_PROFILE
/// Model Context Protocol over stdio (newline-delimited JSON-RPC 2.0).
/// Implements the subset a tool server needs: initialize, ping, tools/list,
/// tools/call. Tool calls are forwarded to the running app.
public final class MCPSession: @unchecked Sendable {
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public static let serverName = "sooogood-media-catch"

    private let forward: (String, [String: JSONValue]) throws -> JSONValue
    private let version: String

    /// - Parameter forward: executes a tool in the app; throws `ControlError`.
    public init(version: String = MediaFetchRelease.version,
                forward: @escaping (String, [String: JSONValue]) throws -> JSONValue) {
        self.version = version
        self.forward = forward
    }

    /// Handles one incoming line; returns the line to write back, if any.
    public func handle(line: String) -> String? {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else {
            return encode(["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let method = message["method"]?.stringValue else { return nil } // a response or junk: ignore
        let id = message["id"]
        let params = message["params"]?.objectValue ?? [:]
        guard let id else { return nil } // notifications (e.g. notifications/initialized) get no reply

        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? Self.supportedVersions[0]
            let negotiated = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            return reply(id, [
                "protocolVersion": .string(negotiated),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(Self.serverName), "title": "Sooogood Media Catch", "version": .string(version)],
                "instructions": "Downloads media into auditable packages (manifest.json + SHA-256), manages torrents, runs creator tools (proxies, transcripts) and sends packages to DaVinci Resolve. There are no delete tools; ask the user before downloading anything they may not have rights to."
            ])
        case "ping":
            return reply(id, [:])
        case "tools/list":
            return reply(id, ["tools": .array(ControlTool.all.map { tool in
                ["name": .string(tool.name), "description": .string(tool.description), "inputSchema": tool.inputSchema]
            })])
        case "tools/call":
            guard let name = params["name"]?.stringValue, ControlTool.named(name) != nil else {
                return error(id, code: -32602, message: "Unknown tool: \(params["name"]?.stringValue ?? "")")
            }
            let arguments = params["arguments"]?.objectValue ?? [:]
            do {
                let result = try forward(name, arguments)
                return reply(id, [
                    "content": [["type": "text", "text": .string(prettyText(result))]],
                    "structuredContent": result.objectValue != nil ? result : ["value": result],
                    "isError": false
                ])
            } catch {
                // Tool failures are results the model should read, not protocol errors.
                return reply(id, [
                    "content": [["type": "text", "text": .string(error.localizedDescription)]],
                    "isError": true
                ])
            }
        default:
            return error(id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func reply(_ id: JSONValue, _ result: JSONValue) -> String? {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func error(_ id: JSONValue, code: Int, message: String) -> String? {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]])
    }

    private func encode(_ value: JSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    private func prettyText(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}

/// Connects to the app, launching it in the background when it is not running.
public enum AppConnector {
    public static func connect(socketURL: URL = ControlPaths.socket, bundleID: String = MediaFetchRelease.bundleIdentifier,
                               launchTimeout: TimeInterval = 20) throws -> ControlClient {
        if let client = try? ControlClient(socketURL: socketURL) { return client }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-b", bundleID]
        try? open.run()
        open.waitUntilExit()
        let deadline = Date().addingTimeInterval(launchTimeout)
        while Date() < deadline {
            if let client = try? ControlClient(socketURL: socketURL) { return client }
            Thread.sleep(forTimeInterval: 0.3)
        }
        throw ControlError.failed(String(localized: "无法连接 Sooogood Media Catch：请确认应用已安装并能正常启动"))
    }
}
#endif
