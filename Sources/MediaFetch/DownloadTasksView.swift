import AppKit
import SwiftUI
import MediaFetchCore
import MediaFetchVideo

enum TaskSection: String, CaseIterable {
    case video = "视频"
    case torrent = "Torrent"
    case tools = "处理"

    var displayName: String { L10n.string(rawValue) }
}

struct DownloadTasksView: View {
    @ObservedObject var downloader: DownloaderService
    @State private var section: TaskSection = .video
    @State private var showMove = false
    let onBack: () -> Void
    let openVideo: () -> Void
    var openSettings: () -> Void = {}
    var openTorrent: () -> Void = {}
    var openTools: ([URL]) -> Void = { _ in }

    var body: some View {
        ZStack {
            CinematicBackground(accent: MediaFetchTheme.videoAccent)

            VStack(spacing: 0) {
                header
#if !MEDIAFETCH_STORE_PROFILE
                Picker("任务类型", selection: $section) {
                    ForEach(TaskSection.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 14)
                switch section {
                case .video:
                    videoSection
                case .torrent:
                    ScrollView { TorrentTaskList(openTorrent: openTorrent).padding(.bottom, 12) }
                case .tools:
                    ScrollView { ToolTaskList(openTools: { openTools([]) }).padding(.bottom, 12) }
                }
#else
                videoSection
#endif
            }
            .frame(maxWidth: 1180)
            .padding(.horizontal, 36)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            PageBackButton(action: onBack)
            VStack(alignment: .leading, spacing: 3) {
                Text(pageTitle)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(MediaFetchTheme.primaryText)
                Text(pageSubtitle)
                    .font(.caption)
                    .foregroundStyle(MediaFetchTheme.secondaryText)
            }
            Spacer()

            if downloader.hasResumableJobs && !downloader.isDownloading {
                Button {
                    downloader.resumeQueue()
                } label: {
                    Label("继续队列", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }

            if downloader.isDownloading {
                Button {
                    downloader.isSuspended ? downloader.resumeCurrent() : downloader.suspendCurrent()
                } label: {
                    Label(downloader.isSuspended ? String(localized: "继续") : String(localized: "暂停"),
                          systemImage: downloader.isSuspended ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    downloader.cancel()
                } label: {
                    Label("取消当前任务", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            }

#if !MEDIAFETCH_STORE_PROFILE
            Button {
                showMove = true
            } label: {
                Label("移动到…", systemImage: "folder.badge.gearshape")
            }
            .buttonStyle(.bordered)
            .help("把已完成的素材包移动到另一个文件夹")
            .sheet(isPresented: $showMove) {
                MovePackagesSheet(downloader: downloader, musicOnly: false) { showMove = false }
            }
#endif

            Button("清除已结束记录") {
                downloader.clearFinishedHistory()
            }
            .buttonStyle(.bordered)
            .disabled(downloader.isDownloading)
        }
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private var videoSection: some View {
        if downloader.jobs.isEmpty {
            emptyState
        } else {
            taskList
        }
    }

    private var emptyState: some View {
        MediaFetchPanel {
            VStack(spacing: 18) {
                Image(systemName: "tray")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(MediaFetchTheme.secondaryText)
                Text(emptyTitle)
                    .font(.title3.bold())
                    .foregroundStyle(MediaFetchTheme.primaryText)
                Text(emptyMessage)
                    .font(.subheadline)
                    .foregroundStyle(MediaFetchTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
#if !MEDIAFETCH_STORE_PROFILE
                Button("前往视频", action: openVideo)
                    .buttonStyle(.borderedProminent)
#endif
            }
            .frame(maxWidth: .infinity, minHeight: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var taskList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(downloader.jobs.reversed()) { job in
                    taskRow(job)
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func taskRow(_ job: DownloadJob) -> some View {
        MediaFetchPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: job.status.symbolName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(job.status.tint)
                        .frame(width: 34, height: 34)
                        .background(job.status.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.title ?? job.sourceURL)
                            .font(.headline)
                            .foregroundStyle(MediaFetchTheme.primaryText)
                            .lineLimit(1)
                        Text(job.sourceURL)
                            .font(.caption)
                            .foregroundStyle(MediaFetchTheme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    StatusPill(
                        text: job.status.displayName,
                        systemImage: job.status.symbolName,
                        color: job.status.tint
                    )

                    Text(job.progressText)
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(MediaFetchTheme.primaryText)
                        .frame(width: 54, alignment: .trailing)
                }

                ProgressView(value: job.progressFraction)
                    .tint(job.status.tint)
                if [.downloading, .packaging, .suspended, .completed].contains(job.status) {
                    StageBar(job: job)
                }

                HStack(spacing: 7) {
                    Text(job.musicQuality.map { String(localized: "音乐 · \($0.displayName)") } ?? job.profile.displayName)
                    if let audio = job.audioQuality {
                        Text("· 实测 \(audio.summary)")
                            .foregroundStyle(audio.meetsExpectation ? MediaFetchTheme.secondaryText : MediaFetchTheme.warning)
                    }
                    if job.musicCoverMissing == true {
                        Text("· 封面缺失").foregroundStyle(MediaFetchTheme.warning)
                    }
                    if let source = job.browserCookieSource {
                        Text("· \(source.displayName) 登录态")
                    }
                    Text("· \(job.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    Spacer()

                    if let manifestPath = job.manifestPath {
#if !MEDIAFETCH_STORE_PROFILE
                        Button("处理…") { openTools(mediaFiles(of: job)) }
                            .buttonStyle(.link)
                        ResolveSendButton(target: .package(URL(fileURLWithPath: manifestPath).deletingLastPathComponent()))
#endif
                        Button("显示素材包") { reveal(manifestPath) }
                            .buttonStyle(.link)
                    } else if let first = job.completedFiles.first {
                        Button("显示文件") { reveal(first) }
                            .buttonStyle(.link)
                    }
                }
                .font(.caption)
                .foregroundStyle(MediaFetchTheme.secondaryText)

                if job.status == .failed || job.status == .retrying || job.lastCommand != nil {
                    JobInsightView(
                        job: job,
                        onRetry: { downloader.retryJob(job.id) },
                        openSettings: openSettings
                    )
                } else if let error = job.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(MediaFetchTheme.danger)
                        .lineLimit(3)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }


    private var pageTitle: String {
#if MEDIAFETCH_STORE_PROFILE
        return String(localized: "素材记录")
#else
        return String(localized: "下载任务")
#endif
    }

    private var pageSubtitle: String {
#if MEDIAFETCH_STORE_PROFILE
        return String(localized: "本地素材包与清单历史")
#else
        return String(localized: "队列、进度与本机历史")
#endif
    }

    private var emptyTitle: String {
#if MEDIAFETCH_STORE_PROFILE
        return String(localized: "还没有素材记录")
#else
        return String(localized: "还没有下载任务")
#endif
    }

    private var emptyMessage: String {
#if MEDIAFETCH_STORE_PROFILE
        return String(localized: "在“音乐”页面完成本地音频匹配并保存后，素材包记录会显示在这里。记录只保存在本机。")
#else
        return String(localized: "从首页进入“视频”，粘贴媒体链接后即可加入队列。任务历史只保存在本机。")
#endif
    }


    /// Media files of a finished package (not sidecars), for the toolbox.
    private func mediaFiles(of job: DownloadJob) -> [URL] {
        job.completedFiles.map(URL.init(fileURLWithPath:)).filter(MediaSignature.expectsMedia)
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
