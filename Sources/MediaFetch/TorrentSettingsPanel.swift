#if !MEDIAFETCH_STORE_PROFILE
import AppKit
import SwiftUI
import MediaFetchTorrent

enum TorrentPreferences {
    static let peerPortKey = "MediaFetch.torrent.peerPort"
    static let downLimitKey = "MediaFetch.torrent.downLimitKBps"
    static let upLimitKey = "MediaFetch.torrent.upLimitKBps"

    static var sessionSettings: TorrentService.SessionSettings {
        let defaults = UserDefaults.standard
        func value(_ key: String) -> Int? { let v = defaults.integer(forKey: key); return v > 0 ? v : nil }
        return .init(peerPort: value(peerPortKey), downloadLimitKBps: value(downLimitKey), uploadLimitKBps: value(upLimitKey))
    }
}

/// Settings card for the BitTorrent engine: folder, peer port, limits, background seeding.
struct TorrentSettingsPanel: View {
    @EnvironmentObject private var service: TorrentService
    @AppStorage(TorrentPreferences.peerPortKey) private var peerPort = 0
    @AppStorage(TorrentPreferences.downLimitKey) private var downLimit = 0
    @AppStorage(TorrentPreferences.upLimitKey) private var upLimit = 0
    @AppStorage(TorrentService.keepSeedingKey) private var keepSeeding = false
    @State private var directory = TorrentDefaults.downloadDirectory
    @State private var applied = false

    var body: some View {
        MediaFetchPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(MediaFetchTheme.torrentAccent, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Torrent").font(.title3.bold()).foregroundStyle(MediaFetchTheme.primaryText)
                        Text(service.engineInstalled ? String(localized: "Transmission 引擎 · 只监听本机，凭据保存在钥匙串") : String(localized: "未安装：brew install transmission-cli"))
                            .font(.caption).foregroundStyle(MediaFetchTheme.secondaryText)
                    }
                }
                HStack {
                    Text("默认保存位置")
                    Text(directory.path).lineLimit(1).truncationMode(.middle).foregroundStyle(MediaFetchTheme.secondaryText)
                    Spacer()
                    Button("更改…", action: chooseDirectory).buttonStyle(.bordered)
                }
                HStack(spacing: 18) {
                    field(String(localized: "监听端口"), value: $peerPort, placeholder: String(localized: "自动"))
                    field(String(localized: "下载限速 KB/s"), value: $downLimit, placeholder: String(localized: "不限"))
                    field(String(localized: "上传限速 KB/s"), value: $upLimit, placeholder: String(localized: "不限"))
                    Button(applied ? String(localized: "已应用") : String(localized: "应用")) { apply() }.buttonStyle(.borderedProminent)
                        .tint(MediaFetchTheme.torrentAccent)
                }
                Toggle("退出应用后继续做种（下次启动时自动接管）", isOn: $keepSeeding)
                Text("关闭时，退出应用会停止 Transmission；打开后，下次启动引擎时生效，重新打开应用会接回同一个后台引擎。")
                    .font(.caption).foregroundStyle(MediaFetchTheme.secondaryText)
            }
            .font(.subheadline)
            .foregroundStyle(MediaFetchTheme.primaryText)
        }
    }

    private func field(_ title: String, value: Binding<Int>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(MediaFetchTheme.secondaryText)
            TextField(placeholder, value: Binding(
                get: { value.wrappedValue > 0 ? value.wrappedValue : nil },
                set: { value.wrappedValue = max(0, $0 ?? 0); applied = false }
            ), format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .frame(width: 110)
        }
    }

    private func apply() {
        service.sessionSettings = TorrentPreferences.sessionSettings
        Task { await service.applySessionSettings(); applied = true }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = directory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        directory = url
        UserDefaults.standard.set(url.path, forKey: "MediaFetch.torrent.directory")
        service.defaultDownloadDirectory = url
        apply()
    }
}
#endif
