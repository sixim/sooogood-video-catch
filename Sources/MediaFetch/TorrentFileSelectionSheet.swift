#if !MEDIAFETCH_STORE_PROFILE
import SwiftUI
import MediaFetchTorrent

/// Pick which files of a torrent to download, and which to fetch first.
struct TorrentFileSelectionSheet: View {
    let snapshot: TorrentSnapshot
    let onConfirm: (_ wanted: Set<Int>, _ highPriority: Set<Int>) -> Void
    let onCancel: () -> Void

    @State private var wanted: Set<Int>
    @State private var highPriority: Set<Int> = []

    init(snapshot: TorrentSnapshot,
         onConfirm: @escaping (Set<Int>, Set<Int>) -> Void,
         onCancel: @escaping () -> Void) {
        self.snapshot = snapshot
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _wanted = State(initialValue: Set(snapshot.files.filter(\.wanted).map(\.index)))
    }

    private var selectedBytes: Int64 {
        snapshot.files.filter { wanted.contains($0.index) }.reduce(0) { $0 + $1.length }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(snapshot.name).font(.title3.bold()).lineLimit(2)
            Text("已选 \(wanted.count)/\(snapshot.files.count) 个文件 · \(ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file))")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("全选") { wanted = Set(snapshot.files.map(\.index)) }
                Button("全不选") { wanted = [] }
                Button("只选视频") {
                    let video = ["mp4", "mkv", "mov", "webm", "m4v", "avi", "ts"]
                    wanted = Set(snapshot.files.filter { video.contains(($0.name as NSString).pathExtension.lowercased()) }.map(\.index))
                }
            }
            .buttonStyle(.link)
            List(snapshot.files) { file in
                HStack {
                    Toggle(isOn: Binding(
                        get: { wanted.contains(file.index) },
                        set: { if $0 { wanted.insert(file.index) } else { wanted.remove(file.index); highPriority.remove(file.index) } }
                    )) {
                        Text(file.name).lineLimit(1).truncationMode(.middle)
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: file.length, countStyle: .file))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        if highPriority.contains(file.index) { highPriority.remove(file.index) } else { highPriority.insert(file.index); wanted.insert(file.index) }
                    } label: {
                        Image(systemName: highPriority.contains(file.index) ? "flag.fill" : "flag")
                    }
                    .buttonStyle(.borderless)
                    .help("优先下载")
                }
            }
            .frame(minHeight: 260)
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("开始下载") { onConfirm(wanted, highPriority) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(wanted.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 640, height: 520)
    }
}
#endif
