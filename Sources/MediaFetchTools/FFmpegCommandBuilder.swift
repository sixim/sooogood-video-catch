import Foundation
import MediaFetchCore

#if !MEDIAFETCH_STORE_PROFILE
/// Builds ffmpeg argument arrays for each preset. Pure: no process, no disk.
public enum FFmpegCommandBuilder {
    /// Half resolution above 1080p, otherwise unchanged; always even dimensions.
    static let proxyScale = "scale=w=-2:h='trunc(if(gt(ih,1080),ih/2,ih)/2)*2'"

    public struct Plan: Equatable, Sendable {
        public let arguments: [String]
        public let output: URL
    }

    /// Prefix shared by every run: never overwrite, machine-readable progress.
    static func common(input: URL) -> [String] {
        ["-hide_banner", "-nostdin", "-n", "-loglevel", "error", "-progress", "pipe:1", "-nostats", "-i", input.path]
    }

    public static func outputURL(for input: URL, preset: ToolPreset, probe: MediaProbe) -> URL {
        let base = input.deletingPathExtension()
        let ext = outputExtension(preset: preset, probe: probe)
        return base.appendingPathExtension(preset.suffix).appendingPathExtension(ext)
    }

    static func outputExtension(preset: ToolPreset, probe: MediaProbe) -> String {
        switch preset {
        case .transcribe: return "srt"
        case .proresProxy, .proresLT, .prores422, .dnxhrLB: return "mov"
        case .h264Proxy, .hevcCompress: return "mp4"
        case .extractAudio: return probe.audioCopyExtension ?? "wav"
        case .wavForEdit: return "wav"
        case .gifPreview: return "gif"
        }
    }

    /// - Parameter hardwareProRes: VideoToolbox ProRes (fast on Apple silicon);
    ///   false falls back to the software `prores_ks` encoder.
    public static func plan(input: URL, preset: ToolPreset, probe: MediaProbe, output: URL? = nil,
                            hardwareProRes: Bool = true) -> Plan {
        let output = output ?? outputURL(for: input, preset: preset, probe: probe)
        var args = common(input: input)
        let keepMetadata = ["-map_metadata", "0"]
        let pcmAudio = ["-c:a", "pcm_s16le"]
        switch preset {
        case .proresProxy:
            args += ["-map", "0:v:0", "-map", "0:a?", "-vf", proxyScale] + prores(profile: .proxy, hardware: hardwareProRes)
                + pcmAudio + keepMetadata
        case .proresLT:
            args += ["-map", "0:v:0", "-map", "0:a?"] + prores(profile: .lt, hardware: hardwareProRes) + pcmAudio + keepMetadata
        case .prores422:
            args += ["-map", "0:v:0", "-map", "0:a?"] + prores(profile: .standard, hardware: hardwareProRes) + pcmAudio + keepMetadata
        case .dnxhrLB:
            args += ["-map", "0:v:0", "-map", "0:a?", "-vf", proxyScale + ",format=yuv422p",
                     "-c:v", "dnxhd", "-profile:v", "dnxhr_lb"] + pcmAudio + keepMetadata
        case .h264Proxy:
            args += ["-map", "0:v:0", "-map", "0:a?", "-vf", proxyScale, "-c:v", "h264_videotoolbox", "-b:v", "8M",
                     "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"] + keepMetadata
        case .hevcCompress:
            args += ["-map", "0:v:0", "-map", "0:a?", "-c:v", "hevc_videotoolbox", "-q:v", "55", "-tag:v", "hvc1",
                     "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"] + keepMetadata
        case .extractAudio:
            if probe.audioCopyExtension != nil {
                args += ["-map", "0:a:0", "-vn", "-c:a", "copy"] + keepMetadata
            } else {
                args += ["-map", "0:a:0", "-vn", "-c:a", "pcm_s24le"] + keepMetadata
            }
        case .wavForEdit:
            args += ["-map", "0:a:0", "-vn", "-c:a", "pcm_s24le", "-ar", "48000"] + keepMetadata
        case .gifPreview:
            args += ["-filter_complex", "fps=12,scale=640:-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer",
                     "-loop", "0"]
        case .transcribe:
            // Audio prep for whisper: 16 kHz mono 16-bit PCM.
            args += ["-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le"]
        }
        args.append(output.path)
        return Plan(arguments: args, output: output)
    }

    enum ProResProfile {
        case proxy, lt, standard
        var videotoolbox: String {
            switch self { case .proxy: return "proxy"; case .lt: return "lt"; case .standard: return "standard" }
        }
        var ks: String {
            switch self { case .proxy: return "0"; case .lt: return "1"; case .standard: return "2" }
        }
    }

    static func prores(profile: ProResProfile, hardware: Bool) -> [String] {
        hardware
            ? ["-c:v", "prores_videotoolbox", "-profile:v", profile.videotoolbox]
            : ["-c:v", "prores_ks", "-profile:v", profile.ks, "-vendor", "apl0", "-pix_fmt", "yuv422p10le"]
    }

    /// Parses one `-progress` line pair into seconds of output written.
    public static func progressSeconds(from line: String) -> Double? {
        if line.hasPrefix("out_time_us="), let value = Double(line.dropFirst("out_time_us=".count)) {
            return value / 1_000_000
        }
        if line.hasPrefix("out_time_ms="), let value = Double(line.dropFirst("out_time_ms=".count)) {
            return value / 1_000_000 // ffmpeg reports microseconds under this key too.
        }
        return nil
    }
}
#endif
