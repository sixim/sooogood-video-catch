import Foundation
import Security

// BitTorrent is Local-profile only; nothing here ships in the Store binary.
#if !MEDIAFETCH_STORE_PROFILE
/// RPC endpoint of the private daemon, remembered so a daemon that kept seeding
/// after the app quit can be adopted again on the next launch.
public struct TorrentRPCCredentials: Codable, Equatable, Sendable {
    public let port: Int
    public let username: String
    public let password: String

    public var endpoint: TransmissionRPCClient.Endpoint { .init(port: port, username: username, password: password) }
}

public protocol TorrentCredentialStoring: Sendable {
    func load() -> TorrentRPCCredentials?
    func save(_ credentials: TorrentRPCCredentials)
    func clear()
}

/// Login-keychain generic password; never written to UserDefaults or logs.
public struct KeychainTorrentCredentialStore: TorrentCredentialStoring {
    public let service: String
    public let account = "transmission-rpc"

    public init(service: String = "com.simon.mediafetch.transmission") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() -> TorrentRPCCredentials? {
        var result: AnyObject?
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(TorrentRPCCredentials.self, from: data)
    }

    public func save(_ credentials: TorrentRPCCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        let update = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func clear() { SecItemDelete(query as CFDictionary) }
}

/// For tests.
public final class InMemoryTorrentCredentialStore: TorrentCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: TorrentRPCCredentials?
    public init() {}
    public func load() -> TorrentRPCCredentials? { lock.withLock { value } }
    public func save(_ credentials: TorrentRPCCredentials) { lock.withLock { value = credentials } }
    public func clear() { lock.withLock { value = nil } }
}
#endif
