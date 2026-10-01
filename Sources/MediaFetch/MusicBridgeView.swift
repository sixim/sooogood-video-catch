import AppKit
import SwiftUI
import MediaFetchCore
import MediaFetchMusic

struct MusicBridgeView: View {
    @ObservedObject var viewModel: SpotifyBridgeViewModel
    let onBack: () -> Void
    let openSettings: () -> Void

    @State private var directLinkItemID: UUID?

    var body: some View {
        ZStack {
            CinematicBackground(accent: MediaFetchTheme.musicPurple)

            VStack(spacing: 0) {
                header
                    .frame(maxWidth: 1180)
                    .padding(.horizontal, 36)
                    .padding(.top, 28)
                    .padding(.bottom, 20)

                if viewModel.connectionState.isConnected {
                    connectedContent
                } else {
                    disconnectedContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: directLinkPresented) {
            AuthorizedDirectURLSheet(
                trackTitle: directLinkTrackTitle,
                onCancel: { directLinkItemID = nil },
                onConfirm: { url in
                    guard let id = directLinkItemID else { return }
                    viewModel.assignAuthorizedDirectURL(url, to: id)
                    directLinkItemID = nil
                }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            PageBackButton(action: onBack)

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(MediaFetchTheme.musicGradient)
                Image(systemName: "music.note")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("音乐")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(MediaFetchTheme.primaryText)
                Text("Spotify 曲序 · 你的音频来源 · 可验证素材包")
                    .font(.caption)
                    .foregroundStyle(MediaFetchTheme.secondaryText)
            }

            Spacer()

            StatusPill(
                text: viewModel.connectionState.displayName,
                systemImage: viewModel.connectionState.systemImage,
                color: viewModel.connectionState.color
            )

            Button(action: openSettings) {
                Image(systemName: "gearshape.fill")
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(MediaFetchTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10).stroke(MediaFetchTheme.border, lineWidth: 1)
            }
            .help("Spotify 设置")
            .accessibilityLabel("打开 Spotify 设置")
        }
    }

    private var disconnectedContent: some View {
        VStack {
            MediaFetchPanel {
                VStack(spacing: 20) {
                    ZStack {
                        Circle().fill(MediaFetchTheme.musicPurple.opacity(0.14))
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(MediaFetchTheme.musicPurple)
                    }
                    .frame(width: 72, height: 72)

                    VStack(spacing: 8) {
                        Text("连接 Spotify 以读取曲目顺序")
                            .font(.title2.bold())
                            .foregroundStyle(MediaFetchTheme.primaryText)
                        Text("\(MediaFetchRelease.displayName) 只读取曲目、专辑和歌单信息。音频仍来自你选择的本地资料夹或明确授权的 DRM-free 直链。")
                            .font(.subheadline)
                            .foregroundStyle(MediaFetchTheme.secondaryText)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 540)
                    }

                    if let error = viewModel.inlineError {
                        InlineMessage(text: error, kind: .error)
                            .frame(maxWidth: 580)
                    }

                    HStack(spacing: 12) {
                        Button("打开设置") { openSettings() }
                            .buttonStyle(.bordered)
#if MEDIAFETCH_STORE_PROFILE
                        Button {
                            viewModel.loadDemoCollection()
                        } label: {
                            Label("查看演示", systemImage: "play.circle")
                        }
                        .buttonStyle(.bordered)
#endif
                        Button {
                            Task { await viewModel.connect() }
                        } label: {
                            if viewModel.connectionState.isBusy {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("连接 Spotify", systemImage: "link")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.connectionState.isBusy)
                    }
                }
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: 760)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(36)
    }

    private var connectedContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    linkPanel

                    if viewModel.connectionState == .demo {
                        InlineMessage(
                            text: "演示模式只使用合成 Spotify 元数据；不会访问 Spotify 账号或下载 Spotify 音频。你仍可以选择自己的本地资料夹测试匹配流程。",
                            kind: .info
                        )
                    }

                    if let error = viewModel.inlineError {
                        InlineMessage(text: error, kind: .error)
                    }

                    if viewModel.phase == .loadingCollection {
                        loadingSkeleton
                    } else if let collection = viewModel.collection {
                        collectionSummary(collection)
                        sourcePanel
                        tracksPanel
                    } else {
                        readyPrompt
                    }
                }
                .frame(maxWidth: 1180)
                .padding(.horizontal, 36)
                .padding(.bottom, viewModel.collection == nil ? 30 : 18)
                .frame(maxWidth: .infinity)
            }

            if viewModel.collection != nil {
                saveBar
            }
        }
    }

    private var linkPanel: some View {
        MediaFetchPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text("Spotify 曲目、专辑或歌单链接")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MediaFetchTheme.primaryText)

                HStack(spacing: 12) {
                    Image(systemName: "link")
                        .foregroundStyle(MediaFetchTheme.secondaryText)
                    TextField("https://open.spotify.com/playlist/…", text: $viewModel.spotifyURLText)
                        .textFieldStyle(.plain)
                        .foregroundStyle(MediaFetchTheme.primaryText)
                        .onSubmit { loadMusic() }
                        .accessibilityLabel("Spotify 曲目、专辑或歌单链接")
                    Button {
                        loadMusic()
                    } label: {
                        if viewModel.phase == .loadingCollection {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("载入音乐", systemImage: "arrow.down.doc")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.spotifyURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.phase.isBusy)
                }
                .padding(.leading, 13)
                .padding(.trailing, 6)
                .frame(height: 48)
                .background(MediaFetchTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(MediaFetchTheme.border, lineWidth: 1)
                }

                Text("Spotify 只提供曲目身份与顺序，不是音频来源。")
                    .font(.caption)
                    .foregroundStyle(MediaFetchTheme.secondaryText)
            }
        }
    }

    private var readyPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(MediaFetchTheme.secondaryText)
            Text("粘贴一个 Spotify 链接开始")
                .font(.headline)
                .foregroundStyle(MediaFetchTheme.primaryText)
            Text("支持单曲、专辑，以及当前账号可以读取的自有或协作歌单。")
                .font(.caption)
                .foregroundStyle(MediaFetchTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private var loadingSkeleton: some View {
        MediaFetchPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 18) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(MediaFetchTheme.surfaceSecondary)
                        .frame(width: 112, height: 112)
                    VStack(alignment: .leading, spacing: 12) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(MediaFetchTheme.surfaceSecondary)
                            .frame(width: 240, height: 20)
                        RoundedRectangle(cornerRadius: 5)
                            .fill(MediaFetchTheme.surfaceSecondary)
                            .frame(width: 170, height: 13)
                        RoundedRectangle(cornerRadius: 5)
                            .fill(MediaFetchTheme.surfaceSecondary)
                            .frame(width: 210, height: 13)
                    }
                }
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 7)
                        .fill(MediaFetchTheme.surfaceSecondary)
                        .frame(height: 38)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("正在载入 Spotify 音乐信息")
        }
    }

    private func collectionSummary(_ collection: SpotifyCollection) -> some View {
        MediaFetchPanel {
            HStack(alignment: .top, spacing: 20) {
                cover(for: collection)

                VStack(alignment: .leading, spacing: 9) {
                    Text(collection.kind.displayName.uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(MediaFetchTheme.musicGreen)
                    Text(collection.title)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(MediaFetchTheme.primaryText)
                        .lineLimit(2)
                    if let subtitle = collection.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(MediaFetchTheme.secondaryText)
                            .lineLimit(2)
                    }
                    HStack(spacing: 14) {
                        Label("\(collection.tracks.count) 首", systemImage: "music.note")
                        Label(collection.totalDurationText, systemImage: "clock")
                        if let externalURL = collection.externalURL {
                            Button {
                                NSWorkspace.shared.open(externalURL)
                            } label: {
                                Label("在 Spotify 打开", systemImage: "arrow.up.right.square")
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(MediaFetchTheme.secondaryText)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func cover(for collection: SpotifyCollection) -> some View {
        if let coverURL = collection.coverURL {
            AsyncImage(url: coverURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                default:
                    coverPlaceholder
                }
            }
            .frame(width: 112, height: 112)
            .background(MediaFetchTheme.surfaceSecondary)
            .overlay {
                Rectangle().stroke(MediaFetchTheme.border, lineWidth: 1)
            }
            .accessibilityLabel("\(collection.title) 封面")
        } else {
            coverPlaceholder
                .frame(width: 112, height: 112)
        }
    }

    private var coverPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(MediaFetchTheme.musicGradient.opacity(0.22))
            Image(systemName: "music.note")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(MediaFetchTheme.musicGreen)
        }
    }

    private var sourcePanel: some View {
        MediaFetchPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("音频来源资料夹")
                            .font(.headline)
                            .foregroundStyle(MediaFetchTheme.primaryText)
                        if let folder = viewModel.sourceFolder {
                            Text(folder.path)
                                .font(.caption)
                                .foregroundStyle(MediaFetchTheme.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("选择包含你拥有音频文件的资料夹；扫描过程只读。")
                                .font(.caption)
                                .foregroundStyle(MediaFetchTheme.secondaryText)
                        }
                    }
                    Spacer()
#if !MEDIAFETCH_STORE_PROFILE
                    if FileManager.default.fileExists(atPath: MusicPreferences.destination.path) {
                        Button {
                            Task { await viewModel.scanSourceFolder(MusicPreferences.destination) }
                        } label: {
                            Label("使用音乐下载文件夹", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.phase.isBusy)
                        .help(MusicPreferences.destination.path)
                    }
#endif
                    Button {
                        chooseSourceFolder()
                    } label: {
                        if viewModel.phase == .scanning {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(viewModel.sourceFolder == nil ? "选择资料夹" : "重新扫描", systemImage: "folder")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.phase.isBusy)
                }

                if viewModel.phase == .scanning {
                    VStack(alignment: .leading, spacing: 7) {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(MediaFetchTheme.musicGreen)
                        Text(viewModel.scanProgressText)
                            .font(.caption)
                            .foregroundStyle(MediaFetchTheme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                HStack(spacing: 10) {
                    MatchCountPill(title: "已匹配", count: viewModel.readyCount, icon: "checkmark.circle.fill", color: MediaFetchTheme.success)
                    MatchCountPill(title: "待确认", count: viewModel.ambiguousCount, icon: "exclamationmark.circle.fill", color: MediaFetchTheme.warning)
                    MatchCountPill(title: "未匹配", count: viewModel.unmatchedCount, icon: "minus.circle.fill", color: MediaFetchTheme.secondaryText)
                    Spacer()
                }
            }
        }
    }

    private var tracksPanel: some View {
        MediaFetchPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("曲目")
                        .font(.headline)
                        .foregroundStyle(MediaFetchTheme.primaryText)
                    Spacer()
                    filterPicker
                }

                if viewModel.filteredItems.isEmpty {
                    Text("这个筛选条件下没有曲目。")
                        .font(.caption)
                        .foregroundStyle(MediaFetchTheme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 90)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(viewModel.filteredItems.enumerated()), id: \.element.id) { offset, item in
                            MusicTrackRow(
                                item: item,
                                displayIndex: viewModel.displayIndex(for: item, fallback: offset + 1),
                                confirmCandidate: { candidate in
                                    viewModel.confirm(candidate: candidate, for: item.id)
                                },
                                chooseLocalFile: { chooseLocalFile(for: item.id) },
                                addDirectURL: { directLinkItemID = item.id }
                            )
                            if item.id != viewModel.filteredItems.last?.id {
                                Divider().overlay(MediaFetchTheme.border)
                            }
                        }
                    }
                }
            }
        }
    }

    private var filterPicker: some View {
        HStack(spacing: 4) {
            ForEach(SpotifyBridgeFilter.allCases) { filter in
                Button {
                    viewModel.filter = filter
                } label: {
                    Text(filter.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(viewModel.filter == filter ? MediaFetchTheme.primaryText : MediaFetchTheme.secondaryText)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(
                            viewModel.filter == filter ? Color.white.opacity(0.10) : .clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(viewModel.filter == filter ? .isSelected : [])
            }
        }
        .padding(3)
        .background(MediaFetchTheme.surfaceSecondary, in: Capsule())
        .accessibilityLabel("曲目匹配筛选")
    }

    private var saveBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("保存到")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(MediaFetchTheme.secondaryText)
                Text(viewModel.destination.path)
                    .font(.caption)
                    .foregroundStyle(MediaFetchTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 460, alignment: .leading)

            Button("更改…") { chooseDestination() }
                .buttonStyle(.bordered)
                .disabled(viewModel.phase.isBusy)

            Spacer()

            if let output = viewModel.completedPackageURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                } label: {
                    Label("显示素材包", systemImage: "folder.badge.checkmark")
                }
                .buttonStyle(.bordered)
            }

            Button {
                Task { await viewModel.saveReadyItems() }
            } label: {
                if viewModel.phase == .saving {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(viewModel.saveProgressText)
                    }
                } else {
                    Label("保存 \(viewModel.readyCount) 首音乐", systemImage: "square.and.arrow.down")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canSave || viewModel.phase.isBusy)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 15)
        .background(MediaFetchTheme.surface.opacity(0.98))
        .overlay(alignment: .top) { Divider().overlay(MediaFetchTheme.border) }
        .shadow(color: .black.opacity(0.35), radius: 18, y: -6)
    }

    private func loadMusic() {
        Task { await viewModel.loadCollection() }
    }

    private func chooseSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = viewModel.sourceFolder
        if panel.runModal() == .OK, let url = panel.url {
            Task { await viewModel.scanSourceFolder(url) }
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = viewModel.destination
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.destination = url
        }
    }

    private func chooseLocalFile(for id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = viewModel.supportedAudioContentTypes
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.assignLocalFile(url, to: id)
        }
    }

    private var directLinkPresented: Binding<Bool> {
        Binding(
            get: { directLinkItemID != nil },
            set: { if !$0 { directLinkItemID = nil } }
        )
    }

    private var directLinkTrackTitle: String {
        guard let id = directLinkItemID else { return "" }
        return viewModel.items.first(where: { $0.id == id })?.track.title ?? "这首音乐"
    }
}

