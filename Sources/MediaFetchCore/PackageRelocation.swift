import Foundation

/// Planning for "移动到…": moving finished packages (audio/video, cover,
/// lyrics, manifest) to another folder. Pure decisions live here; the file
/// operations are in `PackageMover`.
public enum PackageRelocation {
    public enum Skip: Equatable, Sendable {
        case notFinished
        case missingPackage
        case alreadyThere
        case targetExists(String)
        case partOfCollection

        public var message: String {
            switch self {
            case .notFinished: return String(localized: "任务还没完成")
            case .missingPackage: return String(localized: "原文件夹已不存在")
            case .alreadyThere: return String(localized: "已经在目标文件夹里")
            case .targetExists(let path): return String(localized: "目标位置已有同名文件夹，未覆盖：\(path)")
            case .partOfCollection: return String(localized: "属于课程 / 歌单合集，请整体移动合集文件夹")
            }
        }
    }

    /// Where a package lands: it keeps its path relative to the download
    /// folder it was saved into (歌手/专辑/素材包); a package outside that
    /// folder keeps only its own folder name.
    public static func destination(for package: URL, downloadRoot: URL, target: URL) -> URL {
        let packagePath = package.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let rootPath = downloadRoot.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var result = target
        if packagePath.count > rootPath.count, Array(packagePath.prefix(rootPath.count)) == rootPath {
            for component in packagePath.dropFirst(rootPath.count) { result.appendPathComponent(component, isDirectory: true) }
        } else {
            result.appendPathComponent(package.lastPathComponent, isDirectory: true)
        }
        return result
    }

    /// `relativePath → sha256` from a package manifest, used to verify a copy
    /// before the original is removed.
    public static func expectedHashes(manifest data: Data) -> [String: String] {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [:] }
        var result: [String: String] = [:]
        for file in json["files"]?.arrayValue ?? [] {
            if let path = file["relativePath"]?.stringValue, let hash = file["sha256"]?.stringValue { result[path] = hash }
        }
        return result
    }

    /// Rewrites recorded file paths after a move.
    public static func rebase(_ paths: [String], from old: URL, to new: URL) -> [String] {
        let prefix = old.path.hasSuffix("/") ? old.path : old.path + "/"
        return paths.map { $0.hasPrefix(prefix) ? new.appendingPathComponent(String($0.dropFirst(prefix.count))).path : $0 }
    }

    /// Packages already imported into DaVinci Resolve go offline there once moved.
    public static func wasSentToResolve(_ package: URL) -> Bool {
        FileManager.default.fileExists(atPath: package.appendingPathComponent("resolve-imports.json").path)
    }
}
