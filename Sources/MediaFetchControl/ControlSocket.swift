import Darwin
import Foundation
import MediaFetchCore

#if !MEDIAFETCH_STORE_PROFILE
/// Newline-delimited JSON over a Unix domain socket owned by the current user.
/// Request:  {"id": 1, "tool": "list_tasks", "arguments": {...}}
/// Response: {"id": 1, "result": ...} or {"id": 1, "error": {"code": -32000, "message": "..."}}
public final class ControlServer: @unchecked Sendable {
    private let path: String
    private let handler: ControlHandler
    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private var running = false

    public init(socketURL: URL = ControlPaths.socket, handler: ControlHandler) {
        path = socketURL.path
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.failed("socket() failed: \(errno)") }
        var address = try Self.address(for: path)
        // Create the socket node with 0600 from the start: no window where others can connect.
        let previousMask = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previousMask)
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw ControlError.failed("无法监听控制端口：\(String(cString: strerror(errno)))")
        }
        chmod(path, 0o600)
        lock.withLock { listenFD = fd; running = true }
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    public func stop() {
        let fd: Int32 = lock.withLock {
            running = false
            let current = listenFD
            listenFD = -1
            return current
        }
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            unlink(path)
        }
    }

    private func acceptLoop(_ fd: Int32) {
        while lock.withLock({ running }) {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            // Only processes of the same user may talk to the app.
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                close(client)
                continue
            }
            Self.disableSigPipe(client)
            Thread.detachNewThread { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        let writer = LineWriter(fd: fd)
        let reader = LineReader(fd: fd)
        while let line = reader.next() {
            guard let request = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else {
                writer.send(["id": .null, "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            let id = request["id"] ?? .null
            guard let tool = request["tool"]?.stringValue else {
                writer.send(["id": id, "error": ["code": -32600, "message": "Missing tool"]])
                continue
            }
            let arguments = request["arguments"]?.objectValue ?? [:]
            let handler = self.handler
            let done = DispatchSemaphore(value: 0)
            Task {
                do {
                    let result = try await handler.handle(tool: tool, arguments: arguments)
                    writer.send(["id": id, "result": result])
                } catch let error as ControlError {
                    writer.send(["id": id, "error": ["code": .number(Double(error.code)), "message": .string(error.message)]])
                } catch {
                    writer.send(["id": id, "error": ["code": -32000, "message": .string(error.localizedDescription)]])
                }
                done.signal()
            }
            done.wait()
        }
        close(fd)
    }

    /// A peer that disconnects mid-write must not kill the app with SIGPIPE.
    static func disableSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ControlError.failed("控制端口路径过长")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        return address
    }
}

/// Client used by the MCP helper (and tests).
public final class ControlClient: @unchecked Sendable {
    private let fd: Int32
    private let reader: LineReader
    private let writer: LineWriter
    private var nextID = 1
    private let lock = NSLock()

    public init(socketURL: URL = ControlPaths.socket) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.failed("socket() failed") }
        var address = try ControlServer.address(for: socketURL.path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(fd)
            throw ControlError.failed("Sooogood Video Catch 没有运行")
        }
        ControlServer.disableSigPipe(fd)
        self.fd = fd
        reader = LineReader(fd: fd)
        writer = LineWriter(fd: fd)
    }

    deinit { close(fd) }

    /// Blocking call; one request at a time per client.
    public func call(_ tool: String, _ arguments: [String: JSONValue] = [:]) throws -> JSONValue {
        try lock.withLock {
            let id = nextID
            nextID += 1
            writer.send(["id": .number(Double(id)), "tool": .string(tool), "arguments": .object(arguments)])
            guard let line = reader.next(),
                  let reply = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else {
                throw ControlError.failed("应用断开了连接")
            }
            if let error = reply["error"] {
                throw ControlError(code: error["code"]?.intValue ?? -32000, message: error["message"]?.stringValue ?? "error")
            }
            return reply["result"] ?? .null
        }
    }
}

final class LineReader {
    private let fd: Int32
    private var buffer = Data()

    init(fd: Int32) { self.fd = fd }

    /// Next line without its newline, or nil at EOF.
    func next() -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 {
                if count < 0 && errno == EINTR { continue }
                return nil
            }
            buffer.append(contentsOf: chunk[0..<count])
            if buffer.count > 16 * 1024 * 1024 { return nil } // refuse absurd frames
        }
    }
}

final class LineWriter: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()

    init(fd: Int32) { self.fd = fd }

    func send(_ value: JSONValue) {
        guard var data = try? JSONEncoder().encode(value) else { return }
        data.append(0x0A)
        lock.withLock {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written <= 0 { if errno == EINTR { continue }; return }
                    offset += written
                }
            }
        }
    }
}
#endif
