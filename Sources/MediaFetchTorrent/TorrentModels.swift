import Foundation
import MediaFetchCore

// BitTorrent is Local-profile only; nothing here ships in the Store binary.
#if !MEDIAFETCH_STORE_PROFILE
/// What the user handed us: a magnet link or a local `.torrent` file.
public enum TorrentSource: Equatable, Sendable {
    case magnet(String)
    case metainfo(fileName: String, data: Data)

    /// Accepts `magnet:?xt=urn:btih:<40 hex | 32 base32>` and BitTorrent v2
    /// `urn:btmh:`. Anything else is rejected before it reaches the engine.
    public static func magnet(from input: String) -> TorrentSource? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "magnet",
              let topics = components.queryItems?.filter({ $0.name == "xt" }).compactMap(\.value),
              topics.contains(where: isValidExactTopic) else { return nil }
        return .magnet(trimmed)
    }

    public static func metainfo(fileAt url: URL) throws -> TorrentSource {
        let data = try Data(contentsOf: url)
        guard data.first == UInt8(ascii: "d"), data.count < 50 * 1024 * 1024 else {
            throw TorrentError.invalidTorrentFile
        }
        return .metainfo(fileName: url.lastPathComponent, data: data)
    }

    static func isValidExactTopic(_ topic: String) -> Bool {
        let lowered = topic.lowercased()
        if lowered.hasPrefix("urn:btih:") {
            let hash = String(topic.dropFirst("urn:btih:".count))
            let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
            let base32 = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567abcdefghijklmnopqrstuvwxyz")
            return (hash.count == 40 && hash.unicodeScalars.allSatisfy(hex.contains))
                || (hash.count == 32 && hash.unicodeScalars.allSatisfy(base32.contains))
        }
        if lowered.hasPrefix("urn:btmh:") {
            let hash = String(topic.dropFirst("urn:btmh:".count))
            return hash.count == 68 && hash.lowercased().hasPrefix("1220")
        }
        return false
    }

    /// Short label for UI and history before the engine knows the real name.
    public var displayHint: String {
        switch self {
        case .magnet(let link):
            return URLComponents(string: link)?.queryItems?.first(where: { $0.name == "dn" })?.value ?? "磁力链接"
        case .metainfo(let name, _):
            return name
        }
    }
}

public enum TorrentError: LocalizedError, Equatable {
    case engineMissing
    case engineFailedToStart(String)
    case invalidTorrentFile
    case invalidMagnet
    case rpc(code: Int, message: String)
    case http(Int)
    case unauthorized

    public var errorDescription: String? {
        switch self {
        case .engineMissing: return "未找到 transmission-daemon，请执行 brew install transmission-cli"
        case .engineFailedToStart(let detail): return "Torrent 引擎启动失败：\(detail)"
        case .invalidTorrentFile: return "这不是有效的 .torrent 文件"
        case .invalidMagnet: return "磁力链接格式无效（需要 xt=urn:btih: 或 urn:btmh:）"
        case .rpc(_, let message): return "Torrent 引擎返回错误：\(message)"
        case .http(let code): return "Torrent 引擎连接失败（HTTP \(code)）"
        case .unauthorized: return "Torrent 引擎认证失败，请重启应用"
        }
    }
}

public enum TorrentState: Int, Codable, Sendable {
    case stopped = 0
    case queuedToVerify = 1
    case verifying = 2
    case queuedToDownload = 3
    case downloading = 4
    case queuedToSeed = 5
    case seeding = 6

    public var displayName: String {
        switch self {
        case .stopped: return "已停止"
        case .queuedToVerify, .verifying: return "校验中"
        case .queuedToDownload: return "排队下载"
        case .downloading: return "下载中"
        case .queuedToSeed: return "排队做种"
        case .seeding: return "做种中"
        }
    }
}

public struct TorrentFile: Equatable, Sendable, Identifiable {
    public let index: Int
    public let name: String
    public let length: Int64
    public let bytesCompleted: Int64
    public let wanted: Bool
    public let priority: Int

    public var id: Int { index }
    public var progress: Double { length > 0 ? Double(bytesCompleted) / Double(length) : 0 }
}

