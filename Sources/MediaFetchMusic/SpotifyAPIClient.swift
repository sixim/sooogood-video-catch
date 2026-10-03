import Foundation
import MediaFetchCore

public struct SpotifyResourceReference: Equatable, Sendable {
    public let kind: SpotifyResourceKind
    public let id: String

    public init(kind: SpotifyResourceKind, id: String) {
        self.kind = kind
        self.id = id
    }

    public static func parse(_ url: URL) -> SpotifyResourceReference? {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "open.spotify.com" || host.hasSuffix(".open.spotify.com")
        else { return nil }

        let components = url.pathComponents.filter { $0 != "/" }
        guard let kindIndex = components.firstIndex(where: { SpotifyResourceKind(rawValue: $0) != nil }),
              components.indices.contains(kindIndex + 1),
              let kind = SpotifyResourceKind(rawValue: components[kindIndex])
        else { return nil }
        let id = components[kindIndex + 1]
        guard id.range(of: "^[A-Za-z0-9]{10,64}$", options: .regularExpression) != nil else { return nil }
        return SpotifyResourceReference(kind: kind, id: id)
    }
}

public enum SpotifyAPIError: LocalizedError {
    case invalidResourceURL
    case forbidden(String?)
    case rateLimited(retryAfter: TimeInterval?)
    case quotaExceeded
    case playlistAccessDenied(owner: String?)
    case reauthorizationRequired
    case response(status: Int, message: String?)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .invalidResourceURL:
            return String(localized: "请输入 Spotify 曲目、专辑或歌单链接。")
        case let .forbidden(message):
            let detail = message.map { "：\($0)" } ?? ""
            return String(localized: "Spotify 拒绝访问。请确认账号已加入 Developer App allowlist，且具备该内容权限\(detail)。")
        case let .rateLimited(retryAfter):
            if let retryAfter {
                return String(localized: "Spotify 请求过于频繁，请在 \(Int(ceil(retryAfter))) 秒后重试。")
            }
            return String(localized: "Spotify 请求过于频繁，请稍后重试。")
        case .quotaExceeded:
            return String(localized: "Spotify Developer App 的 API 配额已用完，请等待配额恢复或检查开发模式限制。")
        case let .playlistAccessDenied(owner):
            let suffix = owner.map { String(localized: "（所有者：\($0)）") } ?? ""
            return String(localized: "\(MediaFetchRelease.displayName) 只载入当前账号拥有或可协作的歌单\(suffix)。")
        case .reauthorizationRequired:
            return String(localized: "Spotify 授权已失效。请在设置中删除旧凭据后重新连接。")
        case let .response(status, message):
            let detail = message.map { "：\($0)" } ?? ""
            return String(localized: "Spotify API 返回错误 \(status)\(detail)。")
        case .malformedResponse:
            return String(localized: "Spotify 返回了无法识别的元数据。")
        }
    }
}

public protocol SpotifyMetadataCaching: Sendable {
    func data(forKey key: String, now: Date) async -> Data?
    func set(_ data: Data, forKey key: String, expiresAt: Date) async
    func clear() async
}

