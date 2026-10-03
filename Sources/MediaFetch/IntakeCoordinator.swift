import SwiftUI
import MediaFetchCore

/// Hands pasted/dropped/hotkey input from anywhere to the page that owns it.
/// Pages consume their pending input once and clear it.
@MainActor
final class IntakeCoordinator: ObservableObject {
    @Published var pendingVideoInput: String?
    @Published var pendingTorrentInputs: [RoutedInput] = []
    @Published var pendingToolInputs: [URL] = []
    @Published var pendingMusicInput: String?
    @Published var notice: String?

    /// Routes a batch and returns the page to open.
    func route(_ items: [RoutedInput]) -> AppRoute? {
        notice = nil
        let web = items.compactMap { item -> String? in
            if case .webMedia(let url) = item, item.destination == .video { return url.absoluteString }
            return nil
        }
        let music = items.compactMap { item -> String? in
            if case .webMedia(let url) = item, item.destination == .music { return url.absoluteString }
            return nil
        }
        if !music.isEmpty { pendingMusicInput = music.joined(separator: "\n") }
        let torrents = items.filter { $0.destination == .torrent }
        let unsupported = items.compactMap { item -> String? in
            if case .unsupported(let text) = item { return text }
            return nil
        }
        if !web.isEmpty { pendingVideoInput = web.joined(separator: "\n") }
        if !torrents.isEmpty { pendingTorrentInputs += torrents }
        pendingToolInputs += items.compactMap { item -> URL? in
            if case .localMedia(let url) = item { return url }
            return nil
        }
        if !unsupported.isEmpty {
            notice = String(localized: "无法识别：") + unsupported.prefix(3).joined(separator: "、") + (unsupported.count > 3 ? String(localized: " 等") : "")
        }
        switch InputClassifier.primaryDestination(of: items) {
        case .video: return .video
        case .music: return .musicDownload
        case .torrent: return .torrent
        case .tools: return .tools
        case .none: return nil
        }
    }
}

/// Home-screen box that accepts links, magnets, .torrent files and media files.
struct QuickIntakeBar: View {
    @ObservedObject var intake: IntakeCoordinator
    let open: (AppRoute) -> Void
    @State private var text = ""
    @State private var isTargeted = false

    var body: some View {
        MediaFetchPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.to.line")
                        .foregroundStyle(MediaFetchTheme.videoAccent)
                    TextField("粘贴视频链接、磁力链接，或把 .torrent / 媒体文件拖到这里", text: $text)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .onSubmit(submit)
                    Button("开始", action: submit)
                        .buttonStyle(.borderedProminent)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let notice = intake.notice {
                    Text(notice).font(.caption).foregroundStyle(MediaFetchTheme.warning)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(MediaFetchTheme.videoAccent, lineWidth: isTargeted ? 2 : 0))
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $isTargeted, perform: handleDrop)
    }

    private func submit() {
        let items = InputClassifier.classify(text)
        if let route = intake.route(items) {
            text = ""
            open(route)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    let items = url.isFileURL ? InputClassifier.classify(fileURLs: [url]) : InputClassifier.classify(url.absoluteString)
                    if let route = intake.route(items) { open(route) }
                }
            }
        }
        return handled
    }
}
