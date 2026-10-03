import AppKit
import SwiftUI
import MediaFetchCore
import MediaFetchVideo

struct VideoDownloadView: View {
    @ObservedObject var downloader: DownloaderService
    @ObservedObject var loginStore: StreamingSiteLoginStore
    let onBack: () -> Void
    var intake: IntakeCoordinator? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
#if !MEDIAFETCH_STORE_PROFILE
    @State private var mediaURL = ""
    @State private var profile: DownloadProfile = .highest
    @State private var destination = Self.initialDestination()
    @State private var scopedDestination: URL?
    @State private var didRestoreDestination = false
    @State private var genericUseBrowserCookies = false
    @State private var genericBrowserCookieSource: BrowserCookieSource = .recommendedDefault
    @State private var includeSidecars = true
    @State private var includeSubtitles = true
    @State private var showsPreflight = false
    @State private var preflightReport: BatchPreflight.Report?
    @State private var preflightTask: Task<Void, Never>?
    @State private var collectionPhase: CollectionSheet.Phase?
#endif

    var body: some View {
#if MEDIAFETCH_STORE_PROFILE
        storeRestrictedBody
#else
        localDownloadBody
#endif
    }

#if MEDIAFETCH_STORE_PROFILE
    private var storeRestrictedBody: some View {
        ZStack {
            CinematicBackground(accent: MediaFetchTheme.videoAccent)
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    PageBackButton(action: onBack)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("视频素材")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(MediaFetchTheme.primaryText)
                        Text("Mac App Store 版本")
                            .font(.caption)
                            .foregroundStyle(MediaFetchTheme.secondaryText)
                    }
                }

