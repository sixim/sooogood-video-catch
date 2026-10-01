#if !MEDIAFETCH_STORE_PROFILE
import AppKit
import SwiftUI
import MediaFetchCore
import MediaFetchVideo

enum MusicPreferences {
    static let qualityKey = "MediaFetch.music.quality"
    static let layoutKey = "MediaFetch.music.layout"
    static let destinationKey = "MediaFetch.music.destination"
    static let templateKey = "MediaFetch.music.nameTemplate"

    static var destination: URL {
        if let path = UserDefaults.standard.string(forKey: destinationKey) { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sooogood Music", isDirectory: true)
    }
}

/// NetEase Cloud Music / QQ Music: paste a song, album, playlist, artist or chart link.
struct MusicDownloadView: View {
    @ObservedObject var downloader: DownloaderService
    @ObservedObject var logins: StreamingSiteLoginStore
    let onBack: () -> Void
    var intake: IntakeCoordinator? = nil
    var openSettings: () -> Void = {}

    @StateObject private var model: MusicDownloadModel
    @State private var input = ""
    @State private var groupByAlbum = false
    @State private var notice: String?
    @State private var destination = MusicPreferences.destination
    @AppStorage(MusicPreferences.qualityKey) private var qualityRaw = MusicQualityPreference.best.rawValue
    @AppStorage(MusicPreferences.layoutKey) private var layoutRaw = MusicLayout.artistAlbum.rawValue
    @AppStorage(MusicPreferences.templateKey) private var nameTemplate = MusicNameTemplate.defaultTemplate

    init(downloader: DownloaderService, logins: StreamingSiteLoginStore, onBack: @escaping () -> Void,
         intake: IntakeCoordinator? = nil, openSettings: @escaping () -> Void = {}) {
        self.downloader = downloader
        self.logins = logins
        self.onBack = onBack
        self.intake = intake
        self.openSettings = openSettings
        _model = StateObject(wrappedValue: MusicDownloadModel(downloader: downloader, logins: logins))
    }

    private var quality: MusicQualityPreference { MusicQualityPreference(rawValue: qualityRaw) ?? .best }
    private var layout: MusicLayout { MusicLayout(rawValue: layoutRaw) ?? .artistAlbum }
    private let accent = Color(red: 0.89, green: 0.16, blue: 0.19)