private struct MatchCountPill: View {
    let title: String
    let count: Int
    let icon: String
    let color: Color

    var body: some View {
        Label("\(title) \(count)", systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(color.opacity(0.09), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

private struct MusicTrackRow: View {
    let item: SpotifyBridgeItem
    let displayIndex: Int
    let confirmCandidate: (LocalAudioCandidate) -> Void
    let chooseLocalFile: () -> Void
    let addDirectURL: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Text(String(format: "%02d", displayIndex))
                .font(.caption.monospacedDigit())
                .foregroundStyle(MediaFetchTheme.secondaryText)
                .frame(width: 28, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MediaFetchTheme.primaryText)
                    .lineLimit(1)
                Text(item.track.artists.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(MediaFetchTheme.secondaryText)
                    .lineLimit(1)
            }
            .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)

            Text(item.track.durationText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(MediaFetchTheme.secondaryText)
                .frame(width: 48, alignment: .trailing)

            sourceDescription
                .frame(width: 210, alignment: .leading)

            status
                .frame(width: 104, alignment: .leading)

            actions
                .frame(width: 144, alignment: .trailing)
                .opacity(isHovering || item.status == .ambiguous || item.status == .unmatched ? 1 : 0.2)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 52)
        .background(isHovering ? Color.white.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isHovering)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var sourceDescription: some View {
        switch item.source {
        case .localFile(let url):
            Label(url.lastPathComponent, systemImage: "doc.fill")
                .lineLimit(1)
                .truncationMode(.middle)
        case .authorizedDirectURL(let url):
            Label(url.host ?? "授权直链", systemImage: "link")
                .lineLimit(1)
        case nil:
            if item.matches.count > 1 {
                Label("\(item.matches.count) 个本地候选", systemImage: "questionmark.folder")
            } else if let match = item.matches.first {
                Label(match.candidate.url.lastPathComponent, systemImage: "doc")
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Label("尚无音频来源", systemImage: "minus.circle")
            }
        }
    }

    private var status: some View {
        Label(item.status.displayName, systemImage: item.status.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(item.status.color)
            .lineLimit(1)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if !item.matches.isEmpty && item.status != .completed {
                Menu {
                    ForEach(item.matches) { match in
                        Button {
                            confirmCandidate(match.candidate)
                        } label: {
                            Text("\(match.evidence.score) · \(match.candidate.url.lastPathComponent)")
                        }
                    }
                } label: {
                    Image(systemName: "checklist")
                }
                .menuStyle(.borderlessButton)
                .help("审核本地候选")
                .accessibilityLabel("审核《\(item.track.title)》的本地候选")
            }

            if item.status != .completed && item.status != .copying {
                Button(action: chooseLocalFile) {
                    Image(systemName: "doc.badge.plus")
                }
                .buttonStyle(.plain)
                .help("手动选择本地音频")
                .accessibilityLabel("为《\(item.track.title)》选择本地音频")

                Button(action: addDirectURL) {
                    Image(systemName: "link.badge.plus")
                }
                .buttonStyle(.plain)
                .help("添加授权的 DRM-free 直链")
                .accessibilityLabel("为《\(item.track.title)》添加授权的 DRM-free 直链")
            }
        }
        .foregroundStyle(MediaFetchTheme.secondaryText)
    }
}

private struct AuthorizedDirectURLSheet: View {
    let trackTitle: String
    let onCancel: () -> Void
    let onConfirm: (URL) -> Void

    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("添加授权音频直链")
                    .font(.title2.bold())
                Text(trackTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("只接受你明确获准保存的 HTTPS 音频文件地址。Spotify 与 Spotify CDN 地址不会被接受。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("https://example.com/owned-audio.flac", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { confirm() }

            if let error {
                InlineMessage(text: error, kind: .error)
            }

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("使用此来源", action: confirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(26)
        .frame(width: 520)
        .background(MediaFetchTheme.background)
        .environment(\.colorScheme, .dark)
    }

    private func confirm() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            error = "请输入完整的 HTTPS 音频地址。"
            return
        }
        do {
            try SpotifyBridgeService.validateAuthorizedDirectURL(url)
            onConfirm(url)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension SpotifyResourceKind {
    var displayName: String {
        switch self {
        case .track: return "单曲"
        case .album: return "专辑"
        case .playlist: return "歌单"
        }
    }
}

extension SpotifyCollection {
    var totalDurationText: String {
        let totalSeconds = tracks.reduce(0) { $0 + $1.durationMS / 1_000 }
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        return hours > 0 ? "\(hours) 小时 \(minutes) 分钟" : "\(minutes) 分钟"
    }
}

extension SpotifyTrackReference {
    var durationText: String {
        let totalSeconds = durationMS / 1_000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

extension SpotifyBridgeItemStatus {
    var displayName: String {
        switch self {
        case .unmatched: return "未匹配"
        case .ambiguous: return "待确认"
        case .ready: return "已匹配"
        case .copying: return "正在保存"
        case .completed: return "已完成"
        case .failed: return "失败"
        }
    }

    var systemImage: String {
        switch self {
        case .unmatched: return "minus.circle.fill"
        case .ambiguous: return "exclamationmark.circle.fill"
        case .ready: return "checkmark.circle.fill"
        case .copying: return "arrow.down.circle.fill"
        case .completed: return "checkmark.seal.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .unmatched: return MediaFetchTheme.secondaryText
        case .ambiguous: return MediaFetchTheme.warning
        case .ready, .completed: return MediaFetchTheme.success
        case .copying: return Color(hex: 0xB9AFFF)
        case .failed: return MediaFetchTheme.danger
        }
    }
}

#if DEBUG
#Preview("音乐 · 未登录") {
    MusicBridgeView(
        viewModel: SpotifyBridgeViewModel.preview(.disconnected),
        onBack: {},
        openSettings: {}
    )
    .frame(width: 1_120, height: 780)
    .environment(\.colorScheme, .dark)
    .allowsHitTesting(false)
}

#Preview("音乐 · 已载入") {
    MusicBridgeView(
        viewModel: SpotifyBridgeViewModel.preview(.loaded),
        onBack: {},
        openSettings: {}
    )
    .frame(width: 1_120, height: 780)
    .environment(\.colorScheme, .dark)
    .allowsHitTesting(false)
}

#Preview("音乐 · 匹配审核") {
    MusicBridgeView(
        viewModel: SpotifyBridgeViewModel.preview(.review),
        onBack: {},
        openSettings: {}
    )
    .frame(width: 1_120, height: 780)
    .environment(\.colorScheme, .dark)
    .allowsHitTesting(false)
}

#Preview("音乐 · 保存中") {
    MusicBridgeView(
        viewModel: SpotifyBridgeViewModel.preview(.saving),
        onBack: {},
        openSettings: {}
    )
    .frame(width: 1_120, height: 780)
    .environment(\.colorScheme, .dark)
    .allowsHitTesting(false)
}

#Preview("音乐 · 完成") {
    MusicBridgeView(
        viewModel: SpotifyBridgeViewModel.preview(.completed),
        onBack: {},
        openSettings: {}
    )
    .frame(width: 1_120, height: 780)
    .environment(\.colorScheme, .dark)
    .allowsHitTesting(false)
}
#endif
