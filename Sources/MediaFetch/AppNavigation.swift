import SwiftUI
import MediaFetchCore
import MediaFetchMusic
import MediaFetchVideo

enum AppRoute: String, Hashable {
    case home
    case video
    case music
    case tasks
    case settings
}

struct ContentView: View {
    @StateObject private var downloader = DownloaderService()
    @StateObject private var spotify = SpotifyBridgeViewModel()
    @StateObject private var streamingLogins = StreamingSiteLoginStore()
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
                openVideo: { replaceTop(with: .video) }
            )
                .navigationBarBackButtonHidden()
        case .settings:
            SettingsView(
                viewModel: spotify,
                loginStore: streamingLogins,
                onBack: goHome
            )
                .navigationBarBackButtonHidden()
        }
    }

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
