import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var downloader = DownloaderService()
    @State private var mediaURL = ""
    @State private var profile: DownloadProfile = .highest
    @State private var destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    @State private var useBrowserCookies = false
    @State private var browserCookieSource: BrowserCookieSource = .recommendedDefault
    @State private var includeSidecars = true
    @State private var includeSubtitles = true

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color.blue.opacity(0.07)],
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
            }
        }
        .alert("操作未完成", isPresented: Binding(
            get: { downloader.errorMessage != nil },
            set: { if !$0 { downloader.errorMessage = nil } }
        )) {
            Button("知道了") { downloader.errorMessage = nil }
        } message: {
            Text(downloader.errorMessage ?? "未知错误")
        }
        .alert("Safari Cookie 受到 macOS 保护", isPresented: $downloader.safariPermissionRequired) {
            Button("改用 Chrome") {
                browserCookieSource = .chrome
                useBrowserCookies = true
            }
            Button("打开完整磁盘访问") { openFullDiskAccessSettings() }
            Button("稍后", role: .cancel) {}
        } message: {
            Text("MediaFetch 没有权限读取 Safari 登录状态。推荐改用已登录 Vimeo 的 Chrome；或者在“系统设置 → 隐私与安全性 → 完整磁盘访问”中加入并启用 MediaFetch，然后退出并重新打开应用。")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text("MediaFetch")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("把平台实际提供的最高质量媒体保存到本机")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            dependencyBadge
        }
    }

    private var dependencyBadge: some View {
        Label(
            downloader.dependenciesReady ? "下载引擎就绪" : "缺少下载引擎",
            systemImage: downloader.dependenciesReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(downloader.dependenciesReady ? .green : .orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.thinMaterial, in: Capsule())
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
                    } else if let hint = platform.loginHint, !useBrowserCookies {
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
                        Text(item.rawValue).tag(item)
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

                Toggle("使用浏览器登录状态（高画质、私有或账户可见内容）", isOn: $useBrowserCookies)
                if useBrowserCookies {
                    HStack {
                        Picker("读取登录状态", selection: $browserCookieSource) {
                            ForEach(BrowserCookieSource.allCases) { browser in
                                Text(browser.displayName).tag(browser)
                            }
                        }
                        .pickerStyle(.menu)
                        Spacer()
                        Label("本机 yt-dlp 会读取该浏览器 Cookie 库；MediaFetch 不保存 Cookie 文件", systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if browserCookieSource == .safari {
                        HStack {
                            Label("Safari Cookie 受 macOS 保护，需要为 MediaFetch 开启完整磁盘访问。", systemImage: "exclamationmark.shield")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("打开系统设置") { openFullDiskAccessSettings() }
                                .buttonStyle(.link)
                        }
                    }
                }

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
                                cookieSource: selectedCookieSource
                            )
                        } label: {
                            Label("加入下载队列", systemImage: "text.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(mediaURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || containsBlockedPlatform)
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
                    Text("尚无任务。任务历史会保存在本机 Application Support/MediaFetch。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(downloader.jobs.reversed()) { job in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Image(systemName: statusIcon(job.status))
                                    .foregroundStyle(statusColor(job.status))
                                Text(job.title ?? job.sourceURL)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Spacer()
                                Text(job.status.displayName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(statusColor(job.status))
                                Text(job.progressText).font(.caption.monospacedDigit())
                            }
                            ProgressView(value: job.progressFraction)
                            HStack {
                                Text(job.profile.rawValue)
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
            "请只下载你拥有权利、已获许可，或平台明确允许保存的内容。本应用不绕过 DRM 或付费访问控制。",
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
        }
    }

    private var selectedCookieSource: BrowserCookieSource? {
        useBrowserCookies ? browserCookieSource : nil
    }

    private func analyzeMedia() {
        downloader.analyze(mediaURL, cookieSource: selectedCookieSource)
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

    private func statusIcon(_ status: DownloadJobStatus) -> String {
        switch status {
        case .queued, .paused: return "clock"
        case .downloading: return "arrow.down.circle.fill"
        case .packaging: return "checkmark.shield"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle"
        }
    }

    private func statusColor(_ status: DownloadJobStatus) -> Color {
        switch status {
        case .queued, .paused: return .secondary
        case .downloading, .packaging: return .blue
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
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
        case .drmBlocked: return .red
        }
    }
}
