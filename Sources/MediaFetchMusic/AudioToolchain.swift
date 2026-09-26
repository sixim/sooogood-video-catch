import Foundation

#if !MEDIAFETCH_STORE_PROFILE
/// Describes the metadata probe used by the local audio scanner.
///
/// Keeping this separate from `LocalAudioScanner` makes the Local ffprobe,
/// native AVFoundation probe, or a future metadata service replaceable without
/// changing the Spotify UI or matching rules.
public struct AudioToolchain: Sendable, Equatable {
    public let ffprobeURL: URL?
    public let processEnvironment: [String: String]
    public let usesNativeProbe: Bool

    public init(
        ffprobeURL: URL?,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        usesNativeProbe: Bool = false
    ) {
        self.ffprobeURL = ffprobeURL
        self.processEnvironment = processEnvironment
        self.usesNativeProbe = usesNativeProbe
    }

    /// The developer/local profile. It may use an explicitly installed tool.
    public static func local(ffprobeURL: URL? = nil) -> AudioToolchain {
        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        return AudioToolchain(
            ffprobeURL: ffprobeURL ?? findExecutable(named: "ffprobe"),
            processEnvironment: environment
        )
    }

    /// Compatibility factory for callers that still ask for an embedded helper.
    /// Store's applicationDefault uses the native backend below and does not
    /// inspect this path.
    public static func bundled(bundleURL: URL = Bundle.main.bundleURL) -> AudioToolchain {
        let helperDirectory = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
        let ffprobe = helperDirectory.appendingPathComponent("ffprobe")
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(helperDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin"
        return AudioToolchain(
            ffprobeURL: validBundledHelper(ffprobe) ? ffprobe : nil,
            processEnvironment: environment,
            usesNativeProbe: false
        )
    }

    public static let applicationDefault = AudioToolchain.local()

    /// The Store-safe metadata backend. It intentionally does not expose a
    /// process path because NativeAudioScanner uses AVFoundation directly.
    public static func native() -> AudioToolchain {
        AudioToolchain(
            ffprobeURL: nil,
            processEnvironment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            usesNativeProbe: true
        )
    }

    private static func findExecutable(named name: String) -> URL? {
        let manager = FileManager.default
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
            URL(fileURLWithPath: "/usr/bin/\(name)")
        ]
        return candidates.first(where: { manager.isExecutableFile(atPath: $0.path) })
    }

    private static func validBundledHelper(_ url: URL) -> Bool {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: url.path) else { return false }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }
}
#else
/// Store profile exposes only the native probe contract. The Local ffprobe
/// fields and helper discovery are excluded from the Store binary entirely.
public struct AudioToolchain: Sendable, Equatable {
    public let processEnvironment: [String: String]
    public let usesNativeProbe: Bool

    public init(
        processEnvironment: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
        usesNativeProbe: Bool = true
    ) {
        self.processEnvironment = processEnvironment
        self.usesNativeProbe = usesNativeProbe
    }

    public static let applicationDefault = AudioToolchain()

    public static func native() -> AudioToolchain {
        AudioToolchain()
    }

    public static func bundled(bundleURL: URL = Bundle.main.bundleURL) -> AudioToolchain {
        AudioToolchain()
    }
}
#endif
