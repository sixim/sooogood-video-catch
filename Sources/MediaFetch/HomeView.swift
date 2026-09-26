import SwiftUI
import MediaFetchCore
import MediaFetchVideo

struct HomeView: View {
    @ObservedObject var downloader: DownloaderService
    @ObservedObject var spotify: SpotifyBridgeViewModel
    let navigate: (AppRoute) -> Void

    private var activeJobs: Int {
        downloader.jobs.filter { [.queued, .downloading, .packaging, .paused].contains($0.status) }.count
    }

    var body: some View {
        ZStack {
            CinematicBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    header
                    primaryActions
                    secondaryActions
                    provenanceNote
                }
                .frame(maxWidth: 1180)
                .padding(.horizontal, 48)
                .padding(.top, 42)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationBarBackButtonHidden()
    }

    private var header: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 17)
                    .fill(
                        LinearGradient(
                            colors: [MediaFetchTheme.videoAccent, MediaFetchTheme.musicPurple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "arrow.down.to.line.compact")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 58, height: 58)
            .shadow(color: MediaFetchTheme.videoAccent.opacity(0.32), radius: 22, y: 8)

            VStack(alignment: .leading, spacing: 5) {
                Text(MediaFetchRelease.displayName)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(MediaFetchTheme.primaryText)
                Text(homeDescription)
                    .font(.subheadline)
                    .foregroundStyle(MediaFetchTheme.secondaryText)
            }

            Spacer()

            StatusPill(
                text: engineStatusText,
                systemImage: engineStatusImage,
                color: engineStatusColor
            )
        }
        .accessibilityElement(children: .contain)
    }

    private var primaryActions: some View {
        HStack(spacing: 22) {
            FeatureCard(
                title: "视频",
                subtitle: videoCardSubtitle,
                detail: videoCardDetail,
                systemImage: "play.rectangle.fill",
                accentColors: [MediaFetchTheme.videoAccent, Color(hex: 0x79A7FF)],
                action: { navigate(.video) }
            )

            FeatureCard(
                title: "音乐",
                subtitle: "用 Spotify 曲序整理你拥有的本地音频",
                detail: spotify.homeSummary,
                systemImage: "music.note.list",
                accentColors: [MediaFetchTheme.musicPurple, MediaFetchTheme.musicGreen],
                action: { navigate(.music) }
            )
        }
    }

    private var secondaryActions: some View {
        HStack(spacing: 16) {
            CompactNavigationCard(
                title: tasksCardTitle,
                subtitle: downloader.jobs.isEmpty ? tasksCardEmptySubtitle : "\(downloader.jobs.count) 个本机记录",
                systemImage: "list.bullet.rectangle.portrait",
                badge: activeJobs == 0 ? nil : "\(activeJobs)",
                action: { navigate(.tasks) }
            )

#if !MEDIAFETCH_STORE_PROFILE
            CompactNavigationCard(
                title: "Torrent",
                subtitle: "磁力链接与 .torrent 文件",
                systemImage: "point.3.connected.trianglepath.dotted",
                badge: nil,
                action: { navigate(.torrent) }
            )
#endif

            CompactNavigationCard(
                title: "设置",
                subtitle: settingsCardSubtitle,
                systemImage: "gearshape.fill",
                badge: nil,
                action: { navigate(.settings) }
            )
        }
    }

    private var provenanceNote: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(MediaFetchTheme.success)
            Text(provenanceText)
                .font(.caption)
                .foregroundStyle(MediaFetchTheme.secondaryText)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var videoCardSubtitle: String {
#if MEDIAFETCH_STORE_PROFILE
        return "商店版暂不提供第三方站点音视频下载"
#else
        return "下载 YouTube、Vimeo、哔哩哔哩、优酷与开放媒体流"
#endif
    }

    private var engineStatusText: String {
#if MEDIAFETCH_STORE_PROFILE
        return spotify.audioToolReady ? "本地音频工具就绪" : "等待商店音频工具"
#else
        return downloader.dependenciesReady ? "下载引擎就绪" : "需要安装下载引擎"
#endif
    }

    private var engineStatusImage: String {
#if MEDIAFETCH_STORE_PROFILE
        return spotify.audioToolReady ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
#else
        return downloader.dependenciesReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
#endif
    }

    private var engineStatusColor: Color {
#if MEDIAFETCH_STORE_PROFILE
        return spotify.audioToolReady ? MediaFetchTheme.success : MediaFetchTheme.warning
#else
        return downloader.dependenciesReady ? MediaFetchTheme.success : MediaFetchTheme.warning
#endif
    }

    private var settingsCardSubtitle: String {
#if MEDIAFETCH_STORE_PROFILE
        return "Spotify 连接与本地音频整理"
#else
        return "下载引擎与 Spotify 连接"
#endif
    }

    private var tasksCardTitle: String {
#if MEDIAFETCH_STORE_PROFILE
        return "素材记录"
#else
        return "下载任务"
#endif
    }

    private var tasksCardEmptySubtitle: String {
#if MEDIAFETCH_STORE_PROFILE
        return "还没有本地素材包记录"
#else
        return "还没有历史任务"
#endif
    }

    private var homeDescription: String {
#if MEDIAFETCH_STORE_PROFILE
        return "整理属于你的音乐资料库，并生成可复核的本地素材包"
#else
        return "保存平台提供的媒体流，也整理属于你的音乐资料库"
#endif
    }

    private var videoCardDetail: String {
#if MEDIAFETCH_STORE_PROFILE
        return "本地完整版保留完整下载工作流"
#else
        return activeJobs == 0 ? "最高画质 · 原始流 · 可验证素材包" : "\(activeJobs) 个任务等待处理"
#endif
    }

    private var provenanceText: String {
#if MEDIAFETCH_STORE_PROFILE
        return "商店版聚焦 Spotify 元数据与本地音频整理；本地完整版可另行处理你有权保存的站点媒体。"
#else
        return "视频页保存平台当前提供的媒体流；音乐页只复制你明确选择的本地或 DRM-free 音频，并记录来源与校验值。"
#endif
    }
}