public actor MemorySpotifyMetadataCache: SpotifyMetadataCaching {
    private struct Entry: Sendable {
        let data: Data
        let expiresAt: Date
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public func data(forKey key: String, now: Date) -> Data? {
        guard let entry = entries[key] else { return nil }
        guard entry.expiresAt > now else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.data
    }

    public func set(_ data: Data, forKey key: String, expiresAt: Date) {
        entries[key] = Entry(data: data, expiresAt: expiresAt)
    }

    public func clear() {
        entries.removeAll(keepingCapacity: false)
    }
}

public actor SpotifyAPIClient {
    private let auth: any SpotifyAccessTokenProviding
    private let transport: any SpotifyHTTPTransport
    private let cache: any SpotifyMetadataCaching
    private let baseURL: URL
    private let cacheTTL: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        auth: any SpotifyAccessTokenProviding,
        transport: any SpotifyHTTPTransport = URLSessionSpotifyHTTPTransport(),
        cache: any SpotifyMetadataCaching = MemorySpotifyMetadataCache(),
        baseURL: URL = URL(string: "https://api.spotify.com/v1")!,
        cacheTTL: TimeInterval = 24 * 60 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.auth = auth
        self.transport = transport
        self.cache = cache
        self.baseURL = baseURL
        self.cacheTTL = min(max(cacheTTL, 0), 24 * 60 * 60)
        self.now = now
    }

    public func fetch(resourceURL: URL) async throws -> SpotifyCollection {
        guard let resource = SpotifyResourceReference.parse(resourceURL) else {
            throw SpotifyAPIError.invalidResourceURL
        }
        return try await fetch(resource: resource)
    }

    public func fetch(resource: SpotifyResourceReference) async throws -> SpotifyCollection {
        // A cache hit must not silently bypass the user's current connection state.
        _ = try await auth.validAccessToken()
        let cacheKey = "\(resource.kind.rawValue):\(resource.id)"
        if let cached = await cache.data(forKey: cacheKey, now: now()),
           let collection = try? JSONDecoder().decode(SpotifyCollection.self, from: cached) {
            return collection
        }

        let collection: SpotifyCollection
        switch resource.kind {
        case .track:
            collection = try await fetchTrack(id: resource.id)
        case .album:
            collection = try await fetchAlbum(id: resource.id)
        case .playlist:
            collection = try await fetchPlaylist(id: resource.id)
        }

        // Cache only the normalized model. Raw Spotify responses, preview URLs and cover bytes are never stored.
        if cacheTTL > 0, let encoded = try? JSONEncoder().encode(collection) {
            await cache.set(encoded, forKey: cacheKey, expiresAt: now().addingTimeInterval(cacheTTL))
        }
        return collection
    }

    public func disconnect() async throws {
        try await auth.disconnect()
        await cache.clear()
    }

    public func clearMetadataCache() async {
        await cache.clear()
    }

    private func fetchTrack(id: String) async throws -> SpotifyCollection {
        let data = try await get(path: "tracks/\(id)")
        let track = try decode(SpotifyTrackDTO.self, from: data)
        guard let reference = track.reference() else { throw SpotifyAPIError.malformedResponse }
        return SpotifyCollection(
            id: track.id ?? id,
            kind: .track,
            uri: track.uri ?? "spotify:track:\(id)",
            externalURL: track.externalURLs?.spotifyURL,
            title: track.name ?? reference.title,
            subtitle: reference.artists.joined(separator: ", "),
            coverURL: track.album?.images?.bestURL,
            tracks: [reference]
        )
    }

    private func fetchAlbum(id: String) async throws -> SpotifyCollection {
        let data = try await get(path: "albums/\(id)")
        let album = try decode(SpotifyAlbumDTO.self, from: data)
        var simplifiedTracks = album.tracks?.items ?? []
        var fetchedItemCount = simplifiedTracks.count
        let total = album.tracks?.total ?? simplifiedTracks.count

        while fetchedItemCount < total {
            let pageData = try await get(
                path: "albums/\(id)/tracks",
                queryItems: [
                    URLQueryItem(name: "limit", value: "50"),
                    URLQueryItem(name: "offset", value: String(fetchedItemCount))
                ]
            )
            let page = try decode(SpotifyPaging<SpotifySimplifiedTrackDTO>.self, from: pageData)
            guard !page.items.isEmpty else { break }
            simplifiedTracks.append(contentsOf: page.items)
            fetchedItemCount += page.items.count
        }

        let fullTracks = try await fetchFullTracks(ids: simplifiedTracks.compactMap(\.id))
        let fullByID = Dictionary(uniqueKeysWithValues: fullTracks.compactMap { track in
            track.id.map { ($0, track) }
        })
        let references = simplifiedTracks.compactMap { simplified -> SpotifyTrackReference? in
            if let id = simplified.id, let full = fullByID[id] {
                return full.reference(albumOverride: album.name)
            }
            return simplified.reference(album: album.name)
        }

        guard let albumID = album.id, let title = album.name else {
            throw SpotifyAPIError.malformedResponse
        }
        return SpotifyCollection(
            id: albumID,
            kind: .album,
            uri: album.uri ?? "spotify:album:\(id)",
            externalURL: album.externalURLs?.spotifyURL,
            title: title,
            subtitle: album.artists?.compactMap(\.name).joined(separator: ", "),
            coverURL: album.images?.bestURL,
            tracks: references
        )
    }

    private func fetchPlaylist(id: String) async throws -> SpotifyCollection {
        let playlistData = try await get(path: "playlists/\(id)")
        let playlist = try decode(SpotifyPlaylistDTO.self, from: playlistData)

        var offset = 0
        var tracks: [SpotifyTrackReference] = []
        while true {
            let pageData = try await get(
                path: "playlists/\(id)/items",
                queryItems: [
                    URLQueryItem(name: "limit", value: "50"),
                    URLQueryItem(name: "offset", value: String(offset))
                ]
            )
            let page = try decode(SpotifyPlaylistItemsPage.self, from: pageData)
            tracks.append(contentsOf: page.items.compactMap { ($0.item ?? $0.track)?.reference() })
            offset += page.items.count
            if page.items.isEmpty || offset >= page.total || page.next == nil { break }
        }

        guard let playlistID = playlist.id, let title = playlist.name else {
            throw SpotifyAPIError.malformedResponse
        }
        return SpotifyCollection(
            id: playlistID,
            kind: .playlist,
            uri: playlist.uri ?? "spotify:playlist:\(id)",
            externalURL: playlist.externalURLs?.spotifyURL,
            title: title,
            subtitle: playlist.owner?.displayName ?? playlist.owner?.id,
            coverURL: playlist.images?.bestURL,
            tracks: tracks
        )
    }

    private func fetchFullTracks(ids: [String]) async throws -> [SpotifyTrackDTO] {
        let uniqueIDs = Array(NSOrderedSet(array: ids)).compactMap { $0 as? String }
        var tracks: [SpotifyTrackDTO] = []
        // Spotify's February 2026 Web API migration removed GET /tracks?ids=.
        // Fetch one track at a time so album ISRC enrichment stays on supported endpoints
        // and does not create a burst that is hostile to development-mode quotas.
        for id in uniqueIDs {
            do {
                let data = try await get(path: "tracks/\(id)")
                tracks.append(try decode(SpotifyTrackDTO.self, from: data))
            } catch let error as SpotifyAPIError {
                if case .response(status: 404, message: _) = error {
                    // Keep the simplified album item in its original position when an
                    // individual track is deleted or unavailable in the user's region.
                    continue
                }
                throw error
            }
        }
        return tracks
    }

    private func get(
        path: String,
        queryItems: [URLQueryItem] = [],
        mayRefresh: Bool = true
    ) async throws -> Data {
        let token = try await auth.validAccessToken()
        let url = try makeURL(path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await transport.send(request)

        if response.statusCode == 401 {
            if mayRefresh {
                _ = try await auth.refreshAccessToken()
                return try await get(path: path, queryItems: queryItems, mayRefresh: false)
            }
            throw SpotifyAPIError.reauthorizationRequired
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.apiError(data: data, response: response)
        }
        return data
    }

    private func makeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw SpotifyAPIError.invalidResourceURL
        }
        let normalizedBase = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = normalizedBase + "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw SpotifyAPIError.invalidResourceURL }
        return url
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SpotifyAPIError.malformedResponse
        }
    }

    private static func apiError(data: Data, response: HTTPURLResponse) -> SpotifyAPIError {
        let message = errorMessage(from: data)
        switch response.statusCode {
        case 403:
            return .forbidden(message)
        case 429:
            let reason = response.value(forHTTPHeaderField: "X-RateLimit-Reason") ?? errorReason(from: data)
            if reason?.uppercased().contains("QUOTA_EXCEEDED") == true ||
                message?.uppercased().contains("QUOTA_EXCEEDED") == true {
                return .quotaExceeded
            }
            return .rateLimited(retryAfter: retryAfter(from: response))
        default:
            return .response(status: response.statusCode, message: message)
        }
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return object["message"] as? String
    }

    private static func errorReason(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any] {
            return error["reason"] as? String
        }
        return object["reason"] as? String
    }

    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value) { return max(seconds, 0) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value).map { max($0.timeIntervalSinceNow, 0) }
    }
}

