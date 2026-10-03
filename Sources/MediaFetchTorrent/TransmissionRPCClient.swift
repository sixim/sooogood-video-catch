import Foundation
import MediaFetchCore

// BitTorrent is Local-profile only; nothing here ships in the Store binary.
#if !MEDIAFETCH_STORE_PROFILE
/// Minimal JSON-RPC 2.0 client for Transmission ≥ 4.1 (snake_case methods).
/// Handles the `409 + X-Transmission-Session-Id` CSRF handshake and HTTP Basic
/// auth. Talks only to a loopback endpoint owned by this app.
public actor TransmissionRPCClient {
    public struct Endpoint: Sendable, Equatable {
        public let url: URL
        public let username: String
        public let password: String

        public init(port: Int, username: String, password: String) {
            url = URL(string: "http://127.0.0.1:\(port)/transmission/rpc")!
            self.username = username
            self.password = password
        }
    }

    private let endpoint: Endpoint
    private let session: URLSession
    private var sessionID: String?
    private var nextID = 1

    nonisolated var endpointForTesting: Endpoint { endpoint }

    public init(endpoint: Endpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    @discardableResult
    public func call(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let body = try JSONEncoder().encode(JSONValue.object([
            "jsonrpc": "2.0", "method": .string(method), "params": .object(params), "id": .number(Double(id))
        ]))
        for _ in 0..<2 {
            var request = URLRequest(url: endpoint.url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let credentials = Data("\(endpoint.username):\(endpoint.password)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "X-Transmission-Session-Id") }

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw TorrentError.http(0) }
            switch http.statusCode {
            case 409:
                sessionID = http.value(forHTTPHeaderField: "X-Transmission-Session-Id")
                continue
            case 401:
                throw TorrentError.unauthorized
            case 200:
                let reply = try JSONDecoder().decode(JSONValue.self, from: data)
                if let error = reply["error"] {
                    let detail = error["data"]?["error_string"]?.stringValue
                    throw TorrentError.rpc(
                        code: error["code"]?.intValue ?? -1,
                        message: detail ?? error["message"]?.stringValue ?? "unknown"
                    )
                }
                return reply["result"] ?? .null
            case 204:
                return .null
            default:
                throw TorrentError.http(http.statusCode)
            }
        }
        throw TorrentError.http(409)
    }

    // MARK: Typed helpers

    public func version() async throws -> String {
        try await call("session_get", ["fields": ["version"]])["version"]?.stringValue ?? "unknown"
    }

    public struct AddResult: Sendable, Equatable {
        public let engineID: Int
        public let hash: String
        public let name: String
        public let duplicate: Bool
    }

    public func add(
        _ source: TorrentSource,
        downloadDirectory: String,
        paused: Bool,
        sequential: Bool
    ) async throws -> AddResult {
        var params: [String: JSONValue] = [
            "download_dir": .string(downloadDirectory),
            "paused": .bool(paused),
            "sequential_download": .bool(sequential)
        ]
        switch source {
        case .magnet(let link): params["filename"] = .string(link)
        case .metainfo(_, let data): params["metainfo"] = .string(data.base64EncodedString())
        }
        let result = try await call("torrent_add", params)
        let duplicate = result["torrent_duplicate"] != nil
        guard let torrent = result["torrent_added"] ?? result["torrent_duplicate"],
              let id = torrent["id"]?.intValue,
              let hash = torrent["hash_string"]?.stringValue else {
            throw TorrentError.rpc(code: -1, message: String(localized: "torrent_add 没有返回种子信息"))
        }
        return AddResult(engineID: id, hash: hash.lowercased(),
                         name: torrent["name"]?.stringValue ?? hash, duplicate: duplicate)
    }

    public func torrents(hashes: [String]? = nil) async throws -> [TorrentSnapshot] {
        var params: [String: JSONValue] = ["fields": .array(TorrentSnapshot.fields)]
        if let hashes { params["ids"] = .array(hashes.map(JSONValue.string)) }
        let result = try await call("torrent_get", params)
        return (result["torrents"]?.arrayValue ?? []).compactMap(TorrentSnapshot.init(json:))
    }

    public func set(_ hash: String, _ arguments: [String: JSONValue]) async throws {
        var params = arguments
        params["ids"] = [.string(hash)]
        try await call("torrent_set", params)
    }

    public func start(_ hash: String) async throws { try await call("torrent_start", ["ids": [.string(hash)]]) }
    public func stop(_ hash: String) async throws { try await call("torrent_stop", ["ids": [.string(hash)]]) }

    /// Removes the torrent from the engine only. Downloaded data is never
    /// deleted from here; that is always the user's decision in Finder.
    public func removeKeepingData(_ hash: String) async throws {
        try await call("torrent_remove", ["ids": [.string(hash)], "delete_local_data": false])
    }

    public func setSession(_ arguments: [String: JSONValue]) async throws {
        try await call("session_set", arguments)
    }
}
#endif
