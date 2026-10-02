import Foundation

/// Whether NetEase Cloud Music can serve a track at all. Albums and playlists
/// list tracks the platform has no rights to (e.g. catalogues licensed
/// elsewhere); these never download, whatever the account. Read from the same
/// public song-detail endpoint the web player uses — metadata only, no cookies.
public enum NetEaseAvailability {
    public enum Status: Equatable, Sendable {
        case available
        case noRights
    }

    public static let noRightsMessage = "网易云没有这首歌的播放版权（无版权或已下架），换个平台试试"
    public static let noRightsBadge = "无版权"
    /// Ids per request; the endpoint accepts long lists, this keeps URLs short.
    public static let batchSize = 200

    public static func detailURL(ids: [String]) -> URL? {
        let list = ids.compactMap(Int.init).map { #"{"id":\#($0)}"# }.joined(separator: ",")
        var components = URLComponents(string: "https://music.163.com/api/v3/song/detail")
        components?.queryItems = [URLQueryItem(name: "c", value: "[\(list)]")]
        return components?.url
    }

    /// Anonymous answers mark VIP-only and region-limited tracks unplayable
    /// (`st < 0`) too, so `st` alone is not enough: a track counts as "no
    /// rights" only when even subscribers cannot play it (`subp == 0`) or the
    /// song carries `noCopyrightRcmd`. Checked live (2026-10-02): all 11 tracks
    /// of 叶惠美 have st -100 / subp 0; all 200 of the hot chart have subp 1 and
    /// download with a logged-in account. Unknown ids are left out.
    public static func parse(_ data: Data) -> [String: Status] {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [:] }
        var result: [String: Status] = [:]
        var blockedByRecommendation: Set<String> = []
        for song in json["songs"]?.arrayValue ?? [] {
            guard let id = song["id"]?.doubleValue.map({ String(Int($0)) }) else { continue }
            if let marker = song["noCopyrightRcmd"], marker != .null { blockedByRecommendation.insert(id) }
        }
        for privilege in json["privileges"]?.arrayValue ?? [] {
            guard let id = privilege["id"]?.doubleValue.map({ String(Int($0)) }),
                  let status = privilege["st"]?.doubleValue else { continue }
            let subscribersCanPlay = (privilege["subp"]?.doubleValue ?? 1) != 0
            let blocked = status < 0 && (!subscribersCanPlay || blockedByRecommendation.contains(id))
            result[id] = blocked ? .noRights : .available
        }
        return result
    }
}