private struct SpotifyExternalURLsDTO: Decodable {
    let spotify: String?
    var spotifyURL: URL? { spotify.flatMap(URL.init(string:)) }

    enum CodingKeys: String, CodingKey { case spotify }
}

private struct SpotifyImageDTO: Decodable {
    let url: String?
    let width: Int?
    let height: Int?
}

private extension Array where Element == SpotifyImageDTO {
    var bestURL: URL? {
        self.max { ($0.width ?? 0) * ($0.height ?? 0) < ($1.width ?? 0) * ($1.height ?? 0) }?
            .url.flatMap(URL.init(string:))
    }
}

private struct SpotifyArtistDTO: Decodable {
    let name: String?
}

private struct SpotifyAlbumSummaryDTO: Decodable {
    let name: String?
    let images: [SpotifyImageDTO]?
}

private struct SpotifyExternalIDsDTO: Decodable {
    let isrc: String?
}

private struct SpotifyTrackDTO: Decodable {
    let id: String?
    let uri: String?
    let name: String?
    let externalURLs: SpotifyExternalURLsDTO?
    let artists: [SpotifyArtistDTO]?
    let album: SpotifyAlbumSummaryDTO?
    let discNumber: Int?
    let trackNumber: Int?
    let durationMS: Int?
    let explicit: Bool?
    let externalIDs: SpotifyExternalIDsDTO?
    let type: String?
    let isLocal: Bool?