private struct FeatureCard: View {
    let title: String
    let subtitle: String
    let detail: String
    let systemImage: String
    let accentColors: [Color]
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(MediaFetchTheme.surface)

                RadialGradient(
                    colors: [accentColors.first?.opacity(0.24) ?? .clear, .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: 340
                )
                .clipShape(RoundedRectangle(cornerRadius: 18))

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 15)
                                .fill(
                                    LinearGradient(
                                        colors: accentColors,
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            Image(systemName: systemImage)
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 54, height: 54)
                        .shadow(color: (accentColors.first ?? .clear).opacity(0.36), radius: 18, y: 8)

                        Spacer()

                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(isHovering ? MediaFetchTheme.primaryText : MediaFetchTheme.secondaryText)
                            .padding(11)
                            .background(Color.white.opacity(0.05), in: Circle())
                    }

                    Spacer(minLength: 32)

                    Text(title)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(MediaFetchTheme.primaryText)
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(MediaFetchTheme.secondaryText)
                        .lineLimit(2)
                        .padding(.top, 8)
                    Text(detail)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accentColors.last ?? MediaFetchTheme.primaryText)
                        .padding(.top, 18)
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, minHeight: 264)
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(
                        isHovering ? (accentColors.first ?? .white).opacity(0.52) : MediaFetchTheme.border,
                        lineWidth: isHovering ? 1.4 : 1
                    )
            }
            .shadow(color: .black.opacity(isHovering ? 0.38 : 0.24), radius: isHovering ? 26 : 16, y: 12)
            .offset(y: isHovering ? -4 : 0)
            .scaleEffect(isHovering ? 1.006 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("打开\(title)页面")
    }
}

private struct CompactNavigationCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let badge: String?
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 15) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(MediaFetchTheme.primaryText)
                    .frame(width: 42, height: 42)
                    .background(MediaFetchTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(MediaFetchTheme.primaryText)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(MediaFetchTheme.secondaryText)
                }

                Spacer()

                if let badge {
                    Text(badge)
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(MediaFetchTheme.primaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(MediaFetchTheme.videoAccent, in: Capsule())
                }

                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(MediaFetchTheme.secondaryText)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(MediaFetchTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isHovering ? Color.white.opacity(0.18) : MediaFetchTheme.border, lineWidth: 1)
            }
            .offset(y: isHovering ? -2 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

#if DEBUG
#Preview("首页 · 固定状态") {
    HomeView(
        downloader: DownloaderService(previewJobs: [], dependenciesReady: true),
        spotify: SpotifyBridgeViewModel.preview(.review),
        navigate: { _ in }
    )
    .frame(width: 1_120, height: 780)
    .environment(\.colorScheme, .dark)
    .allowsHitTesting(false)
}
#endif