                MediaFetchPanel {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("商店版未启用第三方站点音视频下载", systemImage: "checkmark.shield.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(MediaFetchTheme.primaryText)
                        Text("为了符合 Mac App Store 的第三方媒体与自包含要求，商店版不运行通用站点提取器、不读取浏览器 Cookie，也不下载或执行外部工具。请使用本地完整版处理你有权保存的站点媒体。")
                            .font(.body)
                            .foregroundStyle(MediaFetchTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("音乐页面仍可使用 Spotify 曲目顺序整理你拥有的本地音频，并生成可复核的素材包。")
                            .font(.subheadline)
                            .foregroundStyle(MediaFetchTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: 880)
            .padding(38)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
#else
    private var localDownloadBody: some View {
        ZStack {
            LinearGradient(
                colors: [MediaFetchTheme.background, MediaFetchTheme.videoAccent.opacity(0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    linkPanel
                    if let metadata = downloader.metadata { metadataPanel(metadata) }
                    downloadPanel
                    statusPanel
                    queuePanel
                    legalNote
                }
                .padding(32)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            restoreDestinationBookmarkIfNeeded()
            consumePendingInput()
        }
        .onChange(of: intake?.pendingVideoInput) { _, _ in consumePendingInput() }
        .onChange(of: mediaURL) { _, text in expandShortMusicLinks(text) }
        .sheet(isPresented: Binding(get: { collectionPhase != nil }, set: { if !$0 { collectionPhase = nil } })) {
            if let phase = collectionPhase {
                CollectionSheet(phase: phase) { outline, entries in
                    collectionPhase = nil
                    let url = URL(string: entries.first?.url ?? "")
                    let login = url.map { (cookieSource(for: $0), inAppLoginURLs.contains($0.absoluteString)) }
                    downloader.enqueueCollection(
                        outline, entries: entries, profile: profile, destination: destination,
                        includeSidecars: includeSidecars, includeSubtitles: includeSubtitles,
                        cookieSource: collectionCookieSource ?? login?.0,
                        usesInAppLogin: collectionUsesInApp || (login?.1 ?? false)
                    )
                } onCancel: {
                    collectionPhase = nil
                }
            }
        }
        .sheet(isPresented: $showsPreflight) {
            BatchPreflightSheet(report: preflightReport) { urls in
                showsPreflight = false
                downloader.enqueue(
                    urls.joined(separator: "\n"), profile: profile, destination: destination,
                    includeSidecars: includeSidecars, includeSubtitles: includeSubtitles,
                    cookieSourceByURL: cookieSourcesByURL, inAppLoginURLs: inAppLoginURLs
                )
            } onCancel: {
                preflightTask?.cancel()
                showsPreflight = false
            }
        }
        .onDisappear {
            releaseDestinationScope()
        }
        .alert("操作未完成", isPresented: Binding(
            get: { downloader.errorMessage != nil },
            set: { if !$0 { downloader.errorMessage = nil } }
        )) {
            Button("知道了") { downloader.errorMessage = nil }
        } message: {
            Text(downloader.errorMessage ?? String(localized: "未知错误"))
        }
        .alert("Safari Cookie 受到 macOS 保护", isPresented: $downloader.safariPermissionRequired) {
            Button("改用 Chrome") {
                useChromeForCurrentPlatform()
            }
            Button("打开完整磁盘访问") { openFullDiskAccessSettings() }
            Button("稍后", role: .cancel) {}
        } message: {
            Text("\(MediaFetchRelease.displayName) 没有权限读取 Safari 登录状态。推荐改用已登录 Vimeo 的 Chrome；或者在“系统设置 → 隐私与安全性 → 完整磁盘访问”中加入并启用 \(MediaFetchRelease.displayName)，然后退出并重新打开应用。")
        }
    }
#endif

#if !MEDIAFETCH_STORE_PROFILE
    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(MediaFetchTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(MediaFetchTheme.border, lineWidth: 1)
            }
            .help("返回首页")
            .accessibilityLabel("返回首页")

            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(MediaFetchTheme.videoAccent)
            VStack(alignment: .leading, spacing: 4) {
                Text(MediaFetchRelease.displayName)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(MediaFetchTheme.primaryText)
                Text("把平台实际提供的最高质量媒体保存到本机")
                    .foregroundStyle(MediaFetchTheme.secondaryText)
            }
            Spacer()
            dependencyBadge
        }
    }

    private var dependencyBadge: some View {
        Label(
            downloader.dependenciesReady ? String(localized: "下载引擎就绪") : String(localized: "缺少下载引擎"),
            systemImage: downloader.dependenciesReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(downloader.dependenciesReady ? .green : .orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            if reduceTransparency {
                Capsule().fill(MediaFetchTheme.surfaceSecondary)
            } else {
                Capsule().fill(.thinMaterial)
            }
        }
    }

    private var linkPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    TextEditor(text: $mediaURL)
                        .font(.body)
                        .frame(minHeight: 54, maxHeight: 90)
                        .padding(5)
                        .background(.background, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
                        .overlay(alignment: .topLeading) {
                            if mediaURL.isEmpty {
                                Text("粘贴 YouTube、哔哩哔哩、优酷、Vimeo 或其他媒体链接")
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 13)
                                    .allowsHitTesting(false)
                            }
                        }
                    Button {
                        analyzeMedia()
                    } label: {
                        if downloader.isAnalyzing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("解析", systemImage: "sparkle.magnifyingglass")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(downloader.isAnalyzing || downloader.isDownloading || containsBlockedPlatform)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(StreamingPlatform.featuredDownloadable) { platform in
                            Label(platform.displayName, systemImage: platform.systemImage)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(.quaternary.opacity(0.55), in: Capsule())
                        }
                    }
                }

                if let platform = detectedPlatform {
                    Label("已识别：\(platform.displayName)", systemImage: platform.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(platformColor(platform))
                    if let restriction = platform.restrictionMessage {
                        Text(restriction)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if let hint = platform.loginHint, selectedCookieSource == nil {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                if inputURLs.count > 1 {
                    Label("已检测到 \(inputURLs.count) 条有效链接，将依次加入队列。", systemImage: "list.number")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        } label: {
            Text("媒体链接").font(.headline)
        }
    }

    private func metadataPanel(_ metadata: MediaMetadata) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 18) {
                    if let thumbnail = metadata.thumbnail, let url = URL(string: thumbnail) {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            ZStack { Color.secondary.opacity(0.1); ProgressView() }
                        }
                        .frame(width: 200, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        Text(metadata.title).font(.headline).lineLimit(3)
                        if let uploader = metadata.uploader {
                            Label(uploader, systemImage: "person.crop.circle")
                        }
                        HStack(spacing: 18) {
                            Label(metadata.maximumResolution, systemImage: "rectangle.inset.filled")
                            Label(metadata.durationText, systemImage: "clock")
                            if let extractor = metadata.extractor {
                                Label(extractor, systemImage: "network")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Divider()
                Text("格式检查器").font(.subheadline.weight(.semibold))
                formatHeader
                ForEach(Array(metadata.videoFormatsForInspection.prefix(6))) { format in
                    formatRow(format)
                }
                if !metadata.audioFormatsForInspection.isEmpty {
                    Text("独立音频流").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(metadata.audioFormatsForInspection.prefix(3))) { format in
                        formatRow(format)
                    }
                }
            }
            .padding(6)
        } label: {
            Text("已解析媒体").font(.headline)
        }
    }

    private var downloadPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 15) {
                Picker("保存方式", selection: $profile) {
                    ForEach(DownloadProfile.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .pickerStyle(.menu)

                Text(profile.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("生成完整素材包（缩略图和平台 info.json）", isOn: $includeSidecars)
                Toggle("保存可用的中英文人工字幕与自动字幕", isOn: $includeSubtitles)
                Text("每个任务会建立独立文件夹，并生成包含 SHA-256 与格式来源的 manifest.json。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                siteLoginControls

                HStack {
                    Label(destination.path, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("选择文件夹…") { chooseDestination() }
                }

                Divider()

                HStack {
                    if downloader.isDownloading {
                        Button(role: .destructive) { downloader.cancel() } label: {
                            Label("取消", systemImage: "stop.fill")
                        }
                    } else {
                        Button {
                            downloader.enqueue(
                                mediaURL,
                                profile: profile,
                                destination: destination,
                                includeSidecars: includeSidecars,
                                includeSubtitles: includeSubtitles,
                                cookieSourceByURL: cookieSourcesByURL,
                                inAppLoginURLs: inAppLoginURLs
                            )
                        } label: {
                            Label("加入下载队列", systemImage: "text.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(mediaURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || containsBlockedPlatform)
                        if let collectionURL {
                            Button {
                                expandCollection(collectionURL)
                            } label: {
                                Label("展开课程 / 播放列表", systemImage: "list.bullet.indent")
                            }
                            .controlSize(.large)
                        }
                        if inputURLs.count > 1 {
                            Button {
                                runPreflight()
                            } label: {
                                Label("先预检 \(inputURLs.count) 条链接", systemImage: "checklist")
                            }
                            .controlSize(.large)
                        }
                    }
                    Spacer()
                }
            }
            .padding(6)
        } label: {
            Text("下载设置").font(.headline)
        }
    }

    private var statusPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(downloader.status).fontWeight(.medium)
                    Spacer()
                    Text(downloader.progress.percentText).monospacedDigit()
                }
                ProgressView(value: downloader.progress.fraction)
                HStack {
                    if !downloader.progress.speedText.isEmpty {
                        Text("速度 \(downloader.progress.speedText)")
                    }
                    if !downloader.progress.etaText.isEmpty {
                        Text("剩余 \(downloader.progress.etaText) 秒")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(downloader.completedFiles, id: \.self) { path in
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    } label: {
                        Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "checkmark.circle.fill")
                            .lineLimit(1)
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(6)
        } label: {
            Text("状态").font(.headline)
        }
    }

    private var queuePanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(downloader.jobs.count) 个任务")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if downloader.hasResumableJobs && !downloader.isDownloading {
                        Button("继续队列") { downloader.resumeQueue() }
                    }
                    Button("清除已结束记录") { downloader.clearFinishedHistory() }
                        .disabled(downloader.isDownloading)
                }

                if downloader.jobs.isEmpty {
                    Text("尚无任务。任务历史会保存在本机应用支持目录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(downloader.jobs.reversed()) { job in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Image(systemName: job.status.symbolName)
                                    .foregroundStyle(job.status.tint)
                                Text(job.title ?? job.sourceURL)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Spacer()
                                Text(job.status.displayName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(job.status.tint)
                                Text(job.progressText).font(.caption.monospacedDigit())
                            }
                            ProgressView(value: job.progressFraction)
                            HStack {
                                Text(job.profile.displayName)
                                if let source = job.browserCookieSource {
                                    Text("· \(source.displayName) 登录态")
                                }
                                Spacer()
                                if let manifestPath = job.manifestPath {
                                    Button("显示素材包") { openPath(manifestPath) }
                                        .buttonStyle(.link)
                                } else if let first = job.completedFiles.first {
                                    Button("显示文件") { openPath(first) }
                                        .buttonStyle(.link)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if let error = job.errorMessage {
                                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                            }
                        }
                        .padding(10)
                        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
            .padding(6)
        } label: {
            Text("下载队列与历史").font(.headline)
        }
    }

    private var legalNote: some View {
        Label(
            String(localized: "请只下载你拥有权利、已获许可，或平台明确允许保存的内容。本应用不绕过 DRM 或付费访问控制。"),
            systemImage: "checkmark.shield"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination
        if panel.runModal() == .OK, let selected = panel.url {
            destination = selected
            beginDestinationScope(selected)
            try? SecurityScopedBookmarkStore(key: "MediaFetch.video.destination").save(selected)
        }
    }

    private func restoreDestinationBookmarkIfNeeded() {
        guard !didRestoreDestination else { return }
        didRestoreDestination = true
        let store = SecurityScopedBookmarkStore(key: "MediaFetch.video.destination")
        guard let restored = store.resolve() else { return }
        beginDestinationScope(restored)
        destination = restored
    }

    private func beginDestinationScope(_ url: URL) {
        guard url.isFileURL, scopedDestination != url else { return }
        releaseDestinationScope()
        if url.startAccessingSecurityScopedResource() {
            scopedDestination = url
        }
    }

    private func releaseDestinationScope() {
        guard let scopedDestination else { return }
        scopedDestination.stopAccessingSecurityScopedResource()
        self.scopedDestination = nil
    }

    private static func initialDestination() -> URL {
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    private var selectedCookieSource: BrowserCookieSource? {
        guard let url = inputURLs.first else {
            return genericUseBrowserCookies ? genericBrowserCookieSource : nil
        }
        return cookieSource(for: url)
    }

    /// The list URL to expand, if the input is a course/playlist (or a watch URL with `list=`).
    private var collectionURL: URL? {
        guard inputURLs.count == 1, let url = inputURLs.first else { return nil }
        if CollectionDetector.looksLikeCollection(url) { return url }
        if CollectionDetector.hasPlaylistContext(url),
           let list = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "list" })?.value {
            return URL(string: "https://www.youtube.com/playlist?list=\(list)")
        }
        return nil
    }

    private var collectionCookieSource: BrowserCookieSource? { collectionURL.flatMap(cookieSource(for:)) }
    private var collectionUsesInApp: Bool { collectionURL.map { inAppLoginURLs.contains($0.absoluteString) || isInAppPlatform($0) } ?? false }

    private func isInAppPlatform(_ url: URL) -> Bool {
        let platform = StreamingPlatform.detect(url)
        return loginStore.isEnabled(for: platform) && loginStore.method(for: platform) == .inApp
    }

    private func expandCollection(_ url: URL) {
        collectionPhase = .loading
        Task {
            do {
                let outline = try await downloader.expandCollection(url, cookieSource: cookieSource(for: url),
                                                                    usesInAppLogin: isInAppPlatform(url))
                if collectionPhase != nil { collectionPhase = .loaded(outline) }
            } catch {
                if collectionPhase != nil { collectionPhase = .failed(error.localizedDescription) }
            }
        }
    }

    private func runPreflight() {
        preflightReport = nil
        showsPreflight = true
        let urls = inputURLs
        preflightTask = Task {
            let report = await downloader.preflight(
                urls: urls, profile: profile, destination: destination,
                cookieSourceByURL: cookieSourcesByURL, inAppLoginURLs: inAppLoginURLs
            )
            if !Task.isCancelled { preflightReport = report }
        }
    }

    /// Music-app share links (163cn.tv, c6.y.qq.com) are swapped for their real
    /// page URL in place, so the user sees exactly what will be resolved.
    private func expandShortMusicLinks(_ text: String) {
        guard LinkInputParser.candidates(in: text).contains(where: { URL(string: $0).map(MusicLink.needsRedirectResolution) ?? false }) else { return }
        Task {
            let resolved = await MusicLinkResolver().resolveShortLinks(in: text)
            if resolved != text && mediaURL == text {
                mediaURL = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    /// Input routed from the home box, the hotkey or another app.
    private func consumePendingInput() {
        guard let pending = intake?.pendingVideoInput else { return }
        intake?.pendingVideoInput = nil
        mediaURL = pending
        // Courses and playlists go straight to the lesson picker.
        if let collectionURL, CollectionDetector.looksLikeCollection(inputURLs[0]) {
            expandCollection(collectionURL)
        } else if inputURLs.count == 1 && !downloader.isAnalyzing && !downloader.isDownloading {
            analyzeMedia()
        }
    }

    private func analyzeMedia() {
        downloader.analyze(mediaURL, cookieSource: selectedCookieSource,
                           usesInAppLogin: inputURLs.first.map { inAppLoginURLs.contains($0.absoluteString) } ?? false)
    }

    private var inAppLoginURLs: Set<String> {
        Set(inputURLs.filter {
            let platform = StreamingPlatform.detect($0)
            return loginStore.isEnabled(for: platform) && loginStore.method(for: platform) == .inApp
        }.map(\.absoluteString))
    }

    private var cookieSourcesByURL: [String: BrowserCookieSource] {
        inputURLs.reduce(into: [:]) { result, url in
            if let source = cookieSource(for: url) {
                result[url.absoluteString] = source
            }
        }
    }

    private func cookieSource(for url: URL) -> BrowserCookieSource? {
        let platform = StreamingPlatform.detect(url)
        if StreamingPlatform.browserLoginPlatforms.contains(platform) {
            return loginStore.cookieSource(for: platform)
        }
        return genericUseBrowserCookies ? genericBrowserCookieSource : nil
    }

    private func useChromeForCurrentPlatform() {
        if let platform = detectedPlatform,
           StreamingPlatform.browserLoginPlatforms.contains(platform) {
            loginStore.setBrowser(.chrome, for: platform)
            loginStore.setMethod(.browser, for: platform)
            loginStore.setEnabled(true, for: platform)
        } else {
            genericBrowserCookieSource = .chrome
            genericUseBrowserCookies = true
        }
    }

    @ViewBuilder
    private var siteLoginControls: some View {
        if let platform = detectedPlatform,
           StreamingPlatform.browserLoginPlatforms.contains(platform) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button {
                        loginStore.beginInAppLogin(for: platform)
                    } label: {
                        Label(String(localized: "登录 ") + platform.displayName, systemImage: "person.crop.rectangle")
                    }.buttonStyle(.borderedProminent)
                    Text(loginStore.method(for: platform) == .inApp ? String(localized: "应用内会话") : String(localized: "外部浏览器兼容方式"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                Toggle(
                    String(localized: "使用 \(platform.displayName) 登录会话"),
                    isOn: Binding(
                        get: { loginStore.isEnabled(for: platform) },
                        set: { loginStore.setEnabled($0, for: platform) }
                    )
                )

                if loginStore.isEnabled(for: platform) && loginStore.method(for: platform) == .inApp {
                    Text("使用 \(MediaFetchRelease.displayName) 登录窗口中的会话；若解析提示需要登录，请重新打开登录窗口。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if loginStore.isEnabled(for: platform) && loginStore.method(for: platform) == .browser {
                    HStack(spacing: 12) {
                        Picker(
                            String(localized: "读取登录状态"),
                            selection: Binding(
                                get: { loginStore.browser(for: platform) },
                                set: { loginStore.setBrowser($0, for: platform) }
                            )
                        ) {
                            ForEach(BrowserCookieSource.allCases) { browser in
                                Text(browser.displayName).tag(browser)
                            }
                        }
                        .pickerStyle(.menu)

                        Button {
                            loginStore.openLoginPage(for: platform)
                        } label: {
                            Label("打开 \(platform.displayName) 登录页", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.bordered)

                        Spacer()
                    }

                    Label(
                        String(localized: "下载引擎将读取所选浏览器的 Cookie 库，\(MediaFetchRelease.displayName) 不持久化导出的 Cookie。"),
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if loginStore.browser(for: platform) == .safari {
                        HStack {
                            Label("Safari Cookie 受 macOS 保护，需要为 \(MediaFetchRelease.displayName) 开启完整磁盘访问。", systemImage: "exclamationmark.shield")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("打开系统设置") { openFullDiskAccessSettings() }
                                .buttonStyle(.link)
                        }
                    }
                }
            }
        } else if detectedPlatform?.downloadAllowed != false {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("为通用链接使用浏览器登录状态", isOn: $genericUseBrowserCookies)
                if genericUseBrowserCookies {
                    Picker("读取登录状态", selection: $genericBrowserCookieSource) {
                        ForEach(BrowserCookieSource.allCases) { browser in
                            Text(browser.displayName).tag(browser)
                        }
                    }
                    .pickerStyle(.menu)
                    Label("通用登录设置只作用于未识别的网站链接。", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var formatHeader: some View {
        HStack {
            Text("ID").frame(width: 54, alignment: .leading)
            Text("分辨率").frame(width: 105, alignment: .leading)
            Text("FPS").frame(width: 44, alignment: .leading)
            Text("容器").frame(width: 52, alignment: .leading)
            Text("编码").frame(maxWidth: .infinity, alignment: .leading)
            Text("码率").frame(width: 70, alignment: .trailing)
            Text("大小").frame(width: 82, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func formatRow(_ format: MediaMetadata.Format) -> some View {
        HStack {
            Text(format.formatID ?? "—").frame(width: 54, alignment: .leading)
            Text(format.resolutionText).frame(width: 105, alignment: .leading)
            Text(format.fps.map { String(Int($0.rounded())) } ?? "—").frame(width: 44, alignment: .leading)
            Text(format.extensionName?.uppercased() ?? "—").frame(width: 52, alignment: .leading)
            Text(format.codecText.isEmpty ? "—" : format.codecText)
                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            Text(format.bitrateText).frame(width: 70, alignment: .trailing)
            Text(format.sizeText).frame(width: 82, alignment: .trailing)
        }
        .font(.caption.monospaced())
    }



    private func openPath(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func openFullDiskAccessSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ]
        for value in urls {
            if let url = URL(string: value), NSWorkspace.shared.open(url) { return }
        }
    }

    private var inputURLs: [URL] {
        LinkInputParser.URLs(from: mediaURL)
    }

    private var detectedPlatform: StreamingPlatform? {
        inputURLs.first.map(StreamingPlatform.detect)
    }

    private var containsBlockedPlatform: Bool {
        inputURLs.contains { !StreamingPlatform.detect($0).downloadAllowed }
    }

    private func platformColor(_ platform: StreamingPlatform) -> Color {
        switch platform.supportLevel {
        case .supported: return .green
        case .loginRecommended: return .orange
        case .generic: return .blue
        case .spotifyBridge: return MediaFetchTheme.musicPurple
        case .drmBlocked: return .red
        }
    }
#endif
}
