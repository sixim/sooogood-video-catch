import Foundation

/// A NetEase Cloud Music or QQ Music link, normalized to the URL form yt-dlp's
/// extractors accept. Share links come in many shapes (hash routes, mobile
/// pages, legacy paths); everything is mapped to one canonical URL.
public struct MusicLink: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case song, album, playlist, artist, toplist, radio, program, mv

        /// Kinds that expand into several tracks.
        public var isCollection: Bool { ![.song, .program, .mv].contains(self) }
    }

    public let platform: StreamingPlatform
    public let kind: Kind
    public let id: String
    public let canonicalURL: URL

    public static func parse(_ url: URL) -> MusicLink? {
        switch StreamingPlatform.detect(url) {
        case .netease: return parseNetEase(url)
        case .qqmusic: return parseQQ(url)
        default: return nil
        }
    }

    /// Short links that only reveal the real target after an HTTP redirect.
    public static func needsRedirectResolution(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        if host == "163cn.tv" || host.hasSuffix(".163cn.tv") { return true }
        if host == "c.y.qq.com" || host == "c6.y.qq.com" { return url.path.contains("/base/fcgi-bin/u") }
        return false
    }

    /// Canonical form if this is a recognized music link, otherwise the input unchanged.
    public static func canonicalize(_ url: URL) -> URL {
        parse(url)?.canonicalURL ?? url
    }

    // MARK: NetEase

    static func parseNetEase(_ url: URL) -> MusicLink? {
        let host = url.host?.lowercased() ?? ""
        guard host == "music.163.com" || host == "y.music.163.com" else { return nil }
        // Routes live either in the path or in the hash fragment (`/#/song?id=1`).
        var route = url.path
        var query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let fragment = url.fragment, fragment.hasPrefix("/"),
           let inner = URLComponents(string: "https://x" + fragment) {
            route = inner.path
            query = (inner.queryItems ?? []) + query
        }
        var parts = route.split(separator: "/").map { String($0).lowercased() }
        if parts.first == "m" || parts.first == "#" { parts.removeFirst() }
        if parts.starts(with: ["my", "m", "music"]) { parts.removeFirst(3) }
        guard let id = query.first(where: { $0.name == "id" })?.value, isDigits(id) else { return nil }
        let base = "https://music.163.com/"
        func link(_ kind: Kind, _ path: String) -> MusicLink {
            MusicLink(platform: .netease, kind: kind, id: id, canonicalURL: URL(string: "\(base)\(path)?id=\(id)")!)
        }
        switch parts.joined(separator: "/") {
        case "song": return link(.song, "song")
        case "album": return link(.album, "album")
        case "artist": return link(.artist, "artist")
        case "playlist": return link(.playlist, "playlist")
        case "discover/toplist": return link(.toplist, "discover/toplist")
        case "djradio": return link(.radio, "djradio")
        case "program", "dj": return link(.program, "program")
        case "mv": return link(.mv, "mv")
        default: return nil
        }
    }

    // MARK: QQ Music

    static func parseQQ(_ url: URL) -> MusicLink? {
        let host = url.host?.lowercased() ?? ""
        let parts = url.path.split(separator: "/").map(String.init)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name.lowercased() == name.lowercased() }?.value }
        func link(_ kind: Kind, _ segment: String, _ id: String?) -> MusicLink? {
            guard let id, !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber }), id.allSatisfy(\.isASCII) else { return nil }
            if [.playlist, .toplist].contains(kind) && !isDigits(id) { return nil }
            return MusicLink(platform: .qqmusic, kind: kind, id: id,
                             canonicalURL: URL(string: "https://y.qq.com/n/ryqq/\(segment)/\(id)")!)
        }
        if host == "y.qq.com" {
            // Desktop: /n/ryqq/<type>/<id>
            if parts.count >= 4, parts[0] == "n", parts[1] == "ryqq" {
                switch parts[2] {
                case "songDetail": return link(.song, "songDetail", parts[3])
                case "albumDetail": return link(.album, "albumDetail", parts[3])
                case "playlist": return link(.playlist, "playlist", parts[3])
                case "singer": return link(.artist, "singer", parts[3])
                case "toplist": return link(.toplist, "toplist", parts[3])
                case "mv": return link(.mv, "mv", parts[3])
                default: return nil
                }
            }
            // Legacy: /n/yqq/song/<mid>.html
            if parts.count >= 4, parts[0] == "n", parts[1] == "yqq" {
                let id = (parts[3] as NSString).deletingPathExtension
                switch parts[2] {
                case "song": return link(.song, "songDetail", id)
                case "album": return link(.album, "albumDetail", id)
                case "playlist": return link(.playlist, "playlist", id)
                case "singer": return link(.artist, "singer", id)
                default: return nil
                }
            }
        }
        // Mobile share pages (i.y.qq.com and similar).
        let page = (parts.last ?? "").lowercased()
        if page == "playsong.html" || page == "songdetail.html" { return link(.song, "songDetail", value("songmid") ?? value("songMid")) }
        if page == "album.html" { return link(.album, "albumDetail", value("albummid") ?? value("albumMid")) }
        if page == "taoge.html" || page == "playlist.html" { return link(.playlist, "playlist", value("id")) }
        if page == "singer.html" { return link(.artist, "singer", value("singermid") ?? value("singerMid")) }
        if page == "toplist.html" { return link(.toplist, "toplist", value("id")) }
        return nil
    }

    static func isDigits(_ text: String) -> Bool { !text.isEmpty && text.allSatisfy(\.isASCII) && text.allSatisfy(\.isNumber) }
}
