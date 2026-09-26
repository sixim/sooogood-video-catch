import SwiftUI
import MediaFetchCore
import MediaFetchMusic
import MediaFetchVideo
#if !MEDIAFETCH_STORE_PROFILE
import MediaFetchTorrent
#endif

enum AppRoute: String, Hashable {
    case home
    case video
    case music
    case tasks
    case settings
    case torrent
}

struct ContentView: View {
    @StateObject private var downloader = DownloaderService()
    @StateObject private var spotify = SpotifyBridgeViewModel()
    @StateObject private var streamingLogins = StreamingSiteLoginStore()
#if !MEDIAFETCH_STORE_PROFILE
    @StateObject private var torrents = TorrentService(defaultDownloadDirectory: TorrentDefaults.downloadDirectory)
#endif
    @State private var path: [AppRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(
                downloader: downloader,
                spotify: spotify,
                navigate: navigate
            )
            .navigationDestination(for: AppRoute.self) { route in
                destination(for: route)
            }
        }
        .environment(\.colorScheme, .dark)
        .tint(MediaFetchTheme.videoAccent)
#if !MEDIAFETCH_STORE_PROFILE
        .onAppear {
            downloader.inAppCookieProvider = { url in
                try await streamingLogins.exportSession(for: url)
            }
        }
        .sheet(item: $streamingLogins.requestedLogin) { platform in
            InAppSiteLoginView(session: streamingLogins.session(for: platform), store: streamingLogins)
        }
        .onOpenURL(perform: handleOpenURL)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            torrents.shutdown()
        }
#endif
    }

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .home:
            HomeView(downloader: downloader, spotify: spotify, navigate: navigate)
        case .video:
            VideoDownloadView(
                downloader: downloader,
                loginStore: streamingLogins,
                onBack: goHome
            )
                .navigationBarBackButtonHidden()
        case .music:
            MusicBridgeView(viewModel: spotify, onBack: goHome, openSettings: {
                replaceTop(with: .settings)
            })
            .navigationBarBackButtonHidden()
        case .tasks:
            DownloadTasksView(
                downloader: downloader,
                onBack: goHome,
                openVideo: { replaceTop(with: .video) },
                openSettings: { replaceTop(with: .settings) }
            )
                .navigationBarBackButtonHidden()
        case .torrent:
#if !MEDIAFETCH_STORE_PROFILE
            TorrentView(service: torrents, onBack: goHome)
                .navigationBarBackButtonHidden()
#else
            EmptyView()
#endif
        case .settings:
            SettingsView(
                viewModel: spotify,
                loginStore: streamingLogins,
                onBack: goHome
            )
                .navigationBarBackButtonHidden()
        }
    }

#if !MEDIAFETCH_STORE_PROFILE
    /// `magnet:` links and `.torrent` files opened from Finder or a browser.
    private func handleOpenURL(_ url: URL) {
        let source: TorrentSource?
        if url.scheme?.lowercased() == "magnet" {
            source = TorrentSource.magnet(from: url.absoluteString)
        } else if url.isFileURL, url.pathExtension.lowercased() == "torrent" {
            source = try? TorrentSource.metainfo(fileAt: url)
        } else {
            source = nil
        }
        guard let source else { return }
        if path.last != .torrent { path.append(.torrent) }
        // The first-use notice must be accepted before anything is added.
        guard UserDefaults.standard.bool(forKey: "MediaFetch.torrent.noticeAccepted") else { return }
        Task { try? await torrents.add(source) }
    }
#endif

    private func navigate(_ route: AppRoute) {
        guard route != .home else {
            goHome()
            return
        }
        path.append(route)
    }

    private func goHome() {
        path.removeAll()
    }

    private func replaceTop(with route: AppRoute) {
        if path.isEmpty {
            path = [route]
        } else {
            path[path.count - 1] = route
        }
    }
}
