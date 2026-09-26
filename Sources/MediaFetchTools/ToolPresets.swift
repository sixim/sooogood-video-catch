import Foundation
import MediaFetchCore

// Creator toolbox (ffmpeg / whisper-cli) is Local-profile only.
#if !MEDIAFETCH_STORE_PROFILE
public enum ToolPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case transcribe
    case proresProxy
    case proresLT
    case prores422
    case dnxhrLB
    case h264Proxy
    case hevcCompress
    case extractAudio
    case wavForEdit
    case gifPreview

    public var id: String { rawValue }

    public enum Group: String, CaseIterable, Sendable {
        case edit = "剪辑"
        case audio = "音频与字幕"
        case share = "分享"
    }

    public var group: Group {
        switch self {
        case .proresProxy, .proresLT, .prores422, .dnxhrLB, .h264Proxy: return .edit
        case .transcribe, .extractAudio, .wavForEdit: return .audio
        case .hevcCompress, .gifPreview: return .share
        }
    }

    public var displayName: String {
        switch self {
        case .transcribe: return "转录字幕（SRT / VTT / TXT）"
        case .proresProxy: return "剪辑代理 · ProRes Proxy"
        case .proresLT: return "ProRes LT"
        case .prores422: return "达芬奇友好 · ProRes 422"
        case .dnxhrLB: return "剪辑代理 · DNxHR LB"
        case .h264Proxy: return "剪辑代理 · H.264（硬件编码）"
        case .hevcCompress: return "压缩 · HEVC（硬件编码）"
        case .extractAudio: return "提取原始音轨（不转码）"
        case .wavForEdit: return "WAV 24-bit / 48 kHz"
        case .gifPreview: return "GIF 预览"
        }
    }

    public var detail: String {
        switch self {
        case .transcribe: return "本机 whisper.cpp，Metal 加速；不上传任何音频"
        case .proresProxy: return "半分辨率（超过 1080p 时），VideoToolbox 硬件 ProRes；发送到达芬奇时自动关联为代理"
        case .proresLT: return "全分辨率，体积小于 422，适合调色前的中间素材"
        case .prores422: return "把 VP9 / AV1 等达芬奇不擅长的编码转成 ProRes 422，保留原分辨率与帧率"
        case .dnxhrLB: return "半分辨率 DNxHR LB，跨平台代理"
        case .h264Proxy: return "半分辨率 H.264 8 Mbps，体积最小的代理"
        case .hevcCompress: return "VideoToolbox HEVC 质量模式，适合分享与归档"
        case .extractAudio: return "直接复制平台提供的音频流，零损失"
        case .wavForEdit: return "PCM 24-bit 48 kHz，Logic / Fairlight 直接可用"
        case .gifPreview: return "12 fps、640 宽，调色板优化"
        }
    }

    public var role: DerivativeRecord.Role {
        switch self {
        case .transcribe: return .subtitle
        case .proresProxy, .dnxhrLB, .h264Proxy: return .proxy
        case .proresLT, .prores422: return .transcode
        case .hevcCompress: return .compressed
        case .extractAudio, .wavForEdit: return .audio
        case .gifPreview: return .preview
        }
    }

    /// File name suffix before the extension, e.g. `clip.proxy.mov`.
    public var suffix: String {
        switch self {
        case .transcribe: return ""
        case .proresProxy: return "proxy"
        case .proresLT: return "prores-lt"
        case .prores422: return "prores422"
        case .dnxhrLB: return "dnxhr-proxy"
        case .h264Proxy: return "h264-proxy"
        case .hevcCompress: return "hevc"
        case .extractAudio: return "audio"
        case .wavForEdit: return "edit"
        case .gifPreview: return "preview"
        }
    }

    public var needsVideo: Bool {
        ![.transcribe, .extractAudio, .wavForEdit].contains(self)
    }
}

/// What ffprobe told us about an input.
public struct MediaProbe: Equatable, Sendable {
    public let duration: Double?
    public let videoCodec: String?
    public let width: Int?
    public let height: Int?
    public let audioCodec: String?

    public init(duration: Double?, videoCodec: String?, width: Int?, height: Int?, audioCodec: String?) {
        self.duration = duration
        self.videoCodec = videoCodec
        self.width = width
        self.height = height
        self.audioCodec = audioCodec
    }

    /// Parses `ffprobe -of json -show_format -show_streams`.
    public init?(ffprobeJSON data: Data) {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        let streams = json["streams"]?.arrayValue ?? []
        let video = streams.first { $0["codec_type"]?.stringValue == "video" && $0["disposition"]?["attached_pic"]?.intValue != 1 }
        let audio = streams.first { $0["codec_type"]?.stringValue == "audio" }
        duration = json["format"]?["duration"]?.stringValue.flatMap(Double.init)
        videoCodec = video?["codec_name"]?.stringValue
        width = video?["width"]?.intValue
        height = video?["height"]?.intValue
        audioCodec = audio?["codec_name"]?.stringValue
    }

    /// Container that can hold the audio stream without re-encoding.
    public var audioCopyExtension: String? {
        switch audioCodec {
        case "aac", "alac": return "m4a"
        case "mp3": return "mp3"
        case "opus", "vorbis": return "ogg"
        case "flac": return "flac"
        case "pcm_s16le", "pcm_s24le", "pcm_f32le": return "wav"
        default: return nil
        }
    }
}
#endif
