#if !MEDIAFETCH_STORE_PROFILE
import Foundation

enum TorrentDefaults {
    static var downloadDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: "MediaFetch.torrent.directory"),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }
}
#endif
