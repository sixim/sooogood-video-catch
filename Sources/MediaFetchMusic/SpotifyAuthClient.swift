import AppKit
import CryptoKit
import Foundation
import Network
import Security
import MediaFetchCore

public struct SpotifyOAuthConfiguration: Sendable {
    public static let allowedScopes = [
        "playlist-read-private",
        "playlist-read-collaborative"
    ]

    public let clientID: String
    public var authorizationEndpoint = URL(string: "https://accounts.spotify.com/authorize")!
    public var tokenEndpoint = URL(string: "https://accounts.spotify.com/api/token")!
    public var callbackPath = "/oauth/spotify/callback"
    public var callbackTimeout: TimeInterval = 180

    public init(
        clientID: String,
        authorizationEndpoint: URL = URL(string: "https://accounts.spotify.com/authorize")!,
        tokenEndpoint: URL = URL(string: "https://accounts.spotify.com/api/token")!,
        callbackPath: String = "/oauth/spotify/callback",
        callbackTimeout: TimeInterval = 180
    ) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.callbackPath = callbackPath.hasPrefix("/") ? callbackPath : "/\(callbackPath)"
        self.callbackTimeout = callbackTimeout
    }
}

public struct SpotifyTokenSet: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let tokenType: String
    public let scopes: [String]
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String?, tokenType: String, scopes: [String], expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.scopes = scopes
        self.expiresAt = expiresAt
    }

    public func isUsable(at date: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(date) > leeway && !accessToken.isEmpty
    }
}

public enum SpotifyAuthError: LocalizedError {
    case missingClientID
    case invalidAuthorizationURL
    case randomGenerationFailed(OSStatus)
    case callbackTimedOut
    case callbackCancelled
    case callbackRejected(String)
    case stateMismatch
    case missingAuthorizationCode
    case noStoredCredentials
    case refreshTokenMissing
    case tokenEndpoint(status: Int, message: String?)
    case invalidTokenResponse
    case keychain(OSStatus)
    case loopback(String)

    public var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "请先在设置中填写 Spotify Developer App 的 Client ID。"
        case .invalidAuthorizationURL:
            return "无法创建 Spotify 授权链接。"
        case let .randomGenerationFailed(status):
            return "无法安全生成 Spotify 授权随机数（\(status)）。"
        case .callbackTimedOut:
            return "Spotify 登录等待超时，请重新连接。"
        case .callbackCancelled:
            return "Spotify 登录已取消。"
        case let .callbackRejected(message):
            return "Spotify 未授权连接：\(message)"
        case .stateMismatch:
            return "Spotify 登录回调校验失败，请重新连接。"
        case .missingAuthorizationCode:
            return "Spotify 登录回调中没有授权码。"
        case .noStoredCredentials:
            return "尚未连接 Spotify 账号。"
        case .refreshTokenMissing:
            return "Spotify 登录已过期且无法刷新，请重新连接。"
        case let .tokenEndpoint(status, message):
            return "Spotify 登录服务返回错误 \(status)\(message.map { "：\($0)" } ?? "")。"
        case .invalidTokenResponse:
            return "Spotify 登录服务返回了无法识别的凭据。"
        case let .keychain(status):
            return "无法访问 macOS 钥匙串（\(status)）。"
        case let .loopback(message):
            return "无法接收 Spotify 登录回调：\(message)"
        }
    }
}

public protocol SpotifyCredentialStoring: Sendable {
    func load() throws -> SpotifyTokenSet?
    func save(_ tokenSet: SpotifyTokenSet) throws
    func delete() throws
}

public final class SpotifyKeychainCredentialStore: SpotifyCredentialStoring, @unchecked Sendable {
    public static let service = "\(MediaFetchRelease.bundleIdentifier).spotify"
    private let account = "oauth-token"

    public init() {}

