import Foundation
import XCTest
@testable import MediaFetch
@testable import MediaFetchCore
@testable import MediaFetchMusic

final class SpotifyAuthAPITests: XCTestCase {
    func testPKCEChallengeMatchesRFC7636Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(
            SpotifyAuthClient.pkceChallenge(for: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testAuthorizationURLUsesOnlyApprovedScopes() async throws {
        let client = makeAuthClient()
        let url = try await client.makeAuthorizationURL(
            redirectURI: URL(string: "http://127.0.0.1:54321/oauth/spotify/callback")!,
            codeVerifier: "verifier",
            state: "state-value"
        )
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(values["client_id"], "client-id")
        XCTAssertEqual(values["response_type"], "code")
        XCTAssertEqual(values["code_challenge_method"], "S256")
        XCTAssertEqual(values["state"], "state-value")
        XCTAssertEqual(
            Set(values["scope"]?.split(separator: " ").map(String.init) ?? []),
            Set(["playlist-read-private", "playlist-read-collaborative"])
        )
        XCTAssertNil(values["client_secret"])
    }

    func testConnectExchangesCodeWithoutClientSecretAndDisconnectsFakeCredentials() async throws {
        let store = TestSpotifyCredentialStore()
        let transport = TestSpotifyTransport(routes: [
            "/api/token": [
                .json(200, """
                {
                  "access_token":"access-1",
                  "token_type":"Bearer",
                  "expires_in":3600,
                  "refresh_token":"refresh-1",
                  "scope":"playlist-read-private playlist-read-collaborative"
                }
                """)
            ]
        ])
        let browser = TestSpotifyBrowser()
        let redirect = URL(string: "http://127.0.0.1:54321/oauth/spotify/callback")!
        let callback = URL(string: "http://127.0.0.1:54321/oauth/spotify/callback?code=auth-code&state=fixed-state")!
        let loopback = TestSpotifyLoopback(redirect: redirect, callback: callback)
        let client = SpotifyAuthClient(
            configuration: SpotifyOAuthConfiguration(
                clientID: "client-id",
                authorizationEndpoint: URL(string: "https://accounts.example/authorize")!,
                tokenEndpoint: URL(string: "https://accounts.example/api/token")!
            ),
            credentials: store,
            transport: transport,
            browser: browser,
            random: FixedSpotifyRandom(),
            loopbackFactory: { loopback },
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        let result = try await client.connect()
        XCTAssertEqual(result.accessToken, "access-1")
        XCTAssertEqual(store.currentToken()?.refreshToken, "refresh-1")

        let requests = await transport.recordedRequests()
        let body = String(data: try XCTUnwrap(requests.first?.httpBody), encoding: .utf8)
        XCTAssertTrue(body?.contains("grant_type=authorization_code") == true)
        XCTAssertTrue(body?.contains("code_verifier=fixed-verifier") == true)
        XCTAssertTrue(body?.contains("client_id=client-id") == true)
        XCTAssertFalse(body?.contains("client_secret") == true)
        let openedURL = await browser.lastOpenedURL()
        XCTAssertEqual(openedURL?.host, "accounts.example")
        let stopped = await loopback.wasStopped()
        XCTAssertTrue(stopped)

        try await client.disconnect()
        XCTAssertNil(store.currentToken())
    }

    func testRefreshRetainsRotatingRefreshTokenFallback() async throws {
        let store = TestSpotifyCredentialStore(token: SpotifyTokenSet(
            accessToken: "expired",
            refreshToken: "refresh-old",
            tokenType: "Bearer",
            scopes: SpotifyOAuthConfiguration.allowedScopes,
            expiresAt: Date(timeIntervalSince1970: 900)
        ))
        let transport = TestSpotifyTransport(routes: [
            "/api/token": [.json(200, """
                {"access_token":"access-new","token_type":"Bearer","expires_in":3600}
                """)]
        ])
        let client = SpotifyAuthClient(
            configuration: SpotifyOAuthConfiguration(
                clientID: "client-id",
                tokenEndpoint: URL(string: "https://accounts.example/api/token")!
            ),
            credentials: store,
            transport: transport,
            browser: TestSpotifyBrowser(),
            random: FixedSpotifyRandom(),
            loopbackFactory: {
                TestSpotifyLoopback(
                    redirect: URL(string: "http://127.0.0.1:1/callback")!,
                    callback: URL(string: "http://127.0.0.1:1/callback")!
                )
            },
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        let accessToken = try await client.validAccessToken()
        XCTAssertEqual(accessToken, "access-new")
        XCTAssertEqual(store.currentToken()?.refreshToken, "refresh-old")
        let requests = await transport.recordedRequests()
        let body = String(data: try XCTUnwrap(requests.first?.httpBody), encoding: .utf8)
        XCTAssertTrue(body?.contains("grant_type=refresh_token") == true)
        XCTAssertTrue(body?.contains("refresh_token=refresh-old") == true)
        XCTAssertFalse(body?.contains("client_secret") == true)
    }

    func testCallbackRejectsMismatchedState() {
        let callback = URL(string: "http://127.0.0.1:1234/callback?code=abc&state=wrong")!
        XCTAssertThrowsError(try SpotifyAuthClient.authorizationCode(from: callback, expectedState: "expected")) { error in
            guard case SpotifyAuthError.stateMismatch = error else {
                return XCTFail("Expected stateMismatch, got \(error)")
            }
        }
    }

    func testCallbackReportsUserDeniedAuthorization() {
        let callback = URL(string: "http://127.0.0.1:1234/callback?error=access_denied&state=expected")!
        XCTAssertThrowsError(try SpotifyAuthClient.authorizationCode(from: callback, expectedState: "expected")) { error in
            guard case let SpotifyAuthError.callbackRejected(message) = error else {
                return XCTFail("Expected callbackRejected, got \(error)")
            }
            XCTAssertEqual(message, "access_denied")
        }
    }

    func testCallbackDuplicateStateCannotCrashOrOverrideFirstValue() {
        let callback = URL(string: "http://127.0.0.1:1234/callback?code=abc&state=wrong&state=expected")!
        XCTAssertThrowsError(try SpotifyAuthClient.authorizationCode(from: callback, expectedState: "expected")) { error in
            guard case SpotifyAuthError.stateMismatch = error else {
                return XCTFail("Expected stateMismatch, got \(error)")
            }
        }

        let reversed = URL(string: "http://127.0.0.1:1234/callback?code=abc&state=expected&state=wrong")!
        XCTAssertThrowsError(try SpotifyAuthClient.authorizationCode(from: reversed, expectedState: "expected")) { error in
            guard case SpotifyAuthError.stateMismatch = error else {
                return XCTFail("Expected stateMismatch for any duplicate state, got \(error)")
            }
        }
    }

    func testRealLoopbackListenerUsesDynamicIPv4LoopbackPort() async throws {
        let listener = SpotifyLoopbackHTTPListener(callbackPath: "/test/callback")
        let redirect = try await listener.start()
        XCTAssertEqual(redirect.scheme, "http")
        XCTAssertEqual(redirect.host, "127.0.0.1")
        XCTAssertNotNil(redirect.port)
        XCTAssertNotEqual(redirect.port, 0)
        XCTAssertEqual(redirect.path, "/test/callback")
        await listener.stop()
    }

    func testResourceParserRejectsLookalikeHostAndAcceptsLocalizedSpotifyURL() {
        XCTAssertNil(SpotifyResourceReference.parse(
            URL(string: "https://open.spotify.com.evil.example/track/1234567890")!
        ))
        XCTAssertEqual(
            SpotifyResourceReference.parse(
                URL(string: "https://open.spotify.com/intl-de/album/1234567890?si=test")!
            ),
            SpotifyResourceReference(kind: .album, id: "1234567890")
        )
    }

    func testAlbumUses2026SingleTrackEndpointAndRefreshes401OnlyOnce() async throws {
        let token = TestSpotifyTokenProvider()
        let albumID = "album123456"
        let trackID = "track123456"
        let transport = TestSpotifyTransport(routes: [
            "/v1/albums/\(albumID)": [.json(200, albumJSON(albumID: albumID, trackID: trackID))],
            "/v1/tracks/\(trackID)": [
                .json(401, #"{"error":{"status":401,"message":"expired"}}"#),
                .json(200, trackJSON(trackID: trackID))
            ]
        ])
        let api = SpotifyAPIClient(
            auth: token,
            transport: transport,
            baseURL: URL(string: "https://api.example/v1")!
        )

        let collection = try await api.fetch(resource: SpotifyResourceReference(kind: .album, id: albumID))
        XCTAssertEqual(collection.kind, .album)
        XCTAssertEqual(collection.tracks.first?.isrc, "USAAA2600001")
        let refreshCount = await token.refreshCount()
        XCTAssertEqual(refreshCount, 1)

        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.contains { $0.url?.path == "/v1/tracks/\(trackID)" })
        XCTAssertFalse(requests.contains {
            $0.url?.path == "/v1/tracks" &&
                URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "ids" }) == true
        })
    }

    func testAlbumKeepsSimplifiedTrackWhenSingleEnrichmentIsUnavailable() async throws {
        let albumID = "album-unavailable"
        let availableID = "track-available"
        let unavailableID = "track-unavailable"
        let album = """
        {
          "id":"\(albumID)","uri":"spotify:album:\(albumID)","name":"Test Album",
          "artists":[{"name":"Artist"}],"images":[],
          "tracks":{"items":[
            {"id":"\(availableID)","uri":"spotify:track:\(availableID)","name":"Available","artists":[{"name":"Artist"}],"disc_number":1,"track_number":1,"duration_ms":180000,"explicit":false,"is_local":false},
            {"id":"\(unavailableID)","uri":"spotify:track:\(unavailableID)","name":"Unavailable","artists":[{"name":"Artist"}],"disc_number":1,"track_number":2,"duration_ms":181000,"explicit":true,"is_local":false}
          ],"next":null,"total":2}
        }
        """
        let transport = TestSpotifyTransport(routes: [
            "/v1/albums/\(albumID)": [.json(200, album)],
            "/v1/tracks/\(availableID)": [.json(200, trackJSON(trackID: availableID))],
            "/v1/tracks/\(unavailableID)": [.json(404, #"{"error":{"status":404,"message":"Not available"}}"#)]
        ])
        let api = SpotifyAPIClient(
            auth: TestSpotifyTokenProvider(),
            transport: transport,
            baseURL: URL(string: "https://api.example/v1")!
        )

        let result = try await api.fetch(resource: SpotifyResourceReference(kind: .album, id: albumID))

        XCTAssertEqual(result.tracks.map(\.id), [availableID, unavailableID])
        XCTAssertNil(result.tracks[1].isrc)
        XCTAssertEqual(result.tracks[1].isExplicit, true)
        XCTAssertEqual(result.tracks[1].trackNumber, 2)
    }

    func testSecondUnauthorizedResponseRequiresReauthorization() async throws {
        let token = TestSpotifyTokenProvider()
        let trackID = "track-reauthorize"
        let transport = TestSpotifyTransport(routes: [
            "/v1/tracks/\(trackID)": [
                .json(401, #"{"error":{"status":401,"message":"expired"}}"#),
                .json(401, #"{"error":{"status":401,"message":"revoked"}}"#)
            ]
        ])
        let api = SpotifyAPIClient(
            auth: token,
            transport: transport,
            baseURL: URL(string: "https://api.example/v1")!
        )

        do {
            _ = try await api.fetch(resource: SpotifyResourceReference(kind: .track, id: trackID))
            XCTFail("Expected reauthorizationRequired")
        } catch let error as SpotifyAPIError {
            guard case .reauthorizationRequired = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let refreshCount = await token.refreshCount()
        XCTAssertEqual(refreshCount, 1)
    }

    func testPlaylistUsesItemsEndpointWithoutRequestingProfileScope() async throws {
        let token = TestSpotifyTokenProvider()
        let playlistID = "playlist12345"
        let trackID = "track123456"
        let transport = TestSpotifyTransport(routes: [
            "/v1/playlists/\(playlistID)": [.json(200, """
                {
                  "id":"\(playlistID)","uri":"spotify:playlist:\(playlistID)","name":"My List",
                  "collaborative":false,"owner":{"id":"me","display_name":"Me"},
                  "external_urls":{"spotify":"https://open.spotify.com/playlist/\(playlistID)"},"images":[]
                }
                """)],
            "/v1/playlists/\(playlistID)/items": [.json(200, """
                {"items":[{"item":\(trackJSON(trackID: trackID))}],"next":null,"total":1}
                """)]
        ])
        let api = SpotifyAPIClient(
            auth: token,
            transport: transport,
            baseURL: URL(string: "https://api.example/v1")!
        )

        let result = try await api.fetch(resource: SpotifyResourceReference(kind: .playlist, id: playlistID))
        XCTAssertEqual(result.tracks.map(\.id), [trackID])
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.contains { $0.url?.path == "/v1/playlists/\(playlistID)/items" })
        XCTAssertFalse(requests.contains { $0.url?.path == "/v1/me" })
    }

    func testPlaylistItemsPaginationSkipsDeletedEntriesAndPreservesOrder() async throws {
        let playlistID = "playlist-pages"
        let firstID = "track-page-one"
        let secondID = "track-page-two"
        let transport = TestSpotifyTransport(routes: [
            "/v1/playlists/\(playlistID)": [.json(200, """
                {"id":"\(playlistID)","uri":"spotify:playlist:\(playlistID)","name":"Paged List",
                 "owner":{"id":"me","display_name":"Me"},"images":[]}
                """)],
            "/v1/playlists/\(playlistID)/items": [
                .json(200, """
                    {"items":[{"item":\(trackJSON(trackID: firstID))},{"item":null}],
                     "next":"https://api.example/v1/playlists/\(playlistID)/items?offset=2","total":3}
                    """),
                .json(200, """
                    {"items":[{"item":\(trackJSON(trackID: secondID))}],"next":null,"total":3}
                    """)
            ]
        ])
        let api = SpotifyAPIClient(
            auth: TestSpotifyTokenProvider(),
            transport: transport,
            baseURL: URL(string: "https://api.example/v1")!
        )

        let result = try await api.fetch(resource: SpotifyResourceReference(kind: .playlist, id: playlistID))

        XCTAssertEqual(result.tracks.map(\.id), [firstID, secondID])
        let requests = await transport.recordedRequests()
        let itemRequests = requests.filter {
            $0.url?.path == "/v1/playlists/\(playlistID)/items"
        }
        XCTAssertEqual(itemRequests.count, 2)
        let offsets = itemRequests.compactMap { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "offset" })?.value
        }
        XCTAssertEqual(offsets, ["0", "2"])
    }

    func testPlaylistItemsEndpointEnforcesOwnerOrCollaboratorAccess() async throws {
        let playlistID = "playlist12345"
        let transport = TestSpotifyTransport(routes: [
            "/v1/playlists/\(playlistID)": [.json(200, """
                {"id":"\(playlistID)","uri":"spotify:playlist:\(playlistID)","name":"Other",
                 "collaborative":false,"owner":{"id":"someone-else","display_name":"Other User"},"images":[]}
                """)],
            "/v1/playlists/\(playlistID)/items": [
                .json(403, #"{"error":{"status":403,"message":"Not owner or collaborator"}}"#)
            ]
        ])
        let api = SpotifyAPIClient(
            auth: TestSpotifyTokenProvider(),
            transport: transport,
            baseURL: URL(string: "https://api.example/v1")!
        )

        do {
            _ = try await api.fetch(resource: SpotifyResourceReference(kind: .playlist, id: playlistID))
            XCTFail("Expected forbidden")
        } catch let error as SpotifyAPIError {
            guard case let .forbidden(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "Not owner or collaborator")
        }

        let requests = await transport.recordedRequests()
        XCTAssertFalse(requests.contains { $0.url?.path == "/v1/me" })
    }

    func test403And429HaveActionableErrors() async throws {
        let forbiddenTransport = TestSpotifyTransport(routes: [
            "/v1/tracks/track123456": [.json(403, #"{"error":{"status":403,"message":"User not registered"}}"#)]
        ])
        let forbiddenAPI = SpotifyAPIClient(
            auth: TestSpotifyTokenProvider(),
            transport: forbiddenTransport,
            baseURL: URL(string: "https://api.example/v1")!
        )
        do {
            _ = try await forbiddenAPI.fetch(resource: SpotifyResourceReference(kind: .track, id: "track123456"))
            XCTFail("Expected forbidden")
        } catch let error as SpotifyAPIError {
            guard case .forbidden = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(error.localizedDescription.contains("allowlist"))
        }

        let limitedTransport = TestSpotifyTransport(routes: [
            "/v1/tracks/track123456": [.json(429, #"{"error":{"status":429,"message":"slow down"}}"#, headers: ["Retry-After": "12"])]
        ])
        let limitedAPI = SpotifyAPIClient(
            auth: TestSpotifyTokenProvider(),
            transport: limitedTransport,
            baseURL: URL(string: "https://api.example/v1")!
        )
        do {
            _ = try await limitedAPI.fetch(resource: SpotifyResourceReference(kind: .track, id: "track123456"))
            XCTFail("Expected rate limit")
        } catch let error as SpotifyAPIError {
            guard case let .rateLimited(retryAfter) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(retryAfter, 12)
        }
    }

    func testQuotaExceededHasDedicatedError() async throws {
        let transport = TestSpotifyTransport(routes: [
            "/v1/tracks/track123456": [
                .json(429, #"{"error":{"status":429,"message":"quota exhausted","reason":"QUOTA_EXCEEDED"}}"#)
            ]
        ])
        let api = SpotifyAPIClient(
            auth: TestSpotifyTokenProvider(),
            transport: transport,
            baseURL: URL(string: "https://api.example/v1")!
        )

        do {
            _ = try await api.fetch(resource: SpotifyResourceReference(kind: .track, id: "track123456"))
            XCTFail("Expected quotaExceeded")
        } catch let error as SpotifyAPIError {
            guard case .quotaExceeded = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(error.localizedDescription.contains("配额"))
        }
    }

    func testCacheTTLIsCappedAt24HoursAndStoresOnlyNormalizedMetadata() async throws {
        let fixedNow = Date(timeIntervalSince1970: 10_000)
        let cache = TestSpotifyMetadataCache()
        let token = TestSpotifyTokenProvider()
        let transport = TestSpotifyTransport(routes: [
            "/v1/tracks/track123456": [.json(200, trackJSON(trackID: "track123456", includePreview: true))]
        ])
        let api = SpotifyAPIClient(
            auth: token,
            transport: transport,
            cache: cache,
            baseURL: URL(string: "https://api.example/v1")!,
            cacheTTL: 10 * 24 * 60 * 60,
            now: { fixedNow }
        )

        _ = try await api.fetch(resource: SpotifyResourceReference(kind: .track, id: "track123456"))
        let snapshot = await cache.snapshot()
        XCTAssertEqual(snapshot.expiresAt?.timeIntervalSince(fixedNow), 24 * 60 * 60)
        XCTAssertFalse(String(data: snapshot.data ?? Data(), encoding: .utf8)?.contains("preview_url") == true)
        XCTAssertFalse(String(data: snapshot.data ?? Data(), encoding: .utf8)?.contains("preview.example") == true)

        try await api.disconnect()
        let disconnected = await token.wasDisconnected()
        let cleared = await cache.wasCleared()
        XCTAssertTrue(disconnected)
        XCTAssertTrue(cleared)
    }

    private func makeAuthClient() -> SpotifyAuthClient {
        SpotifyAuthClient(
            configuration: SpotifyOAuthConfiguration(clientID: "client-id"),
            credentials: TestSpotifyCredentialStore(),
            transport: TestSpotifyTransport(routes: [:]),
            browser: TestSpotifyBrowser(),
            random: FixedSpotifyRandom(),
            loopbackFactory: {
                TestSpotifyLoopback(
                    redirect: URL(string: "http://127.0.0.1:1/callback")!,
                    callback: URL(string: "http://127.0.0.1:1/callback")!
                )
            }
        )
    }

    private func albumJSON(albumID: String, trackID: String) -> String {
        """
        {
          "id":"\(albumID)","uri":"spotify:album:\(albumID)","name":"Test Album",
          "artists":[{"name":"Artist"}],"images":[{"url":"https://images.example/album.jpg","width":640,"height":640}],
          "external_urls":{"spotify":"https://open.spotify.com/album/\(albumID)"},
          "tracks":{"items":[{
            "id":"\(trackID)","uri":"spotify:track:\(trackID)","name":"Song","artists":[{"name":"Artist"}],
            "disc_number":1,"track_number":1,"duration_ms":180000,"is_local":false,
            "external_urls":{"spotify":"https://open.spotify.com/track/\(trackID)"}
          }],"next":null,"total":1}
        }
        """
    }

    private func trackJSON(trackID: String, includePreview: Bool = false) -> String {
        let preview = includePreview ? #", "preview_url":"https://preview.example/file.mp3""# : ""
        return """
        {
          "id":"\(trackID)","uri":"spotify:track:\(trackID)","name":"Song","type":"track","is_local":false,
          "artists":[{"name":"Artist"}],"album":{"name":"Test Album","images":[{"url":"https://images.example/album.jpg","width":640,"height":640}]},
          "disc_number":1,"track_number":1,"duration_ms":180000,"external_ids":{"isrc":"USAAA2600001"},
          "external_urls":{"spotify":"https://open.spotify.com/track/\(trackID)"}\(preview)
        }
        """
    }
}

private final class TestSpotifyCredentialStore: SpotifyCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: SpotifyTokenSet?

    init(token: SpotifyTokenSet? = nil) {
        self.token = token
    }

    func load() throws -> SpotifyTokenSet? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    func save(_ tokenSet: SpotifyTokenSet) throws {
        lock.lock()
        token = tokenSet
        lock.unlock()
    }

    func delete() throws {
        lock.lock()
        token = nil
        lock.unlock()
    }

    func currentToken() -> SpotifyTokenSet? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }
}

private struct FixedSpotifyRandom: SpotifyOAuthRandomGenerating {
    func codeVerifier() throws -> String { "fixed-verifier" }
    func state() throws -> String { "fixed-state" }
}

private actor TestSpotifyBrowser: SpotifyBrowserOpening {
    private var openedURL: URL?
    func open(_ url: URL) async throws { openedURL = url }
    func lastOpenedURL() -> URL? { openedURL }
}

private actor TestSpotifyLoopback: SpotifyLoopbackListening {
    private let redirect: URL
    private let callback: URL
    private var stopped = false

    init(redirect: URL, callback: URL) {
        self.redirect = redirect
        self.callback = callback
    }

    func start() async throws -> URL { redirect }
    func waitForCallback(timeout: TimeInterval) async throws -> URL { callback }
    func stop() async { stopped = true }
    func wasStopped() -> Bool { stopped }
}

private struct TestSpotifyResponse: Sendable {
    let status: Int
    let data: Data
    let headers: [String: String]

    static func json(_ status: Int, _ json: String, headers: [String: String] = [:]) -> TestSpotifyResponse {
        TestSpotifyResponse(status: status, data: Data(json.utf8), headers: headers)
    }
}

private actor TestSpotifyTransport: SpotifyHTTPTransport {
    private var routes: [String: [TestSpotifyResponse]]
    private var requests: [URLRequest] = []

    init(routes: [String: [TestSpotifyResponse]]) {
        self.routes = routes
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url?.path ?? ""
        guard var responses = routes[path], !responses.isEmpty else {
            throw URLError(.resourceUnavailable)
        }
        let response = responses.removeFirst()
        routes[path] = responses
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        return (response.data, http)
    }

    func recordedRequests() -> [URLRequest] { requests }
}

private actor TestSpotifyTokenProvider: SpotifyAccessTokenProviding {
    private var token = "old-token"
    private var refreshes = 0
    private var disconnected = false

    func validAccessToken() async throws -> String { token }
    func refreshAccessToken() async throws -> String {
        refreshes += 1
        token = "new-token"
        return token
    }
    func disconnect() async throws { disconnected = true }
    func refreshCount() -> Int { refreshes }
    func wasDisconnected() -> Bool { disconnected }
}

private actor TestSpotifyMetadataCache: SpotifyMetadataCaching {
    private var data: Data?
    private var expiresAt: Date?
    private var cleared = false

    func data(forKey key: String, now: Date) -> Data? { nil }
    func set(_ data: Data, forKey key: String, expiresAt: Date) {
        self.data = data
        self.expiresAt = expiresAt
    }
    func clear() {
        data = nil
        expiresAt = nil
        cleared = true
    }
    func snapshot() -> (data: Data?, expiresAt: Date?) { (data, expiresAt) }
    func wasCleared() -> Bool { cleared }
}
