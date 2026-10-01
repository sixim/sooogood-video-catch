import Foundation

/// Where a pasted or dropped item should go. The home screen accepts anything;
/// this decides the destination without knowing about any engine module.
public enum RoutedInput: Equatable, Sendable {
    case webMedia(URL)
    case magnet(String)
    case torrentFile(URL)
    case localMedia(URL)
    case unsupported(String)

    public var destination: Destination {
        switch self {
        case .webMedia(let url):
            return MusicLink.parse(url) != nil || MusicLink.needsRedirectResolution(url) ? .music : .video
        case .magnet, .torrentFile: return .torrent
        case .localMedia: return .tools
        case .unsupported: return .none
        }
    }

    public enum Destination: String, Sendable {
        case video, music, torrent, tools, none
    }
}

public enum InputClassifier {
    static let localMediaExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "webm", "avi", "mxf", "ts", "mp3", "m4a", "wav", "aif", "aiff", "flac", "opus"
    ]

    /// Splits on whitespace and newlines; magnets keep their full query string.
    public static func classify(_ text: String) -> [RoutedInput] {
        var items: [RoutedInput] = []
        for token in text.components(separatedBy: .whitespacesAndNewlines) where !token.isEmpty {
            let lowered = token.lowercased()
            if lowered.contains("http://") || lowered.contains("https://"), !lowered.hasPrefix("magnet:") {
                // Share text glues links to other characters: take every URL inside the token.
                let urls = LinkInputParser.URLs(from: token)
                items += urls.map { $0.pathExtension.lowercased() == "torrent" ? .torrentFile($0) : .webMedia($0) }
                if urls.isEmpty { items.append(.unsupported(token)) }
            } else if !token.unicodeScalars.contains(where: { $0.value > 0x2E7F }) || token.hasPrefix("/") || token.hasPrefix("~") || lowered.hasPrefix("magnet:") {
                items.append(classifyToken(token))
            }
            // Pure CJK words around a shared link (e.g. 分享…的单曲) are not inputs.
        }
        return items.reduce(into: [RoutedInput]()) { result, item in
            if !result.contains(item) { result.append(item) }
        }
    }

    public static func classify(fileURLs: [URL]) -> [RoutedInput] {
        fileURLs.map { url in
            let ext = url.pathExtension.lowercased()
            if ext == "torrent" { return .torrentFile(url) }
            if localMediaExtensions.contains(ext) { return .localMedia(url) }
            return .unsupported(url.lastPathComponent)
        }
    }

    static func classifyToken(_ token: String) -> RoutedInput {
        let lowered = token.lowercased()
        if lowered.hasPrefix("magnet:?") { return .magnet(token) }
        if lowered.hasPrefix("file://"), let url = URL(string: token) {
            return classify(fileURLs: [url]).first ?? .unsupported(token)
        }
        if token.hasPrefix("/") || token.hasPrefix("~/") {
            let url = URL(fileURLWithPath: (token as NSString).expandingTildeInPath)
            return classify(fileURLs: [url]).first ?? .unsupported(token)
        }
        if let url = URLValidator.validatedMediaURL(from: token) {
            if url.pathExtension.lowercased() == "torrent" { return .torrentFile(url) }
            return .webMedia(url)
        }
        return .unsupported(token)
    }

    /// The single page to open for a batch: the destination most items share,
    /// preferring video when tied.
    public static func primaryDestination(of items: [RoutedInput]) -> RoutedInput.Destination {
        let counts = Dictionary(grouping: items.map(\.destination).filter { $0 != .none }, by: { $0 }).mapValues(\.count)
        guard let best = counts.max(by: { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key != .video
        }) else { return .none }
        return best.key
    }
}
