#if !MEDIAFETCH_STORE_PROFILE
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MediaFetchCore
import MediaFetchTools

/// Creator toolbox: proxies, transcodes, audio, transcripts, GIF previews.
struct ToolsView: View {
    @ObservedObject var service: ToolService
    let onBack: () -> Void
    var intake: IntakeCoordinator? = nil

    @State private var inputs: [URL] = []
    @State private var presets: Set<ToolPreset> = [.proresProxy]
    @State private var language = "auto"
    @State private var host: WhisperModel.Host = .huggingFace
    @State private var isTargeted = false
    @State private var pendingDownload: WhisperModel?

    var body: some View {
        ZStack {
            CinematicBackground(accent: MediaFetchTheme.toolsAccent)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    inputPanel
                    presetPanel
                    if presets.contains(.transcribe) { modelPanel }
                    startBar
                    jobList
                }
                .frame(maxWidth: 1180)
                .padding(.horizontal, 36)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear(perform: consumePendingInputs)
        .onChange(of: intake?.pendingToolInputs.count) { _, _ in consumePendingInputs() }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: handleDrop)
        .confirmationDialog("下载 whisper 模型", isPresented: Binding(
            get: { pendingDownload != nil }, set: { if !$0 { pendingDownload = nil } }
        ), presenting: pendingDownload) { model in
            Button("下载 \(model.fileName)") { Task { await service.downloadModel(model, host: host) } }
            Button("取消", role: .cancel) {}
        } message: { model in
            Text("来源：\(model.downloadURL(host: host).absoluteString)\n大小：约 \(ByteCountFormatter.string(fromByteCount: model.approximateBytes, countStyle: .file))\n保存到：\(WhisperModelStore.directory.path)")
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 16) {
            PageBackButton(action: onBack)
            VStack(alignment: .leading, spacing: 3) {
                Text("工具箱")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(MediaFetchTheme.primaryText)
                Text("剪辑代理 · 转码 · 音轨 · 本机转录，结果写入 derivatives.json")
                    .font(.caption)
                    .foregroundStyle(MediaFetchTheme.secondaryText)
            }
            Spacer()
            if service.toolchain.ffmpeg == nil {
                StatusPill(text: "缺少 FFmpeg", systemImage: "exclamationmark.triangle.fill", color: MediaFetchTheme.warning)
            }
        }
    }

    private var inputPanel: some View {
        MediaFetchPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("素材").font(.headline).foregroundStyle(MediaFetchTheme.primaryText)
                    Spacer()
                    Button("选择文件…", action: chooseFiles).buttonStyle(.bordered)
                    if !inputs.isEmpty { Button("清空") { inputs = [] }.buttonStyle(.link) }
                }
                if inputs.isEmpty {
                    Text("把视频或音频文件拖到这里，或在「下载任务」里对已完成的素材包选择「处理…」")
                        .font(.caption)
                        .foregroundStyle(MediaFetchTheme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ForEach(inputs, id: \.self) { url in
                        HStack {
                            Image(systemName: "film").foregroundStyle(MediaFetchTheme.toolsAccent)
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { inputs.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                        }
                        .font(.caption)
                        .foregroundStyle(MediaFetchTheme.primaryText)
                    }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(MediaFetchTheme.toolsAccent, lineWidth: isTargeted ? 2 : 0))
    }

    private var presetPanel: some View {
        MediaFetchPanel {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(ToolPreset.Group.allCases, id: \.self) { group in
                    Text(group.rawValue).font(.headline).foregroundStyle(MediaFetchTheme.primaryText)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 10)], spacing: 10) {
                        ForEach(ToolPreset.allCases.filter { $0.group == group }) { preset in
                            presetTile(preset)
                        }
                    }
                }
            }
        }
    }

    private func presetTile(_ preset: ToolPreset) -> some View {
        let selected = presets.contains(preset)
        return Button {
            if selected { presets.remove(preset) } else { presets.insert(preset) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected ? MediaFetchTheme.toolsAccent : MediaFetchTheme.secondaryText)
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.displayName).font(.subheadline.bold()).foregroundStyle(MediaFetchTheme.primaryText)
                    Text(preset.detail).font(.caption).foregroundStyle(MediaFetchTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? MediaFetchTheme.toolsAccent.opacity(0.10) : MediaFetchTheme.surfaceSecondary,
                        in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var modelPanel: some View {
        MediaFetchPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("转录模型").font(.headline).foregroundStyle(MediaFetchTheme.primaryText)
                    Spacer()
                    Picker("语言", selection: $language) {
                        Text("自动识别").tag("auto")
                        Text("中文").tag("zh")
                        Text("English").tag("en")
                        Text("日本語").tag("ja")
                    }
                    .frame(width: 180)
                }
                if service.installedModels.isEmpty {
                    Text("还没有模型。选择一个下载，或使用电脑上已有的 ggml 模型文件。")
                        .font(.caption).foregroundStyle(MediaFetchTheme.warning)
                } else {
                    Picker("使用模型", selection: $service.selectedModel) {
                        ForEach(service.installedModels, id: \.self) { url in
                            Text(url.lastPathComponent).tag(Optional(url))
                        }
                    }
                    .frame(maxWidth: 420)
                }
                if let progress = service.modelDownloadProgress {
                    ProgressView(value: progress) { Text("正在下载模型… \(Int(progress * 100))%").font(.caption) }
                } else {
                    HStack(spacing: 8) {
                        Menu("下载模型") {
                            ForEach(WhisperModel.catalog) { model in
                                Button("\(model.displayName) · 约 \(ByteCountFormatter.string(fromByteCount: model.approximateBytes, countStyle: .file))") {
                                    pendingDownload = model
                                }
                            }
                        }
                        .frame(width: 140)
                        Picker("下载源", selection: $host) {
                            Text("Hugging Face").tag(WhisperModel.Host.huggingFace)
                            Text("hf-mirror（国内）").tag(WhisperModel.Host.mirror)
                        }
                        .frame(width: 260)
                        Button("使用已有模型文件…", action: chooseExistingModel).buttonStyle(.link)
                    }
                }
                if let error = service.errorMessage {
                    Text(error).font(.caption).foregroundStyle(MediaFetchTheme.danger)
                }
            }
            .font(.caption)
        }
    }

    private var startBar: some View {
        HStack {
            Button {
                service.enqueue(inputs: inputs, presets: ToolPreset.allCases.filter(presets.contains), language: language)
            } label: {
                Label("开始处理 \(inputs.count * presets.count) 项", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(MediaFetchTheme.toolsAccent)
            .controlSize(.large)
            .disabled(inputs.isEmpty || presets.isEmpty || service.toolchain.ffmpeg == nil
                      || (presets.contains(.transcribe) && service.selectedModel == nil))
            Spacer()
            if service.jobs.contains(where: { [.completed, .failed, .cancelled].contains($0.status) }) {
                Button("清除已结束记录") { service.clearFinished() }.buttonStyle(.bordered)
            }
        }
    }

    private var jobList: some View {
        LazyVStack(spacing: 10) {
            ForEach(service.jobs.reversed()) { job in
                ToolJobRow(job: job, onCancel: { service.cancel(job.id) })
            }
        }
    }

    // MARK: Actions

    private func consumePendingInputs() {
        guard let intake, !intake.pendingToolInputs.isEmpty else { return }
        for url in intake.pendingToolInputs where !inputs.contains(url) { inputs.append(url) }
        intake.pendingToolInputs = []
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .audio, .audiovisualContent]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !inputs.contains(url) { inputs.append(url) }
    }

    private func chooseExistingModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        panel.message = "选择 whisper.cpp 的 ggml-*.bin 模型文件（会以链接方式使用，不复制）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        service.useExistingModel(at: url)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in if !inputs.contains(url) { inputs.append(url) } }
            }
        }
        return handled
    }
}

