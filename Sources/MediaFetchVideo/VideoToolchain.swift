import Foundation

#if !MEDIAFETCH_STORE_PROFILE
/// Describes where the video engine is sourced from and which capabilities it may use.
///
/// The app layer never needs to know whether the engine is a local Homebrew install or
/// an optional future helper embedded in a sandboxed App Store build.
public struct VideoToolchain: Sendable, Equatable {
    public let ytDLPURL: URL?
    public let ffmpegURL: URL?
    public let allowsBrowserCookies: Bool
    public let processEnvironment: [String: String]

    public init(
        ytDLPURL: URL?,
        ffmpegURL: URL?,
        allowsBrowserCookies: Bool,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.ytDLPURL = ytDLPURL
        self.ffmpegURL = ffmpegURL
        self.allowsBrowserCookies = allowsBrowserCookies
        self.processEnvironment = processEnvironment
    }

    /// The developer/local profile. External tools are intentionally explicit here.
    public static func local(
        ytDLPURL: URL? = nil,
        ffmpegURL: URL? = nil
    ) -> VideoToolchain {
        let resolvedYTDLP = ytDLPURL ?? Self.findExecutable(named: "yt-dlp")
        let resolvedFFmpeg = ffmpegURL ?? Self.findExecutable(named: "ffmpeg")
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        return VideoToolchain(
            ytDLPURL: resolvedYTDLP,
            ffmpegURL: resolvedFFmpeg,
            allowsBrowserCookies: true,
            processEnvironment: environment
        )
    }

    /// Compatibility factory for callers that still ask for bundled video tools.
    /// Store's applicationDefault is intentionally inert and never inspects this path.
    public static func bundled(bundleURL: URL = Bundle.main.bundleURL) -> VideoToolchain {
        let helperDirectory = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
        let ytDLP = helperDirectory.appendingPathComponent("yt-dlp")
        let ffmpeg = helperDirectory.appendingPathComponent("ffmpeg")
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(helperDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin"
        return VideoToolchain(
            ytDLPURL: Self.validBundledHelper(ytDLP) ? ytDLP : nil,
            ffmpegURL: Self.validBundledHelper(ffmpeg) ? ffmpeg : nil,
            allowsBrowserCookies: false,
            processEnvironment: environment
        )
    }

    public static let applicationDefault = VideoToolchain.local()

    private static func findExecutable(named name: String) -> URL? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private static func validBundledHelper(_ url: URL) -> Bool {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: url.path) else { return false }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }
}
#else
/// Store profile deliberately has no third-party video toolchain type data.
/// Keeping this small stub lets the shared app shell compile while the Local
/// yt-dlp/FFmpeg adapter is excluded from the Store binary entirely.
public struct VideoToolchain: Sendable, Equatable {
    public let allowsBrowserCookies: Bool
    public let processEnvironment: [String: String]

    public init(
        allowsBrowserCookies: Bool = false,
        processEnvironment: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    ) {
        self.allowsBrowserCookies = allowsBrowserCookies
        self.processEnvironment = processEnvironment
    }

    public static let applicationDefault = VideoToolchain()

    public static func bundled(bundleURL: URL = Bundle.main.bundleURL) -> VideoToolchain {
        VideoToolchain()
    }
}
#endif
