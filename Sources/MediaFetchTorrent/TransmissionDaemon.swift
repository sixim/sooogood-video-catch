import Darwin
import Foundation
import MediaFetchCore

// BitTorrent is Local-profile only; nothing here ships in the Store binary.
#if !MEDIAFETCH_STORE_PROFILE
/// Owns a private `transmission-daemon` child process: loopback-only RPC on a
/// random port, fresh random credentials every launch, and a config directory
/// that nobody else uses. Torrent resume state persists in that directory, so
/// torrents survive app restarts without our own bookkeeping.
public final class TransmissionDaemon: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var executable: URL
        public var configDirectory: URL
        public var downloadDirectory: URL
        public var portForwarding: Bool
        /// When true the daemon is launched without the watchdog so it keeps
        /// seeding after the app quits; the next launch adopts it via Keychain.
        public var keepRunningAfterAppQuits: Bool
        public var credentials: TorrentCredentialStoring

        public init(executable: URL, configDirectory: URL, downloadDirectory: URL, portForwarding: Bool = true,
                    keepRunningAfterAppQuits: Bool = false,
                    credentials: TorrentCredentialStoring = InMemoryTorrentCredentialStore()) {
            self.executable = executable
            self.configDirectory = configDirectory
            self.downloadDirectory = downloadDirectory
            self.portForwarding = portForwarding
            self.keepRunningAfterAppQuits = keepRunningAfterAppQuits
            self.credentials = credentials
        }
    }

    public static func findExecutable() -> URL? {
        ["/opt/homebrew/bin/transmission-daemon", "/usr/local/bin/transmission-daemon"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static var defaultConfigDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MediaFetch", isDirectory: true)
            .appendingPathComponent("transmission", isDirectory: true)
    }

    private var configuration: Configuration
    private var process: Process?
    /// True when this app session attached to a daemon started by an earlier session.
    public private(set) var adoptedExisting = false
    private let lock = NSLock()

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public var isRunning: Bool {
        lock.withLock { process?.isRunning == true }
    }

    /// Starts the daemon and waits until RPC answers.
    public func start(session: URLSession = .shared) async throws -> TransmissionRPCClient {
        let manager = FileManager.default
        let dir = configuration.configDirectory
        try manager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        // A daemon left seeding by the previous session: adopt it instead of restarting.
        if let saved = configuration.credentials.load() {
            let client = TransmissionRPCClient(endpoint: saved.endpoint, session: session)
            if (try? await client.version()) != nil {
                adoptedExisting = true
                return client
            }
        }
        terminateStaleDaemon()

        let port = try Self.freeLoopbackPort()
        let username = "mediafetch"
        let password = Self.randomSecret()
        try writeSettings(port: port, username: username, password: password)
        configuration.credentials.save(TorrentRPCCredentials(port: port, username: username, password: password))

        let task = Process()
        let daemonArguments = ["--foreground", "--config-dir", dir.path,
                               "--log-level=warn", "--logfile", dir.appendingPathComponent("daemon.log").path]
        if configuration.keepRunningAfterAppQuits {
            task.executableURL = configuration.executable
            task.arguments = daemonArguments
        } else {
            // A small sh watchdog owns the daemon: if the app dies (crash, force quit,
            // SIGKILL) the daemon is stopped too instead of seeding on as an orphan.
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", Self.watchdogScript, "mediafetch-transmission", configuration.executable.path] + daemonArguments
        }
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { throw TorrentError.engineFailedToStart(error.localizedDescription) }
        lock.withLock { process = task }
        try? String(task.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)

        let client = TransmissionRPCClient(
            endpoint: .init(port: port, username: username, password: password), session: session
        )
        for _ in 0..<100 {
            if !task.isRunning {
                throw TorrentError.engineFailedToStart(Self.tail(of: dir.appendingPathComponent("daemon.log")))
            }
            if (try? await client.version()) != nil { return client }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        stop()
        throw TorrentError.engineFailedToStart("RPC 在 10 秒内没有响应")
    }

    /// Quits the daemon unless the user chose to keep seeding after quit.
    public func stopForAppQuit(keepSeeding: Bool) {
        if keepSeeding { return }
        stop()
    }

    /// SIGTERM lets the daemon flush resume files before exiting.
    public func stop() {
        let task: Process? = lock.withLock {
            let current = process
            process = nil
            return current
        }
        configuration.credentials.clear()
        guard let task, task.isRunning else {
            // Adopted daemon from an earlier session: stop it through its pid file.
            if adoptedExisting { terminateStaleDaemon(); adoptedExisting = false }
            return
        }
        task.terminate()
        let deadline = Date().addingTimeInterval(5)
        while task.isRunning && Date() < deadline { usleep(50_000) }
        if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        try? FileManager.default.removeItem(at: pidFile)
    }

    // MARK: Internals

    private var pidFile: URL { configuration.configDirectory.appendingPathComponent("daemon.pid") }

    /// A crashed previous app session may leave its daemon holding the config
    /// directory. Only a process that is really transmission-daemon is killed.
    private func terminateStaleDaemon() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
           String(cString: buffer).hasSuffix("transmission-daemon") {
            kill(pid, SIGTERM)
            for _ in 0..<50 where kill(pid, 0) == 0 { usleep(100_000) }
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    func writeSettings(port: Int, username: String, password: String) throws {
        let url = configuration.configDirectory.appendingPathComponent("settings.json")
        var settings: [String: JSONValue] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONDecoder().decode(JSONValue.self, from: data).objectValue {
            settings = existing
        }
        let overrides: [String: JSONValue] = [
            "rpc_enabled": true,
            "rpc_bind_address": "127.0.0.1",
            "rpc_port": .number(Double(port)),
            "rpc_authentication_required": true,
            "rpc_username": .string(username),
            "rpc_password": .string(password),
            "rpc_whitelist_enabled": true,
            "rpc_whitelist": "127.0.0.1,::1",
            "rpc_host_whitelist_enabled": true,
            "download_dir": .string(configuration.downloadDirectory.path),
            "port_forwarding_enabled": .bool(configuration.portForwarding),
            "watch_dir_enabled": false,
            "script_torrent_added_enabled": false,
            "script_torrent_done_enabled": false,
            "script_torrent_done_seeding_enabled": false,
            "rename_partial_files": true,
            "start_added_torrents": true,
            "umask": "077"
        ]
        settings.merge(overrides) { _, new in new }
        if settings["peer_port"] == nil {
            settings["peer_port"] = .number(Double(Int.random(in: 49_152...65_000)))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(JSONValue.object(settings)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// `$@` is the daemon command line; nothing is interpolated into the script.
    static let watchdogScript = """
    "$@" &
    child=$!
    parent=$PPID
    trap 'kill -TERM "$child" 2>/dev/null; wait "$child"; exit 0' TERM INT HUP
    while kill -0 "$parent" 2>/dev/null; do
        if ! kill -0 "$child" 2>/dev/null; then wait "$child"; exit $?; fi
        sleep 1
    done
    kill -TERM "$child" 2>/dev/null
    wait "$child"
    """

    static func freeLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TorrentError.engineFailedToStart("无法分配端口") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw TorrentError.engineFailedToStart("无法分配端口") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    static func randomSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
    }

    private static func tail(of url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "进程已退出" }
        return text.split(separator: "\n").suffix(3).joined(separator: " ")
    }
}
#endif
