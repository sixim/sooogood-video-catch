import Foundation

enum BrowserCookieSource: String, CaseIterable, Identifiable, Codable {
    case safari
    case chrome
    case firefox

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Google Chrome"
        case .firefox: return "Firefox"
        }
    }

    var ytDLPArguments: [String] {
        ["--cookies-from-browser", rawValue]
    }

    static var recommendedDefault: BrowserCookieSource {
        if FileManager.default.fileExists(atPath: "/Applications/Google Chrome.app") { return .chrome }
        if FileManager.default.fileExists(atPath: "/Applications/Firefox.app") { return .firefox }
        return .safari
    }
}

enum SafariCookieAccess {
    private static let candidatePaths = [
        NSHomeDirectory() + "/Library/Cookies/Cookies.binarycookies",
        NSHomeDirectory() + "/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"
    ]

    static func canReadCookieStore() -> Bool {
        for path in candidatePaths where FileManager.default.fileExists(atPath: path) {
            do {
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                try handle.close()
                return true
            } catch {
                return false
            }
        }
        return false
    }
}

enum EngineErrorClassifier {
    static func isSafariCookiePermissionError(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("cookies.binarycookies") &&
            (lowered.contains("operation not permitted") || lowered.contains("permission denied"))
    }

    static func isDRMError(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("known to use drm protection") ||
            lowered.contains("drm protected") || lowered.contains("has_drm")
    }
}

enum DownloadProfile: String, CaseIterable, Identifiable, Codable {
    case highest = "最高画质（无损合并）"
    case sourceStreams = "保留平台原始音视频流"
    case compatibleMP4 = "兼容 MP4（无损封装）"
    case audioOnly = "仅保存最佳原始音频"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .highest:
            return "选择最佳视频流 + 最佳音频流，仅重新封装为 MKV，不重新编码。"
        case .sourceStreams:
            return "分别保存平台直接提供的视频流和音频流，内容不转码、不合并。"
        case .compatibleMP4:
            return "优先选择 H.264 + M4A 并无损封装为 MP4；为兼容剪辑软件，画质可能低于最高画质模式。"
        case .audioOnly:
            return "只保存平台直接提供的最佳音频流，不转换为 MP3，不伪装来源。"
        }
    }

    var formatSelector: String {
        switch self {
        case .highest: return "bv*+ba/b"
        case .sourceStreams: return "bv,ba"
        case .compatibleMP4:
            return "bv*[vcodec^=avc1][ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*[ext=mp4]+ba[ext=m4a]/bv*+ba/b"
        case .audioOnly: return "ba/b"
        }
    }

    var requiresFFmpeg: Bool {
        switch self {
        case .highest, .compatibleMP4: return true
        case .sourceStreams, .audioOnly: return false
        }
    }
}

struct MediaMetadata: Decodable {
    struct Format: Decodable, Identifiable {
        let formatID: String?
        let extensionName: String?
        let height: Int?
        let width: Int?
        let fps: Double?
        let videoCodec: String?
        let audioCodec: String?
        let filesize: Int64?
        let approximateFilesize: Int64?
        let totalBitrate: Double?
        let videoBitrate: Double?
        let audioBitrate: Double?
        let dynamicRange: String?
        let language: String?

        enum CodingKeys: String, CodingKey {
            case formatID = "format_id"
            case extensionName = "ext"
            case height, width, fps, filesize
            case videoCodec = "vcodec"
            case audioCodec = "acodec"
            case approximateFilesize = "filesize_approx"
            case totalBitrate = "tbr"
            case videoBitrate = "vbr"
            case audioBitrate = "abr"
            case dynamicRange = "dynamic_range"
            case language
        }

        var id: String {
            [formatID, extensionName, videoCodec, audioCodec].compactMap { $0 }.joined(separator: "-")
        }

        var resolutionText: String {
            if let width, let height { return "\(width)×\(height)" }
            if videoCodec == "none" { return "纯音频" }
            return height.map { "\($0)p" } ?? "未知"
        }

        var codecText: String {
            [videoCodec, audioCodec, dynamicRange, language]
                .compactMap { $0 }
                .filter { $0 != "none" && $0 != "SDR" }
                .joined(separator: " · ")
        }

        var sizeText: String {
            guard let bytes = filesize ?? approximateFilesize else { return "大小未知" }
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }

        var bitrateText: String {
            guard let bitrate = totalBitrate ?? videoBitrate ?? audioBitrate else { return "未知" }
            if bitrate >= 1_000 { return String(format: "%.1f Mbps", bitrate / 1_000) }
            return String(format: "%.0f kbps", bitrate)
        }
    }

    let id: String
    let title: String
    let uploader: String?
    let duration: Double?
    let thumbnail: String?
    let extractor: String?
    let formats: [Format]?

    var maximumResolution: String {
        guard let format = formats?
            .filter({ ($0.height ?? 0) > 0 })
            .max(by: { ($0.height ?? 0, $0.fps ?? 0) < ($1.height ?? 0, $1.fps ?? 0) })
        else { return "未知" }

        let dimensions: String
        if let width = format.width, let height = format.height {
            dimensions = "\(width)×\(height)"
        } else {
            dimensions = "\(format.height ?? 0)p"
        }
        if let fps = format.fps, fps > 0 {
            return "\(dimensions) · \(Int(fps.rounded())) fps"
        }
        return dimensions
    }

    var durationText: String {
        guard let duration else { return "时长未知" }
        let total = Int(duration.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    var videoFormatsForInspection: [Format] {
        let video = (formats ?? []).filter { $0.videoCodec != nil && $0.videoCodec != "none" }
        return video.sorted {
            (($0.height ?? 0), ($0.fps ?? 0), ($0.filesize ?? $0.approximateFilesize ?? 0)) >
            (($1.height ?? 0), ($1.fps ?? 0), ($1.filesize ?? $1.approximateFilesize ?? 0))
        }
    }

    var audioFormatsForInspection: [Format] {
        (formats ?? [])
            .filter { $0.videoCodec == "none" && $0.audioCodec != nil && $0.audioCodec != "none" }
            .sorted {
                (($0.audioBitrate ?? 0), ($0.filesize ?? $0.approximateFilesize ?? 0)) >
                (($1.audioBitrate ?? 0), ($1.filesize ?? $1.approximateFilesize ?? 0))
            }
    }
}

struct DownloadProgress: Equatable {
    var fraction: Double = 0
    var percentText = "0%"
    var speedText = ""
    var etaText = ""
}

enum ProgressParser {
    static func parse(_ line: String) -> DownloadProgress? {
        guard line.hasPrefix("MF_PROGRESS|") else { return nil }
        let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 6 else { return nil }

        let cleanPercent = parts[1]
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        let percent = Double(cleanPercent) ?? 0
        let speed = parts[4] == "NA" ? "" : parts[4]
        let eta = parts[5] == "NA" ? "" : parts[5]
        return DownloadProgress(
            fraction: min(max(percent / 100, 0), 1),
            percentText: String(format: "%.1f%%", percent),
            speedText: speed,
            etaText: eta
        )
    }
}

enum URLValidator {
    static func validatedMediaURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }

    static func isVimeoURL(_ input: String) -> Bool {
        guard let host = validatedMediaURL(from: input)?.host?.lowercased() else { return false }
        return host == "vimeo.com" || host.hasSuffix(".vimeo.com")
    }
}
