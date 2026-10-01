import AppKit
import Foundation
import MediaFetchCore

#if !MEDIAFETCH_STORE_PROFILE
/// Runs the Python bridge against the user's running DaVinci Resolve.
/// Arguments go to `Process` as an array; the request travels over stdin, so
/// no path or title ever passes through a shell.
public struct ResolveBridge: Sendable {
    public struct Environment: Sendable, Equatable {
        public var appURL: URL
        public var scriptAPI: URL
        public var scriptLibrary: URL
        public var python: URL

        public static let resolveBundleID = "com.blackmagic-design.DaVinciResolve"

        /// Standard macOS install locations documented in Resolve's scripting README.
        public static func discover() throws -> Environment {
            let manager = FileManager.default
            let app = URL(fileURLWithPath: "/Applications/DaVinci Resolve/DaVinci Resolve.app")
            let api = URL(fileURLWithPath: "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting")
            let library = app.appendingPathComponent("Contents/Libraries/Fusion/fusionscript.so")
            guard manager.fileExists(atPath: app.path),
                  manager.fileExists(atPath: api.appendingPathComponent("Modules/DaVinciResolveScript.py").path),
                  manager.fileExists(atPath: library.path) else { throw ResolveBridgeError.notInstalled }
            guard let python = findPython() else { throw ResolveBridgeError.pythonMissing }
            return Environment(appURL: app, scriptAPI: api, scriptLibrary: library, python: python)
        }

        /// Homebrew first; the system stub is used only when developer tools are
        /// present, otherwise it would pop an install dialog.
        static func findPython() -> URL? {
            let manager = FileManager.default
            for path in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"] where manager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            let hasDeveloperTools = manager.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/python3")
                || manager.fileExists(atPath: "/Applications/Xcode.app")
            return hasDeveloperTools ? URL(fileURLWithPath: "/usr/bin/python3") : nil
        }

        var processEnvironment: [String: String] {
            [
                "PATH": "/usr/bin:/bin",
                "HOME": NSHomeDirectory(),
                "RESOLVE_SCRIPT_API": scriptAPI.path,
                "RESOLVE_SCRIPT_LIB": scriptLibrary.path,
                "PYTHONPATH": scriptAPI.appendingPathComponent("Modules").path,
                "PYTHONIOENCODING": "utf-8",
                "PYTHONDONTWRITEBYTECODE": "1"
            ]
        }
    }

    public let environment: Environment
    public var timeout: TimeInterval = 120
    /// Tests drive the bridge against a fake scripting module without Resolve.
    var requiresRunningApp = true

    public init(environment: Environment) {
        self.environment = environment
    }

    public static var isResolveRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Environment.resolveBundleID).isEmpty
    }

    public func status() async throws -> ResolveStatus {
        let reply = try await run(["op": "status"])
        guard let status = reply["status"] else { throw ResolveBridgeError.bridgeFailed("缺少状态信息") }
        return try status.decoded(as: ResolveStatus.self)
    }

    public func importMedia(_ request: ResolveImportRequest) async throws -> ResolveImportResult {
        let reply = try await run(try JSONValue.encoded(request))
        guard let result = reply["result"] else { throw ResolveBridgeError.bridgeFailed("缺少导入结果") }
        return try result.decoded(as: ResolveImportResult.self)
    }

    /// Opens Resolve and waits until its scripting endpoint answers.
    public func launchAndWait(seconds: Int = 90) async throws -> ResolveStatus {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: environment.appURL, configuration: configuration)
        var lastError: Error = ResolveBridgeError.timedOut
        for _ in 0..<(seconds / 3) {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            do { return try await status() } catch { lastError = error }
        }
        throw lastError
    }

    // MARK: Process

    func run(_ request: JSONValue) async throws -> JSONValue {
        guard !requiresRunningApp || Self.isResolveRunning else { throw ResolveBridgeError.notRunning }
        let environment = self.environment
        let timeout = self.timeout
        let data = try await Task.detached(priority: .userInitiated) {
            try Self.execute(request: request, environment: environment, timeout: timeout)
        }.value
        let reply: JSONValue
        do { reply = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch {
            let text = String(decoding: data.prefix(300), as: UTF8.self)
            throw ResolveBridgeError.bridgeFailed(text.isEmpty ? "达芬奇脚本没有返回结果" : text)
        }
        guard reply["ok"]?.boolValue == true else { throw Self.mapError(reply) }
        return reply
    }

    static func mapError(_ reply: JSONValue) -> ResolveBridgeError {
        let detail = reply["detail"]?.stringValue ?? ""
        switch reply["error"]?.stringValue {
        case "not_connected": return .notConnected
        case "no_project": return .noProject
        case "not_ready": return .notReady
        case "module": return .scriptModuleMissing(detail)
        case "bin_failed": return .binFailed(detail)
        default: return .bridgeFailed(detail.isEmpty ? (reply["error"]?.stringValue ?? "未知错误") : detail)
        }
    }

    private static func execute(request: JSONValue, environment: Environment, timeout: TimeInterval) throws -> Data {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("MediaFetch-resolve-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        let script = directory.appendingPathComponent("bridge.py")
        try Data(ResolveBridgeScript.source.utf8).write(to: script)

        let process = Process()
        process.executableURL = environment.python
        // -s skips user site-packages; not -I, which would also drop PYTHONPATH.
        process.arguments = ["-s", script.path]
        process.environment = environment.processEnvironment
        process.currentDirectoryURL = directory
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(try JSONEncoder().encode(request))
        try input.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        let collected = OutputCollector(output.fileHandleForReading)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            throw ResolveBridgeError.timedOut
        }
        let data = collected.finish()
        if data.isEmpty {
            let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile().suffix(400), as: UTF8.self)
            throw ResolveBridgeError.bridgeFailed(stderr.isEmpty ? "Python 退出码 \(process.terminationStatus)" : stderr)
        }
        return data
    }
}

/// Drains a pipe on a background thread so a large reply cannot block the child.
private final class OutputCollector: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let all = handle.readDataToEndOfFile()
            lock.withLock { data = all }
            done.signal()
        }
    }

    func finish() -> Data {
        done.wait()
        return lock.withLock { data }
    }
}
#endif