    var body: some View {
        ZStack {
            CinematicBackground(accent: accent)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    inputPanel
                    optionsBar
                    if layout == .custom { templateEditor }
                    content
                    recentJobs
                }
                .frame(maxWidth: 1180)
                .padding(.horizontal, 36)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear(perform: consumePendingInput)
        .onChange(of: intake?.pendingMusicInput) { _, _ in consumePendingInput() }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 16) {
            PageBackButton(action: onBack)
            VStack(alignment: .leading, spacing: 3) {
                Text("音乐下载").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(MediaFetchTheme.primaryText)
                Text("网易云音乐 · QQ 音乐 · 平台原始音质，自动写入标签、封面和歌词")
                    .font(.caption).foregroundStyle(MediaFetchTheme.secondaryText)
            }
            Spacer()
            ForEach([StreamingPlatform.netease, .qqmusic], id: \.self) { platform in
                Button { openSettings() } label: {
                    StatusPill(text: "\(platform.displayName) · \(model.loginSummary(for: platform))",
                               systemImage: model.isLoggedIn(platform) ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.questionmark",
                               color: model.isLoggedIn(platform) ? MediaFetchTheme.success : MediaFetchTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .help("在设置 › 流媒体网站登录 中登录；QQ 音乐必须登录，网易云登录会员后可下载无损")
            }
        }
    }

    private var inputPanel: some View {
        MediaFetchPanel {
            HStack(spacing: 10) {
                Image(systemName: "music.note").foregroundStyle(accent)
                TextField("粘贴单曲、专辑、歌单、歌手或排行榜链接，或 App 里的分享文案", text: $input)
                    .textFieldStyle(.plain)
                    .onSubmit { model.resolve(input) }
                Button { model.resolve(input) } label: {
                    if model.phase == .resolving { ProgressView().controlSize(.small) } else { Label("解析", systemImage: "sparkle.magnifyingglass") }
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.phase == .resolving)
            }
        }
    }

    private var optionsBar: some View {
        HStack(spacing: 16) {
            Picker("音质", selection: $qualityRaw) {
                ForEach(MusicQualityPreference.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .frame(width: 230)
            Picker("整理方式", selection: $layoutRaw) {
                ForEach(MusicLayout.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .frame(width: 260)
            Spacer()
            if let summary = model.indexSummary {
                Button(summary) { model.refreshIndex() }.buttonStyle(.link).help("点击重新索引本地音乐")
            }
            Label(destination.path, systemImage: "folder").lineLimit(1).truncationMode(.middle).frame(maxWidth: 280, alignment: .trailing)
            Button("更改…", action: chooseDestination).buttonStyle(.link)
        }
        .font(.caption)
        .foregroundStyle(MediaFetchTheme.secondaryText)
    }

    private var templateEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("文件名模板").font(.caption).foregroundStyle(MediaFetchTheme.secondaryText)
                TextField(MusicNameTemplate.defaultTemplate, text: $nameTemplate)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
            }
            Text("可用：{artist} {album} {title} {id} {index}，用 / 分隔文件夹 · 示例：\(MusicNameTemplate(nameTemplate).preview())")
                .font(.caption2).foregroundStyle(MediaFetchTheme.secondaryText)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            Text("支持 music.163.com、y.qq.com 的各种链接与分享短链。音质取决于你的账号权益：网易云未登录最高 320k，QQ 音乐需要登录。")
                .font(.callout).foregroundStyle(MediaFetchTheme.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 120)
        case .resolving:
            HStack { ProgressView(); Text("正在解析…").foregroundStyle(MediaFetchTheme.secondaryText) }
                .frame(maxWidth: .infinity, minHeight: 120)
        case .failed(let message):
            MediaFetchPanel {
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(MediaFetchTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    if message.contains("登录") { Button("去登录", action: openSettings).buttonStyle(.bordered) }
                }
            }
        case .single(_, let track):
            singleCard(track)
        case .list(let outline):
            listPanel(outline)
        }
    }

    private func singleCard(_ track: MusicTrackInfo) -> some View {
        MediaFetchPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    artwork(track.thumbnail, size: 96)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(track.title).font(.title3.bold()).foregroundStyle(MediaFetchTheme.primaryText)
                        Text(track.artistLine).foregroundStyle(MediaFetchTheme.secondaryText)
                        if let album = track.album { Text("专辑：\(album)").font(.caption).foregroundStyle(MediaFetchTheme.secondaryText) }
                        HStack(spacing: 6) {
                            ForEach(track.availableTiers, id: \.self) { QualityBadge(tier: $0, emphasized: $0 == quality.expectedTier(from: track.availableTiers)) }
                            if track.hasLyrics { Text("歌词").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule()) }
                        }
                        expectationLine(track)
                        if let match = model.singleLocalMatch { localBanner(match) }
                    }
                    Spacer()
                    if let duration = track.duration { Text(CollectionSheet.format(duration)).font(.caption.monospacedDigit()).foregroundStyle(MediaFetchTheme.secondaryText) }
                }
                downloadBar(count: 1)
            }
        }
    }

    private func listPanel(_ outline: CollectionOutline) -> some View {
        let probed = outline.entries.filter { model.probes[$0.id]?.track != nil }.count
        return MediaFetchPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(outline.title.isEmpty ? outline.id : outline.title).font(.title3.bold()).foregroundStyle(MediaFetchTheme.primaryText)
                        Text("\(outline.entries.count) 首 · 已选 \(model.selected.count) · 已检测音质 \(probed)" +
                             (model.localMatches.isEmpty ? "" : " · 本地已有 \(model.localMatches.count)（默认不选）") +
                             (outline.unavailableCount > 0 ? " · \(outline.unavailableCount) 首当前账号不可见" : ""))
                            .font(.caption).foregroundStyle(MediaFetchTheme.secondaryText)
                    }
                    Spacer()
                    Toggle("按专辑分组", isOn: $groupByAlbum).toggleStyle(.checkbox)
                    if probed < outline.entries.count {
                        Button("检测全部音质") { model.probeAll() }.buttonStyle(.bordered)
                    }
                    Button("全选") { model.toggle(outline.entries, on: true) }.buttonStyle(.link)
                    Button("全不选") { model.selected = [] }.buttonStyle(.link)
                }
                .font(.caption)
                if groupByAlbum {
                    ForEach(model.albumGroups(), id: \.album) { group in
                        HStack {
                            Text(group.album).font(.subheadline.bold()).foregroundStyle(MediaFetchTheme.primaryText)
                            Text("\(group.entries.count) 首").font(.caption).foregroundStyle(MediaFetchTheme.secondaryText)
                            Spacer()
                            Button("选中整张") { model.toggle(group.entries, on: true) }.buttonStyle(.link).font(.caption)
                        }
                        .padding(.top, 6)
                        ForEach(group.entries) { row($0) }
                    }
                } else {
                    ForEach(outline.entries) { row($0) }
                }
                downloadBar(count: model.selected.count)
            }
        }
    }

    private func row(_ entry: CollectionEntry) -> some View {
        let probe = model.probes[entry.id] ?? .pending
        let track = probe.track
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { model.selected.contains(entry.id) },
                                     set: { model.toggle([entry], on: $0) })).toggleStyle(.checkbox).labelsHidden()
            Text(String(format: "%03d", entry.index)).font(.caption.monospacedDigit()).foregroundStyle(MediaFetchTheme.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(track?.title ?? entry.title).lineLimit(1).foregroundStyle(MediaFetchTheme.primaryText)
                Text([track?.artistLine, track?.album].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).lineLimit(1).foregroundStyle(MediaFetchTheme.secondaryText)
            }
            Spacer()
            if let match = model.localMatches[entry.id] {
                Text(match.isExact ? "本地已有" : "本地可能已有")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(MediaFetchTheme.success.opacity(0.18), in: Capsule())
                    .foregroundStyle(MediaFetchTheme.success)
                    .help(match.path)
            }
            switch probe {
            case .pending:
                Button("检测") { model.probe([entry]) }.buttonStyle(.link).font(.caption)
            case .loading:
                ProgressView().controlSize(.mini)
            case .failed(let message):
                Label(message.contains("登录") ? "需要登录" : "不可用", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(MediaFetchTheme.warning).help(message)
            case .loaded(let track):
                HStack(spacing: 4) {
                    if let expected = quality.expectedTier(from: track.availableTiers) {
                        QualityBadge(tier: expected, emphasized: true)
                    } else {
                        Text(quality == .losslessOnly ? "无无损" : "无匹配音质").font(.caption2).foregroundStyle(MediaFetchTheme.warning)
                    }
                    if let best = track.bestTier, best != quality.expectedTier(from: track.availableTiers) {
                        Text("最高 \(best.displayName)").font(.caption2).foregroundStyle(MediaFetchTheme.secondaryText)
                    }
                }
            }
            Text(entry.duration.map(CollectionSheet.format) ?? track?.duration.map(CollectionSheet.format) ?? "")
                .font(.caption.monospacedDigit()).foregroundStyle(MediaFetchTheme.secondaryText).frame(width: 48, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private func localBanner(_ match: LocalMusicIndex.Match) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(MediaFetchTheme.success)
            Text(match.isExact ? "本地已有这首歌" : "本地可能已有（歌名、歌手、时长一致）")
            Button("显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: match.path)]) }.buttonStyle(.link)
        }
        .font(.caption)
    }

    private func expectationLine(_ track: MusicTrackInfo) -> some View {
        Group {
            if let tier = quality.expectedTier(from: track.availableTiers) {
                Text("将下载：\(tier.displayName)").font(.caption).foregroundStyle(MediaFetchTheme.success)
            } else if track.formats.isEmpty {
                Text("平台没有返回可下载的格式（可能需要登录或版权受限）").font(.caption).foregroundStyle(MediaFetchTheme.warning)
            } else {
                Text("当前账号没有「\(quality.displayName)」可用；最高 \(track.bestTier?.displayName ?? "-")").font(.caption).foregroundStyle(MediaFetchTheme.warning)
            }
        }
    }

    private func downloadBar(count: Int) -> some View {
        HStack {
            Button {
                let result = model.enqueue(quality: quality, layout: layout, destination: destination, nameTemplate: nameTemplate)
                var parts: [String] = []
                if result.queued > 0 { parts.append("已加入 \(result.queued) 首") }
                if !result.skipped.isEmpty { parts.append("跳过 \(result.skipped.count) 首（没有「\(quality.displayName)」）：" + result.skipped.prefix(3).joined(separator: "、")) }
                notice = parts.isEmpty ? downloader.errorMessage : parts.joined(separator: "；")
            } label: {
                Label("下载\(count > 1 ? "选中的 \(count) 首" : "")", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .controlSize(.large)
            .disabled(count == 0)
            if let notice { Text(notice).font(.caption).foregroundStyle(MediaFetchTheme.secondaryText) }
            Spacer()
        }
        .padding(.top, 6)
    }

    private var recentJobs: some View {
        let jobs = downloader.jobs.filter { $0.musicQuality != nil }.suffix(8).reversed()
        return VStack(alignment: .leading, spacing: 8) {
            if !jobs.isEmpty {
                Text("最近的音乐任务").font(.headline).foregroundStyle(MediaFetchTheme.primaryText).padding(.top, 8)
            }
            ForEach(Array(jobs)) { job in
                HStack(spacing: 10) {
                    Image(systemName: job.status.symbolName).foregroundStyle(job.status.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.title ?? job.sourceURL).lineLimit(1).foregroundStyle(MediaFetchTheme.primaryText)
                        if [.downloading, .packaging].contains(job.status) { StageBar(job: job) }
                        else if let error = job.errorMessage { Text(error).font(.caption).lineLimit(1).foregroundStyle(MediaFetchTheme.danger) }
                    }
                    Spacer()
                    if let audio = job.audioQuality {
                        QualityBadge(tier: audio.tier, emphasized: true).help(audio.summary)
                        if !audio.meetsExpectation {
                            Label("低于平台标称", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(MediaFetchTheme.warning)
                                .help("平台标称 \(audio.expectedTier?.displayName ?? "-")，实际文件 \(audio.summary)")
                        }
                    }
                    if let manifest = job.manifestPath {
                        Button("显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: manifest).deletingLastPathComponent()]) }
                            .buttonStyle(.link)
                        ResolveSendButton(target: .package(URL(fileURLWithPath: manifest).deletingLastPathComponent()))
                    }
                    Text(job.status.displayName).font(.caption).foregroundStyle(MediaFetchTheme.secondaryText)
                }
                .font(.subheadline)
            }
        }
    }

    // MARK: Helpers

    private func artwork(_ url: String?, size: CGFloat) -> some View {
        AsyncImage(url: url.flatMap { URL(string: $0.replacingOccurrences(of: "http://", with: "https://")) }) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack { MediaFetchTheme.surfaceSecondary; Image(systemName: "music.note").foregroundStyle(MediaFetchTheme.secondaryText) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func consumePendingInput() {
        guard let pending = intake?.pendingMusicInput else { return }
        intake?.pendingMusicInput = nil
        input = pending
        model.resolve(pending)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = destination
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = url
        UserDefaults.standard.set(url.path, forKey: MusicPreferences.destinationKey)
    }
}

struct QualityBadge: View {
    let tier: MusicQualityTier
    var emphasized = false

    var body: some View {
        Text(tier.displayName)
            .font(.caption2.weight(emphasized ? .bold : .regular))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tier.isLossless ? Color(red: 0.95, green: 0.78, blue: 0.35) : MediaFetchTheme.primaryText)
            .background((tier.isLossless ? Color(red: 0.95, green: 0.78, blue: 0.35) : MediaFetchTheme.secondaryText).opacity(emphasized ? 0.25 : 0.12),
                        in: Capsule())
    }
}
#endif
