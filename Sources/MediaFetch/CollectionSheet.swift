#if !MEDIAFETCH_STORE_PROFILE
import SwiftUI
import MediaFetchCore

/// Pick lectures / playlist items to download. Courses are grouped by chapter.
struct CollectionSheet: View {
    enum Phase { case loading, loaded(CollectionOutline), failed(String) }

    let phase: Phase
    let onEnqueue: (CollectionOutline, [CollectionEntry]) -> Void
    let onCancel: () -> Void
    @State private var selected: Set<String> = []
    @State private var didInitialize = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch phase {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取课程 / 播放列表目录…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 260)
                HStack { Spacer(); Button("取消", action: onCancel) }
            case .failed(let message):
                Label("无法展开", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
                Text(message).font(.callout).textSelection(.enabled)
                Spacer()
                HStack { Spacer(); Button("关闭", action: onCancel).keyboardShortcut(.cancelAction) }
            case .loaded(let outline):
                loaded(outline)
            }
        }
        .padding(22)
        .frame(width: 720, height: 580)
    }

    @ViewBuilder
    private func loaded(_ outline: CollectionOutline) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(outline.title.isEmpty ? outline.id : outline.title).font(.title3.bold()).lineLimit(2)
            let kind = outline.isCourse ? String(localized: "课程") : String(localized: "播放列表")
            Text("\(kind) · \(outline.entries.count) 项 · 已选 \(selected.count) 项 · 保存到「\(outline.rootFolderName)」文件夹")
                .font(.caption).foregroundStyle(.secondary)
            if outline.unavailableCount > 0 {
                Text("另有 \(outline.unavailableCount) 个课时当前账号无法观看（通常需要购买或登录），已隐藏。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if outline.isCourse {
                Text("只会下载你账号有权观看、且没有 DRM 保护的课时；受保护的课时会在课程清单里标记为已跳过。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        HStack {
            Button("全选") { selected = Set(outline.entries.map(\.id)) }
            Button("全不选") { selected = [] }
        }
        .buttonStyle(.link)
        List {
            ForEach(Array(outline.chapters.enumerated()), id: \.offset) { _, chapter in
                Section {
                    ForEach(chapter.entries) { entry in
                        Toggle(isOn: Binding(
                            get: { selected.contains(entry.id) },
                            set: { if $0 { selected.insert(entry.id) } else { selected.remove(entry.id) } }
                        )) {
                            HStack {
                                Text(String(format: "%03d", entry.index)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(entry.title).lineLimit(1)
                                Spacer()
                                if let duration = entry.duration {
                                    Text(Self.format(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                } header: {
                    if let title = chapter.title {
                        HStack {
                            Text(title).font(.subheadline.bold())
                            Spacer()
                            Button("选中本章") { chapter.entries.forEach { selected.insert($0.id) } }.buttonStyle(.link)
                        }
                    }
                }
            }
        }
        .onAppear {
            guard !didInitialize else { return }
            didInitialize = true
            selected = Set(outline.entries.map(\.id))
        }
        HStack {
            Spacer()
            Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
            Button("加入队列（\(selected.count)）") {
                onEnqueue(outline, outline.entries.filter { selected.contains($0.id) })
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selected.isEmpty)
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }
}
#endif
