import Foundation
import MediaFetchCore

// Agent control (local socket + MCP) is Local-profile only.
#if !MEDIAFETCH_STORE_PROFILE
/// The tools agents can call. Shared by the app (which executes them) and the
/// MCP helper (which advertises them), so both always agree. There is
/// deliberately no tool that deletes tasks or files.
public struct ControlTool: Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": false
        ]
    }

    static let string: JSONValue = ["type": "string"]
    static let stringArray: JSONValue = ["type": "array", "items": ["type": "string"], "minItems": 1]
    static let taskID: JSONValue = ["type": "string", "description": "Task id from list_tasks (video UUID, torrent info hash, or tool job UUID)"]

    public static let all: [ControlTool] = [
        .init(name: "app_status",
              description: "Sooogood Video Catch version, which engines are installed, and task counts.",
              inputSchema: schema([:])),
        .init(name: "analyze_url",
              description: "Resolve one media URL with yt-dlp without downloading: title, uploader, duration, best resolution, format count.",
              inputSchema: schema(["url": string], required: ["url"])),
        .init(name: "preflight_batch",
              description: "Check several URLs before downloading: unsupported, needs login, unavailable, already downloaded, estimated size vs free disk space.",
              inputSchema: schema(["urls": stringArray, "profile": profileSchema], required: ["urls"])),
        .init(name: "enqueue_download",
              description: "Add media URLs to the download queue. Each item becomes an auditable package with manifest.json and SHA-256. Destination must be inside ~/Downloads, ~/Movies or the folder chosen in the app.",
              inputSchema: schema([
                "urls": stringArray, "profile": profileSchema,
                "destination": ["type": "string", "description": "Absolute folder path; defaults to the app's current download folder"],
                "subtitles": ["type": "boolean"], "sidecars": ["type": "boolean", "description": "Thumbnail and info.json"]
              ], required: ["urls"])),
        .init(name: "expand_collection",
              description: String(localized: "List the entries of a playlist or course (YouTube playlist, Udemy course, Bilibili 课堂) with chapters, without downloading."),
              inputSchema: schema(["url": string], required: ["url"])),
        .init(name: "enqueue_collection",
              description: "Queue entries of a playlist or course into one folder with chapter sub-folders and a collection-manifest.json. Omit indices to take every entry. DRM-protected lectures are skipped and recorded.",
              inputSchema: schema([
                "url": string,
                "indices": ["type": "array", "items": ["type": "integer"], "description": "Entry indices from expand_collection"],
                "profile": profileSchema,
                "destination": ["type": "string"]
              ], required: ["url"])),
        .init(name: "analyze_music",
              description: "Resolve a NetEase Cloud Music or QQ Music link (song, album, playlist, artist, chart; share text and short links accepted): artists, album, duration, lyrics, and which qualities this account can download (128k…320k, lossless, Hi-Res). Lists expand to their tracks; NetEase tracks the platform has no rights to carry unavailable_reason and are skipped by enqueue_music; tracks already in the music folder carry local_path.",
              inputSchema: schema(["url": string], required: ["url"])),
        .init(name: "enqueue_music",
              description: "Download NetEase Cloud Music / QQ Music tracks as tagged packages (original audio, embedded cover and lyrics, .lrc, manifest with measured quality). Lists take optional indices. Never transcodes; tracks without the requested quality, without platform rights, or already in the destination are skipped and reported.",
              inputSchema: schema([
                "url": string,
                "indices": ["type": "array", "items": ["type": "integer"], "description": "Track indices from analyze_music (lists only)"],
                "quality": ["type": "string", "enum": ["best", "losslessOnly", "upTo320"]],
                "layout": ["type": "string", "enum": ["artistAlbum", "flat", "collection"]],
                "destination": ["type": "string", "description": "Folder; defaults to the app's music folder"],
                "skip_existing": ["type": "boolean", "description": "Skip tracks already downloaded (same platform + track id) in the destination or moved elsewhere by the app. Default true."]
              ], required: ["url"])),
        .init(name: "list_tasks",
              description: "List video downloads, torrents and toolbox jobs with status and progress.",
              inputSchema: schema([
                "kind": ["type": "string", "enum": ["video", "torrent", "tools", "all"]],
                "limit": ["type": "integer", "minimum": 1, "maximum": 200]
              ])),
        .init(name: "list_torrents", description: "List torrents with progress, speed, share ratio and whether their manifest is written.",
              inputSchema: schema([:])),
        .init(name: "get_task", description: "Details of one task, including failure diagnosis and output paths.",
              inputSchema: schema(["id": taskID], required: ["id"])),
        .init(name: "pause_task", description: "Pause a running video download or a torrent.",
              inputSchema: schema(["id": taskID], required: ["id"])),
        .init(name: "resume_task", description: "Resume a paused video download or torrent.",
              inputSchema: schema(["id": taskID], required: ["id"])),
        .init(name: "cancel_task", description: "Cancel a queued or running video download or toolbox job. Downloaded files are kept.",
              inputSchema: schema(["id": taskID], required: ["id"])),
        .init(name: "retry_task", description: "Re-queue a failed or cancelled video download.",
              inputSchema: schema(["id": taskID], required: ["id"])),
        .init(name: "read_manifest", description: "Return the provenance manifest (files, SHA-256, source, engine) of a finished video download or torrent.",
              inputSchema: schema(["id": taskID], required: ["id"])),
        .init(name: "add_torrent",
              description: "Add a magnet link. Only for content the user has the right to download and share; requires the user to have accepted the in-app notice.",
              inputSchema: schema([
                "magnet": string, "sequential": ["type": "boolean"],
                "seed_policy": ["type": "string", "enum": ["stop_when_done", "ratio_1", "ratio_2", "idle_30min"]]
              ], required: ["magnet"])),
        .init(name: "run_tool",
              description: "Run creator tools on local media files: proxies (ProRes/DNxHR/H.264), ProRes 422 transcode, HEVC compress, audio extract, WAV, GIF preview, whisper transcription.",
              inputSchema: schema([
                "paths": stringArray,
                "presets": ["type": "array", "minItems": 1, "items": ["type": "string", "enum": [
                    "transcribe", "proresProxy", "proresLT", "prores422", "dnxhrLB", "h264Proxy",
                    "hevcCompress", "extractAudio", "wavForEdit", "gifPreview"]]],
                "language": ["type": "string", "description": "Transcription language code or 'auto'"]
              ], required: ["paths", "presets"])),
        .init(name: "get_transcript", description: "Read the plain-text transcript produced next to a media file.",
              inputSchema: schema(["path": ["type": "string", "description": "Media file path or transcript .txt path"]], required: ["path"])),
        .init(name: "send_to_resolve",
              description: "Import a finished package into the current DaVinci Resolve project (bin Sooogood/<package>), with provenance metadata and linked proxies.",
              inputSchema: schema(["id": taskID, "path": ["type": "string", "description": "Package folder, if no task id"]]))
    ]

    static let profileSchema: JSONValue = [
        "type": "string", "enum": ["highest", "source", "mp4", "audio"],
        "description": "highest = best video+audio merged to MKV; source = original streams; mp4 = H.264/AAC MP4; audio = best original audio"
    ]

    public static func named(_ name: String) -> ControlTool? { all.first { $0.name == name } }
}

public struct ControlError: Error, Equatable, Sendable, LocalizedError {
    public let code: Int
    public let message: String

    /// Compared by the MCP helper to reconnect once after the app restarts.
    public static let disconnectedMessage = String(localized: "应用断开了连接")

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public static func invalidParams(_ message: String) -> ControlError { .init(code: -32602, message: message) }
    public static func notFound(_ message: String) -> ControlError { .init(code: -32004, message: message) }
    public static func forbidden(_ message: String) -> ControlError { .init(code: -32003, message: message) }
    public static func failed(_ message: String) -> ControlError { .init(code: -32000, message: message) }
    public static let unknownMethod = ControlError(code: -32601, message: "Unknown method")

    public var errorDescription: String? { message }
}

/// Implemented by the app; receives validated tool calls.
public protocol ControlHandler: Sendable {
    func handle(tool: String, arguments: [String: JSONValue]) async throws -> JSONValue
}

public enum ControlPaths {
    /// Short enough for `sockaddr_un.sun_path` (104 bytes) under a normal home.
    public static var socket: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MediaFetch/control.sock")
    }
}
#endif