    enum CodingKeys: String, CodingKey {
        case id, uri, name, artists, album, type, explicit
        case externalURLs = "external_urls"
        case discNumber = "disc_number"
        case trackNumber = "track_number"
        case durationMS = "duration_ms"
        case externalIDs = "external_ids"
        case isLocal = "is_local"
    }

    func reference(albumOverride: String? = nil) -> SpotifyTrackReference? {
        guard type == nil || type == "track",
              isLocal != true,
              let id, let uri, let name, let durationMS
        else { return nil }
        return SpotifyTrackReference(
            id: id,
            uri: uri,
            externalURL: externalURLs?.spotifyURL,
            title: name,
            artists: artists?.compactMap(\.name) ?? [],
            album: albumOverride ?? album?.name,
            discNumber: discNumber ?? 1,
            trackNumber: trackNumber ?? 0,
            durationMS: durationMS,
            isExplicit: explicit,
            isrc: externalIDs?.isrc
        )
    }
}

private struct SpotifySimplifiedTrackDTO: Decodable {
    let id: String?
    let uri: String?
    let name: String?
    let externalURLs: SpotifyExternalURLsDTO?
    let artists: [SpotifyArtistDTO]?
    let discNumber: Int?
    let trackNumber: Int?
    let durationMS: Int?
    let explicit: Bool?
    let isLocal: Bool?

    enum CodingKeys: String, CodingKey {
        case id, uri, name, artists, explicit
        case externalURLs = "external_urls"
        case discNumber = "disc_number"
        case trackNumber = "track_number"
        case durationMS = "duration_ms"
        case isLocal = "is_local"
    }

    func reference(album: String?) -> SpotifyTrackReference? {
        guard isLocal != true, let id, let uri, let name, let durationMS else { return nil }
        return SpotifyTrackReference(
            id: id,
            uri: uri,
            externalURL: externalURLs?.spotifyURL,
            title: name,
            artists: artists?.compactMap(\.name) ?? [],
            album: album,
            discNumber: discNumber ?? 1,
            trackNumber: trackNumber ?? 0,
            durationMS: durationMS,
            isExplicit: explicit,
            isrc: nil
        )
    }
}

private struct SpotifyPaging<Item: Decodable>: Decodable {
    let items: [Item]
    let next: String?
    let total: Int
}

private struct SpotifyAlbumDTO: Decodable {
    let id: String?
    let uri: String?
    let name: String?
    let externalURLs: SpotifyExternalURLsDTO?
    let artists: [SpotifyArtistDTO]?
    let images: [SpotifyImageDTO]?
    let tracks: SpotifyPaging<SpotifySimplifiedTrackDTO>?

    enum CodingKeys: String, CodingKey {
        case id, uri, name, artists, images, tracks
        case externalURLs = "external_urls"
    }
}

private struct SpotifyOwnerDTO: Decodable {
    let id: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

private struct SpotifyPlaylistDTO: Decodable {
    let id: String?
    let uri: String?
    let name: String?
    let collaborative: Bool?
    let externalURLs: SpotifyExternalURLsDTO?
    let images: [SpotifyImageDTO]?
    let owner: SpotifyOwnerDTO?

    enum CodingKeys: String, CodingKey {
        case id, uri, name, collaborative, images, owner
        case externalURLs = "external_urls"
    }
}

private struct SpotifyPlaylistItemDTO: Decodable {
    let item: SpotifyTrackDTO?
    let track: SpotifyTrackDTO?
}

private struct SpotifyPlaylistItemsPage: Decodable {
    let items: [SpotifyPlaylistItemDTO]
    let next: String?
    let total: Int
}

private struct SpotifyCurrentUserDTO: Decodable {
    let id: String
}