/// One torrent as reported by `torrent_get`. Built from `JSONValue` so a new
/// or missing engine field never breaks decoding of the rest.
public struct TorrentSnapshot: Equatable, Sendable, Identifiable {
    public let engineID: Int
    public let hash: String
    public let name: String
    public let state: TorrentState
    public let percentDone: Double
    public let metadataPercentComplete: Double
    public let downloadRate: Int64
    public let uploadRate: Int64
    public let eta: Int
    public let totalSize: Int64
    public let sizeWhenDone: Int64
    public let leftUntilDone: Int64
    public let uploadRatio: Double
    public let errorString: String
    public let downloadDirectory: String
    public let isFinished: Bool
    public let sequential: Bool
    public let peersConnected: Int
    public let files: [TorrentFile]

    public var id: String { hash }
    public var hasMetadata: Bool { metadataPercentComplete >= 1 }
    public var isComplete: Bool { hasMetadata && leftUntilDone == 0 && sizeWhenDone > 0 }

    public static let fields: [JSONValue] = [
        "id", "hash_string", "name", "status", "percent_done", "metadata_percent_complete",
        "rate_download", "rate_upload", "eta", "total_size", "size_when_done", "left_until_done",
        "upload_ratio", "error_string", "download_dir", "is_finished", "sequential_download",
        "peers_connected", "files", "file_stats"
    ]

    public init?(json: JSONValue) {
        guard let id = json["id"]?.intValue, let hash = json["hash_string"]?.stringValue else { return nil }
        engineID = id
        self.hash = hash.lowercased()
        name = json["name"]?.stringValue ?? hash
        state = TorrentState(rawValue: json["status"]?.intValue ?? 0) ?? .stopped
        percentDone = json["percent_done"]?.doubleValue ?? 0
        metadataPercentComplete = json["metadata_percent_complete"]?.doubleValue ?? 0
        downloadRate = Int64(json["rate_download"]?.doubleValue ?? 0)
        uploadRate = Int64(json["rate_upload"]?.doubleValue ?? 0)
        eta = json["eta"]?.intValue ?? -1
        totalSize = Int64(json["total_size"]?.doubleValue ?? 0)
        sizeWhenDone = Int64(json["size_when_done"]?.doubleValue ?? 0)
        leftUntilDone = Int64(json["left_until_done"]?.doubleValue ?? 0)
        uploadRatio = json["upload_ratio"]?.doubleValue ?? 0
        errorString = json["error_string"]?.stringValue ?? ""
        downloadDirectory = json["download_dir"]?.stringValue ?? ""
        isFinished = json["is_finished"]?.boolValue ?? false
        sequential = json["sequential_download"]?.boolValue ?? false
        peersConnected = json["peers_connected"]?.intValue ?? 0
        let rawFiles = json["files"]?.arrayValue ?? []
        let stats = json["file_stats"]?.arrayValue ?? []
        files = rawFiles.enumerated().map { index, file in
            let stat: JSONValue? = index < stats.count ? stats[index] : nil
            return TorrentFile(
                index: index,
                name: file["name"]?.stringValue ?? "",
                length: Int64(file["length"]?.doubleValue ?? 0),
                bytesCompleted: Int64(file["bytes_completed"]?.doubleValue ?? 0),
                wanted: stat?["wanted"]?.boolValue ?? true,
                priority: stat?["priority"]?.intValue ?? 0
            )
        }
    }
}

/// How long to keep sharing after the download completes.
public enum SeedPolicy: Codable, Hashable, Sendable {
    case stopWhenDone
    case ratio(Double)
    case idleMinutes(Int)

    public static let `default` = SeedPolicy.ratio(1.0)

    public var displayName: String {
        switch self {
        case .stopWhenDone: return "下载完成即停止"
        case .ratio(let r): return String(format: "分享率达到 %.1f 后停止", r)
        case .idleMinutes(let m): return "空闲 \(m) 分钟后停止"
        }
    }

    /// `torrent_set` arguments. Mode 1 = use this torrent's own limit.
    var torrentArguments: [String: JSONValue] {
        switch self {
        case .stopWhenDone:
            return ["seed_ratio_mode": 1, "seed_ratio_limit": 0]
        case .ratio(let ratio):
            return ["seed_ratio_mode": 1, "seed_ratio_limit": .number(ratio)]
        case .idleMinutes(let minutes):
            return ["seed_idle_mode": 1, "seed_idle_limit": .number(Double(minutes)), "seed_ratio_mode": 2]
        }
    }
}
#endif
