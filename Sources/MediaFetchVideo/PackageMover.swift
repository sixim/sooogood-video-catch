import Foundation
import MediaFetchCore

public enum PackageMoveError: LocalizedError, Equatable {
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .verificationFailed(let file): return "复制后校验不一致（\(file)），原文件已保留"
        }
    }
}

/// Moves one package folder. Same volume: a rename. Across volumes: copy to a
/// hidden staging folder, verify every file (size, and SHA-256 against the
/// manifest), rename into place, and only then remove the original.
enum PackageMover {
    /// Returns true when the package was copied across volumes.
    @discardableResult
    static func move(package: URL, to destination: URL) throws -> Bool {
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        if sameVolume(package, parent) {
            try manager.moveItem(at: package, to: destination)
            return false
        }
        let staging = parent.appendingPathComponent(".sooogood-move-\(UUID().uuidString)", isDirectory: true)
        do {
            try manager.copyItem(at: package, to: staging)
            try verify(copy: staging, of: package)
            try manager.moveItem(at: staging, to: destination)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
        try manager.removeItem(at: package)
        return true
    }

    static func verify(copy: URL, of original: URL) throws {
        let expected = (try? Data(contentsOf: original.appendingPathComponent("manifest.json")))
            .map(PackageRelocation.expectedHashes(manifest:)) ?? [:]
        let base = original.standardizedFileURL.pathComponents.count
        guard let enumerator = FileManager.default.enumerator(at: original, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            throw PackageMoveError.verificationFailed(original.lastPathComponent)
        }
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let relative = file.standardizedFileURL.pathComponents.dropFirst(base).joined(separator: "/")
            let copied = copy.appendingPathComponent(relative)
            let copiedSize = try? copied.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard copiedSize == values.fileSize else { throw PackageMoveError.verificationFailed(relative) }
            if let hash = expected[relative], (try? ManifestWriter.sha256(copied)) != hash {
                throw PackageMoveError.verificationFailed(relative)
            }
        }
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let left = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject,
              let right = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject else { return false }
        return left.isEqual(right)
    }

    /// Removes folders left empty by a move (歌手/专辑), never `root` itself.
    static func removeEmptyParents(of directory: URL, stopAt root: URL) {
        let manager = FileManager.default
        let rootPath = root.standardizedFileURL.path
        var current = directory.standardizedFileURL
        while current.path.hasPrefix(rootPath + "/"), current.path != rootPath {
            let contents = (try? manager.contentsOfDirectory(atPath: current.path)) ?? ["?"]
            guard contents.allSatisfy({ $0 == ".DS_Store" }) else { return }
            try? manager.removeItem(at: current.appendingPathComponent(".DS_Store"))
            guard (try? manager.removeItem(at: current)) != nil else { return }
            current = current.deletingLastPathComponent()
        }
    }
}
