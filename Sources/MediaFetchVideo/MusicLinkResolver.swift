import Foundation
import MediaFetchCore

/// Expands music-app short links (163cn.tv, c6.y.qq.com/base/fcgi-bin/u?…) to
/// their canonical page URL. Redirects are followed only while they stay on
/// music hosts, and the result is used only if it parses as a music link.
public struct MusicLinkResolver: Sendable {
    let session: URLSession
    static let maxRedirects = 6

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Replaces every short link in `input` with its canonical form; other text is kept.
    public func resolveShortLinks(in input: String) async -> String {
        var output = input
        for candidate in LinkInputParser.candidates(in: input) {
            guard let url = URL(string: candidate), MusicLink.needsRedirectResolution(url),
                  let resolved = await resolve(url) else { continue }
            output = output.replacingOccurrences(of: candidate, with: " " + resolved.absoluteString + " ")
        }
        return output
    }

    public func resolve(_ url: URL) async -> URL? {
        if let link = MusicLink.parse(url) { return link.canonicalURL }
        guard Self.isMusicHost(url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let guardian = RedirectGuard(limit: Self.maxRedirects)
        _ = try? await session.data(for: request, delegate: guardian)
        guard !guardian.leftMusicHosts else { return nil }
        // The last hop we allowed is where the link points.
        return guardian.lastAllowed.flatMap { MusicLink.parse($0)?.canonicalURL }
    }

    static func isMusicHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), url.scheme?.lowercased().hasPrefix("http") == true else { return false }
        return ["163cn.tv", "music.163.com", "y.music.163.com", "qq.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// Follows redirects only while they stay on music hosts; records each hop.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var hops = 0
    private var _lastAllowed: URL?
    private var _leftMusicHosts = false

    init(limit: Int) { self.limit = limit }

    var lastAllowed: URL? { lock.withLock { _lastAllowed } }
    var leftMusicHosts: Bool { lock.withLock { _leftMusicHosts } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let next = request.url
        let allowed: Bool = lock.withLock {
            hops += 1
            guard let next, hops <= limit, MusicLinkResolver.isMusicHost(next) else {
                _leftMusicHosts = next.map { !MusicLinkResolver.isMusicHost($0) } ?? false
                return false
            }
            _lastAllowed = next
            return true
        }
        // Once a hop parses as a music link there is no need to load that page.
        if allowed, let next, MusicLink.parse(next) == nil {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}
