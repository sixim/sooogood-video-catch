import Foundation

/// Persists a user-selected file URL so a sandboxed build can regain access after relaunch.
///
/// The store contains bookmark data only; it never copies, moves, or hashes the selected
/// file. Callers must keep a security scope open for the duration of their file operation.
public final class SecurityScopedBookmarkStore: @unchecked Sendable {
    public let key: String

    public init(key: String) {
        self.key = key
    }

    public func save(_ url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: key)
    }

    public func resolve() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale { try? save(url) }
            return url
        } catch {
            return nil
        }
    }

    public func remove() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    @discardableResult
    public func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    public func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}
