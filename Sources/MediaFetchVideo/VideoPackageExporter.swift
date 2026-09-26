import Foundation

public enum VideoPackageExportError: LocalizedError, Equatable {
    case destinationUnavailable(String)
    case packageUnavailable(String)
    case copyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .destinationUnavailable(let path):
            return "无法访问用户选择的导出目录：\(path)"
        case .packageUnavailable(let path):
            return "下载 staging 素材包不存在：\(path)"
        case .copyFailed(let message):
            return "无法将素材包导出到用户目录：\(message)"
        }
    }
}

/// Moves the boundary between a sandboxed helper and a user-selected destination.
///
/// The helper writes only inside the app container. The main app, which owns the
/// security-scoped bookmark, exports the finished package after manifest generation.
public final class VideoPackageExporter: @unchecked Sendable {
    private let manager: FileManager

    public init(fileManager: FileManager = .default) {
        manager = fileManager
    }

    public func stagingDirectory(for jobID: UUID) -> URL {
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MediaFetch", isDirectory: true)
            .appendingPathComponent("Video Staging", isDirectory: true)
            .appendingPathComponent(jobID.uuidString, isDirectory: true)
        try? manager.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    public func export(packageDirectory: URL, to destination: URL) throws -> URL {
        guard packageDirectory.isFileURL,
              manager.fileExists(atPath: packageDirectory.path) else {
            throw VideoPackageExportError.packageUnavailable(packageDirectory.path)
        }
        guard destination.isFileURL else {
            throw VideoPackageExportError.destinationUnavailable(destination.path)
        }
        do {
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            throw VideoPackageExportError.destinationUnavailable(destination.path)
        }

        let target = availableDirectory(
            named: packageDirectory.lastPathComponent,
            in: destination
        )
        do {
            try manager.copyItem(at: packageDirectory, to: target)
        } catch {
            throw VideoPackageExportError.copyFailed(error.localizedDescription)
        }
        return target
    }

    public func regularFiles(in directory: URL) throws -> [URL] {
        let urls = try manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return urls.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func removeStagingDirectory(for jobID: UUID) {
        let directory = stagingDirectory(for: jobID)
        try? manager.removeItem(at: directory)
    }

    private func availableDirectory(named name: String, in destination: URL) -> URL {
        var candidate = destination.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while manager.fileExists(atPath: candidate.path) {
            candidate = destination.appendingPathComponent("\(name) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }
}