struct ToolJobRow: View {
    let job: ToolJob
    let onCancel: () -> Void

    var body: some View {
        MediaFetchPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: symbol).foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.inputName).font(.subheadline.bold()).foregroundStyle(MediaFetchTheme.primaryText).lineLimit(1)
                        Text(job.preset.displayName + speedText).font(.caption).foregroundStyle(MediaFetchTheme.secondaryText)
                    }
                    Spacer()
                    StatusPill(text: job.status.displayName, systemImage: symbol, color: tint)
                    if job.status == .running || job.status == .queued {
                        Button("取消", action: onCancel).buttonStyle(.bordered)
                    }
                }
                if job.status == .running { ProgressView(value: job.progress).tint(MediaFetchTheme.toolsAccent) }
                if let error = job.errorMessage, job.status == .failed {
                    Text(error).font(.caption).foregroundStyle(MediaFetchTheme.danger).lineLimit(3).textSelection(.enabled)
                }
                if job.status == .completed {
                    HStack(spacing: 12) {
                        ForEach(job.outputPaths, id: \.self) { path in
                            Button((path as NSString).lastPathComponent) {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                            .buttonStyle(.link)
                            .lineLimit(1)
                        }
                        Spacer()
                        ResolveSendButton(target: .package(URL(fileURLWithPath: job.inputPath).deletingLastPathComponent()))
                    }
                    .font(.caption)
                }
            }
        }
    }

    private var speedText: String {
        var parts: [String] = []
        if let elapsed = job.elapsedSeconds { parts.append(String(format: "耗时 %.1f 秒", elapsed)) }
        if let factor = job.speedFactor { parts.append(String(format: "%.1f× 实时", factor)) }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
    }

    private var symbol: String {
        switch job.status {
        case .queued: return "clock.fill"
        case .running: return "gearshape.2.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }

    private var tint: Color {
        switch job.status {
        case .queued, .cancelled: return MediaFetchTheme.secondaryText
        case .running: return MediaFetchTheme.toolsAccent
        case .completed: return MediaFetchTheme.success
        case .failed: return MediaFetchTheme.danger
        }
    }
}

/// Processing section of the task page.
struct ToolTaskList: View {
    @EnvironmentObject private var service: ToolService
    let openTools: () -> Void

    var body: some View {
        LazyVStack(spacing: 10) {
            if service.jobs.isEmpty {
                VStack(spacing: 10) {
                    Text("还没有处理任务").foregroundStyle(MediaFetchTheme.secondaryText)
                    Button("打开工具箱", action: openTools).buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            }
            ForEach(service.jobs.reversed()) { job in
                ToolJobRow(job: job, onCancel: { service.cancel(job.id) })
            }
        }
    }
}
#endif
