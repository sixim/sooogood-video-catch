#if !MEDIAFETCH_STORE_PROFILE
import Foundation
import MediaFetchTorrent

enum TorrentDefaults {
    static var downloadDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: "MediaFetch.torrent.directory"),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    static func dependencyItem() -> DependencyItem {
        let path = TransmissionDaemon.findExecutable()?.path
        return DependencyItem(
            id: "transmission", name: "Transmission", purpose: "Torrent 下载引擎",
            level: path == nil ? .missing : .ready,
            detail: path ?? "未安装，Torrent 功能不可用",
            command: "brew install transmission-cli"
        )
    }
}
#endif
