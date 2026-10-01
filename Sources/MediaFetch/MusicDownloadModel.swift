#if !MEDIAFETCH_STORE_PROFILE
import Foundation
import MediaFetchCore
import MediaFetchVideo

/// State of the music download page: resolve a link, list tracks, probe each
/// track's available quality (three at a time), and queue the selection.
@MainActor
final class MusicDownloadModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case resolving
        case single(url: String, track: MusicTrackInfo)
        case list(CollectionOutline)
        case failed(String)
    }

    enum Probe: Equatable {
        case pending
        case loading
        case loaded(MusicTrackInfo)
        case failed(String)

        var track: MusicTrackInfo? { if case .loaded(let t) = self { return t }; return nil }
    }

    @Published var phase: Phase = .idle
    @Published var probes: [String: Probe] = [:]
    @Published var selected: Set<String> = []
    @Published var sourceURL: URL?

    static let autoProbeLimit = 40
    private let maxConcurrentProbes = 3

    private let downloader: DownloaderService
    private let logins: StreamingSiteLoginStore

    init(downloader: DownloaderService, logins: StreamingSiteLoginStore) {
        self.downloader = downloader
        self.logins = logins
    }

    var outline: CollectionOutline? { if case .list(let o) = phase { return o }; return nil }

    func session(for url: URL) -> (cookieSource: BrowserCookieSource?, inApp: Bool) { logins.routing(for: url) }

    /// Login state for the page header.
    func loginSummary(for platform: StreamingPlatform) -> String {
        guard logins.isEnabled(for: platform) else { return "未登录" }
        return logins.method(for: platform) == .inApp ? "应用内登录" : "\(logins.browser(for: platform).displayName) 登录态"
    }

    func isLoggedIn(_ platform: StreamingPlatform) -> Bool { logins.isEnabled(for: platform) }

    // MARK: Resolve

    func resolve(_ text: String) {
        probeQueue = []
        probes = [:]
        selected = []
        phase = .resolving
        Task {
            let expanded = await MusicLinkResolver().resolveShortLinks(in: text)
            guard let url = LinkInputParser.URLs(from: expanded).first(where: { MusicLink.parse($0) != nil }) else {
                phase = .failed("没有找到网易云音乐或 QQ 音乐的链接。支持单曲、专辑、歌单、歌手和排行榜，也可以直接粘贴 App 的分享文案。")
                return
            }
            sourceURL = url
            let session = session(for: url)
            do {
                if MusicLink.parse(url)?.kind.isCollection == true {
                    let outline = try await downloader.expandCollection(url, cookieSource: session.cookieSource, usesInAppLogin: session.inApp)
                    phase = .list(outline)
                    selected = Set(outline.entries.map(\.id))
                    probe(Array(outline.entries.prefix(Self.autoProbeLimit)))
                } else {
                    let track = try await downloader.inspectMusic(url, cookieSource: session.cookieSource, usesInAppLogin: session.inApp)
                    phase = .single(url: url.absoluteString, track: track)
                }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Probing

    func probeAll() {
        guard let outline else { return }
        probe(outline.entries.filter { probes[$0.id] == nil || probes[$0.id] == .pending })
    }

    func probe(_ entries: [CollectionEntry]) {
        for entry in entries where probes[entry.id] == nil || probes[entry.id] == .pending {
            probes[entry.id] = .pending
            if !probeQueue.contains(where: { $0.id == entry.id }) { probeQueue.append(entry) }
        }
        // A small pool of workers drains the queue; each probe is one yt-dlp run.
        while activeProbes < maxConcurrentProbes, !probeQueue.isEmpty {
            activeProbes += 1
            Task { [weak self] in
                while let self, let entry = self.nextQueuedProbe() {
                    await self.probeOne(entry)
                }
                self?.activeProbes -= 1
            }
        }
    }

    private var probeQueue: [CollectionEntry] = []
    private var activeProbes = 0

    private func nextQueuedProbe() -> CollectionEntry? {
        while !probeQueue.isEmpty {
            let entry = probeQueue.removeFirst()
            if probes[entry.id] == .pending { return entry }
        }
        return nil
    }

    private func probeOne(_ entry: CollectionEntry) async {
        guard let url = URL(string: entry.url) else { probes[entry.id] = .failed("链接无效"); return }
        probes[entry.id] = .loading
        let session = session(for: url)
        do {
            probes[entry.id] = .loaded(try await downloader.inspectMusic(url, cookieSource: session.cookieSource, usesInAppLogin: session.inApp))
        } catch {
            probes[entry.id] = .failed(error.localizedDescription)
        }
    }

    // MARK: Selection

    /// Entries grouped by album once probed; unknown albums stay together.
    func albumGroups() -> [(album: String, entries: [CollectionEntry])] {
        guard let outline else { return [] }
        var order: [String] = []
        var groups: [String: [CollectionEntry]] = [:]
        for entry in outline.entries {
            let album = probes[entry.id]?.track?.album ?? "未知专辑"
            if groups[album] == nil { order.append(album) }
            groups[album, default: []].append(entry)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    func toggle(_ entries: [CollectionEntry], on: Bool) {
        for entry in entries { if on { selected.insert(entry.id) } else { selected.remove(entry.id) } }
    }

    // MARK: Queue

    /// Returns how many were queued and which were skipped because the chosen
    /// quality is known to be unavailable for them.
    @discardableResult
    func enqueue(quality: MusicQualityPreference, layout: MusicLayout, destination: URL, nameTemplate: String? = nil) -> (queued: Int, skipped: [String]) {
        guard let sourceURL else { return (0, []) }
        let session = session(for: sourceURL)
        var items: [(url: String, title: String?, collection: CollectionContext?)] = []
        var skipped: [String] = []
        switch phase {
        case .single(let url, let track):
            if quality.expectedTier(from: track.availableTiers) == nil && !track.formats.isEmpty {
                skipped.append(track.title)
            } else {
                items.append((url, track.title, nil))
            }
        case .list(let outline):
            for entry in outline.entries where selected.contains(entry.id) {
                if let track = probes[entry.id]?.track, !track.formats.isEmpty,
                   quality.expectedTier(from: track.availableTiers) == nil {
                    skipped.append(entry.title)
                    continue
                }
                items.append((entry.url, probes[entry.id]?.track?.title ?? entry.title,
                              layout == .collection || (layout == .custom && (nameTemplate ?? "").contains("{index}"))
                                ? outline.context(for: entry) : nil))
            }
        default:
            break
        }
        guard !items.isEmpty else { return (0, skipped) }
        let queued = downloader.enqueueMusic(items, quality: quality, layout: layout, destination: destination,
                                             cookieSource: session.cookieSource, usesInAppLogin: session.inApp,
                                             nameTemplate: nameTemplate)
        return (queued, skipped)
    }
}
#endif