    public func load() throws -> SpotifyTokenSet? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SpotifyAuthError.keychain(status) }
        guard let data = result as? Data,
              let tokenSet = try? JSONDecoder().decode(SpotifyTokenSet.self, from: data)
        else { throw SpotifyAuthError.invalidTokenResponse }
        return tokenSet
    }

    public func save(_ tokenSet: SpotifyTokenSet) throws {
        let data = try JSONEncoder().encode(tokenSet)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw SpotifyAuthError.keychain(updateStatus) }

        var addQuery = baseQuery
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw SpotifyAuthError.keychain(addStatus) }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SpotifyAuthError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
    }
}

public protocol SpotifyHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionSpotifyHTTPTransport: SpotifyHTTPTransport {
    public let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, httpResponse)
    }
}

public protocol SpotifyBrowserOpening: Sendable {
    func open(_ url: URL) async throws
}

public struct WorkspaceSpotifyBrowserOpener: SpotifyBrowserOpening {
    public init() {}

    public func open(_ url: URL) async throws {
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        if !opened { throw SpotifyAuthError.callbackCancelled }
    }
}

public protocol SpotifyOAuthRandomGenerating: Sendable {
    func codeVerifier() throws -> String
    func state() throws -> String
}

public struct SecureSpotifyOAuthRandomGenerator: SpotifyOAuthRandomGenerating {
    public init() {}

    public func codeVerifier() throws -> String { try Self.randomURLSafeString(byteCount: 48) }
    public func state() throws -> String { try Self.randomURLSafeString(byteCount: 24) }

    private static func randomURLSafeString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw SpotifyAuthError.randomGenerationFailed(status) }
        return Data(bytes).base64URLEncodedString()
    }
}

public protocol SpotifyLoopbackListening: Sendable {
    func start() async throws -> URL
    func waitForCallback(timeout: TimeInterval) async throws -> URL
    func stop() async
}

public actor SpotifyLoopbackHTTPListener: SpotifyLoopbackListening {
    private let callbackPath: String
    private let queue = DispatchQueue(label: "\(MediaFetchRelease.bundleIdentifier).spotify.loopback")
    private var listener: NWListener?
    private var readyContinuation: CheckedContinuation<URL, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var bufferedCallback: Result<URL, Error>?
    private var timeoutTask: Task<Void, Never>?

    public init(callbackPath: String = "/oauth/spotify/callback") {
        self.callbackPath = callbackPath.hasPrefix("/") ? callbackPath : "/\(callbackPath)"
    }

    public func start() async throws -> URL {
        if let listener, let port = listener.port {
            return Self.redirectURL(port: port, path: callbackPath)
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters)
        } catch {
            throw SpotifyAuthError.loopback(error.localizedDescription)
        }
        listener = newListener
        newListener.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleListenerState(state) }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }

        return try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
            newListener.start(queue: queue)
        }
    }

    public func waitForCallback(timeout: TimeInterval) async throws -> URL {
        if let bufferedCallback {
            self.bufferedCallback = nil
            return try bufferedCallback.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            callbackContinuation = continuation
            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                let nanoseconds = UInt64(max(timeout, 0.1) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                await self?.timeOutCallback()
            }
        }
    }

    public func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        listener?.cancel()
        listener = nil
        if let readyContinuation {
            self.readyContinuation = nil
            readyContinuation.resume(throwing: SpotifyAuthError.callbackCancelled)
        }
        if let callbackContinuation {
            self.callbackContinuation = nil
            callbackContinuation.resume(throwing: SpotifyAuthError.callbackCancelled)
        }
        bufferedCallback = nil
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port, let readyContinuation else { return }
            self.readyContinuation = nil
            readyContinuation.resume(returning: Self.redirectURL(port: port, path: callbackPath))
        case let .failed(error):
            let wrapped = SpotifyAuthError.loopback(error.localizedDescription)
            if let readyContinuation {
                self.readyContinuation = nil
                readyContinuation.resume(throwing: wrapped)
            }
            deliverCallback(.failure(wrapped))
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, error in
            Task { await self?.handleRequest(data: data, error: error, connection: connection) }
        }
    }

    private func handleRequest(data: Data?, error: NWError?, connection: NWConnection) {
        guard error == nil,
              let data,
              let request = String(data: data, encoding: .utf8),
              let requestLine = request.split(separator: "\r\n", maxSplits: 1).first
        else {
            connection.cancel()
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            sendResponse(status: "405 Method Not Allowed", body: "Method not allowed.", connection: connection)
            return
        }
        let requestTarget = String(parts[1])
        guard let components = URLComponents(string: "http://127.0.0.1\(requestTarget)"),
              components.path == callbackPath,
              let callbackURL = components.url
        else {
            sendResponse(status: "404 Not Found", body: "Not found.", connection: connection)
            return
        }

        sendResponse(
            status: "200 OK",
            body: "Spotify connection received. You may close this window and return to Sooogood Video Catch.",
            connection: connection
        )
        deliverCallback(.success(callbackURL))
    }

    private func sendResponse(status: String, body: String, connection: NWConnection) {
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var response = Data(header.utf8)
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func deliverCallback(_ result: Result<URL, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let callbackContinuation {
            self.callbackContinuation = nil
            callbackContinuation.resume(with: result)
        } else {
            bufferedCallback = result
        }
    }

    private func timeOutCallback() {
        guard let callbackContinuation else { return }
        self.callbackContinuation = nil
        callbackContinuation.resume(throwing: SpotifyAuthError.callbackTimedOut)
    }

    private static func redirectURL(port: NWEndpoint.Port, path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port.rawValue)\(path)")!
    }
}

