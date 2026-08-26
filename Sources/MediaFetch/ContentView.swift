import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var downloader = DownloaderService()
    @State private var mediaURL = ""
    @State private var profile: DownloadProfile = .highest
    @State private var destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

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
            HStack(spacing: 12) {
                TextField("粘贴 YouTube 或其他受支持网站的链接", text: $mediaURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .onSubmit { downloader.analyze(mediaURL) }
                Button {
                    downloader.analyze(mediaURL)
                } label: {
                    if downloader.isAnalyzing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("解析", systemImage: "sparkle.magnifyingglass")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(downloader.isAnalyzing || downloader.isDownloading)
            }
            .padding(6)
        } label: {
            Text("媒体链接").font(.headline)
        }
    }

    private func metadataPanel(_ metadata: MediaMetadata) -> some View {
        GroupBox {
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
                            downloader.download(mediaURL, profile: profile, destination: destination)
                        } label: {
                            Label("开始下载", systemImage: "arrow.down.to.line.compact")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(mediaURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
}
