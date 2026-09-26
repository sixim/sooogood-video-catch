import Foundation

/// A private, short-lived engine credential file. Never put it in media output,
/// history, manifests, or logs. Its owner keeps it alive until Process exits.
final class TemporaryCookieFile: @unchecked Sendable {
    let directory: URL
    let url: URL

    init(data: Data, root: URL = FileManager.default.temporaryDirectory) throws {
        directory = root.appendingPathComponent("MediaFetch-session-" + UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent("cookies.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: url.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            try? FileManager.default.removeItem(at: directory)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
    deinit { remove() }
}