public protocol SpotifyAccessTokenProviding: Sendable {
    func validAccessToken() async throws -> String
    func refreshAccessToken() async throws -> String
    func disconnect() async throws
}

public actor SpotifyAuthClient: SpotifyAccessTokenProviding {
    public typealias LoopbackFactory = @Sendable () -> any SpotifyLoopbackListening

    private let configuration: SpotifyOAuthConfiguration
    private let credentials: any SpotifyCredentialStoring
    private let transport: any SpotifyHTTPTransport
    private let browser: any SpotifyBrowserOpening
    private let random: any SpotifyOAuthRandomGenerating
    private let loopbackFactory: LoopbackFactory
    private let now: @Sendable () -> Date

    public init(
        configuration: SpotifyOAuthConfiguration,
        credentials: any SpotifyCredentialStoring = SpotifyKeychainCredentialStore(),
        transport: any SpotifyHTTPTransport = URLSessionSpotifyHTTPTransport(),
        browser: any SpotifyBrowserOpening = WorkspaceSpotifyBrowserOpener(),
        random: any SpotifyOAuthRandomGenerating = SecureSpotifyOAuthRandomGenerator(),
        loopbackFactory: LoopbackFactory? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.credentials = credentials
        self.transport = transport
        self.browser = browser
        self.random = random
        self.loopbackFactory = loopbackFactory ?? {
            SpotifyLoopbackHTTPListener(callbackPath: configuration.callbackPath)
        }
        self.now = now
    }

    public func isConnected() -> Bool {
        (try? credentials.load()) != nil
    }

    public func connect() async throws -> SpotifyTokenSet {
        guard !configuration.clientID.isEmpty else { throw SpotifyAuthError.missingClientID }
        let verifier = try random.codeVerifier()
        let state = try random.state()
        let listener = loopbackFactory()
        let redirectURI = try await listener.start()

        do {
            let authorizationURL = try makeAuthorizationURL(
                redirectURI: redirectURI,
                codeVerifier: verifier,
                state: state
            )
            try await browser.open(authorizationURL)
            let callbackURL = try await listener.waitForCallback(timeout: configuration.callbackTimeout)
            await listener.stop()
            let code = try Self.authorizationCode(from: callbackURL, expectedState: state)
            let tokenSet = try await exchangeAuthorizationCode(
                code,
                verifier: verifier,
                redirectURI: redirectURI
            )
            try credentials.save(tokenSet)
            return tokenSet
        } catch {
            await listener.stop()
            throw error
        }
    }

    public func validAccessToken() async throws -> String {
        guard let tokenSet = try credentials.load() else { throw SpotifyAuthError.noStoredCredentials }
        if tokenSet.isUsable(at: now()) { return tokenSet.accessToken }
        return try await refreshAccessToken()
    }

    public func refreshAccessToken() async throws -> String {
        guard let stored = try credentials.load() else { throw SpotifyAuthError.noStoredCredentials }
        guard let refreshToken = stored.refreshToken, !refreshToken.isEmpty else {
            throw SpotifyAuthError.refreshTokenMissing
        }
        let body = Self.formEncoded([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": configuration.clientID
        ])
        let response = try await requestToken(body: body)
        let tokenSet = try tokenSet(from: response, fallbackRefreshToken: refreshToken)
        try credentials.save(tokenSet)
        return tokenSet.accessToken
    }

    public func disconnect() throws {
        try credentials.delete()
    }

    public func makeAuthorizationURL(redirectURI: URL, codeVerifier: String, state: String) throws -> URL {
        guard !configuration.clientID.isEmpty else { throw SpotifyAuthError.missingClientID }
        var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.pkceChallenge(for: codeVerifier)),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: SpotifyOAuthConfiguration.allowedScopes.joined(separator: " "))
        ]
        guard let url = components?.url else { throw SpotifyAuthError.invalidAuthorizationURL }
        return url
    }

    public static func pkceChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    public static func authorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw SpotifyAuthError.missingAuthorizationCode
        }
        let queryItems = components.queryItems ?? []
        let stateValues = queryItems.filter { $0.name == "state" }
        guard stateValues.count == 1, stateValues[0].value == expectedState else {
            throw SpotifyAuthError.stateMismatch
        }
        let errorValues = queryItems.filter { $0.name == "error" }
        guard errorValues.count <= 1 else { throw SpotifyAuthError.missingAuthorizationCode }
        if let error = errorValues.first?.value, !error.isEmpty {
            throw SpotifyAuthError.callbackRejected(error)
        }
        let codeValues = queryItems.filter { $0.name == "code" }
        guard codeValues.count == 1, let code = codeValues[0].value, !code.isEmpty else {
            throw SpotifyAuthError.missingAuthorizationCode
        }
        return code
    }

    private func exchangeAuthorizationCode(
        _ code: String,
        verifier: String,
        redirectURI: URL
    ) async throws -> SpotifyTokenSet {
        let body = Self.formEncoded([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI.absoluteString,
            "client_id": configuration.clientID,
            "code_verifier": verifier
        ])
        let response = try await requestToken(body: body)
        return try tokenSet(from: response, fallbackRefreshToken: nil)
    }

    private func requestToken(body: Data) async throws -> SpotifyTokenResponse {
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw SpotifyAuthError.tokenEndpoint(
                status: response.statusCode,
                message: Self.tokenErrorMessage(from: data)
            )
        }
        do {
            return try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
        } catch {
            throw SpotifyAuthError.invalidTokenResponse
        }
    }

    private func tokenSet(
        from response: SpotifyTokenResponse,
        fallbackRefreshToken: String?
    ) throws -> SpotifyTokenSet {
        guard !response.accessToken.isEmpty, response.expiresIn > 0 else {
            throw SpotifyAuthError.invalidTokenResponse
        }
        let returnedScopes = response.scope?
            .split(separator: " ")
            .map(String.init) ?? SpotifyOAuthConfiguration.allowedScopes
        let allowed = Set(SpotifyOAuthConfiguration.allowedScopes)
        guard Set(returnedScopes).isSubset(of: allowed) else {
            throw SpotifyAuthError.invalidTokenResponse
        }
        return SpotifyTokenSet(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? fallbackRefreshToken,
            tokenType: response.tokenType,
            scopes: returnedScopes,
            expiresAt: now().addingTimeInterval(TimeInterval(response.expiresIn))
        )
    }

    private static func tokenErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let description = object["error_description"] as? String { return description }
        if let error = object["error"] as? String { return error }
        return nil
    }

    private static func formEncoded(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let value = fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
        return Data(value.utf8)
    }
}

private struct SpotifyTokenResponse: Decodable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let refreshToken: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
