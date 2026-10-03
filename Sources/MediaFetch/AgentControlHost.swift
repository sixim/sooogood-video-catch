#if !MEDIAFETCH_STORE_PROFILE
import AppKit
import SwiftUI
import MediaFetchControl
import MediaFetchCore

/// Owns the local control socket that the `sooogood-mcp` helper talks to.
@MainActor
final class AgentControlHost: ObservableObject {
    static let preferenceKey = "MediaFetch.agent.enabled"

    @Published private(set) var isListening = false
    @Published private(set) var errorMessage: String?
    private var server: ControlServer?
    private var bridge: AgentControlBridge?

    func configure(bridge: AgentControlBridge) {
        self.bridge = bridge
        let enabled = UserDefaults.standard.object(forKey: Self.preferenceKey) as? Bool ?? true
        setEnabled(enabled)
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
        server?.stop()
        server = nil
        isListening = false
        guard enabled, let bridge else { return }
        let server = ControlServer(handler: bridge)
        do {
            try server.start()
            self.server = server
            isListening = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        server?.stop()
        server = nil
        isListening = false
    }

    /// The helper ships next to the app binary.
    static var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/sooogood-mcp").path
    }

    static var helperInstalled: Bool { FileManager.default.isExecutableFile(atPath: helperPath) }
}

struct AgentSettingsPanel: View {
    @ObservedObject var host: AgentControlHost
    @AppStorage(AgentControlHost.preferenceKey) private var enabled = true
    @State private var copied: String?

    private var claudeCommand: String { "claude mcp add sooogood -- \"\(AgentControlHost.helperPath)\"" }
    private var jsonConfig: String {
        "{\n  \"mcpServers\": {\n    \"sooogood\": { \"command\": \"\(AgentControlHost.helperPath)\" }\n  }\n}"
    }

    var body: some View {
        MediaFetchPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "cpu")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(MediaFetchTheme.musicPurple, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("AI Agent（MCP）").font(.title3.bold()).foregroundStyle(MediaFetchTheme.primaryText)
                        Text("让 Claude Code、Hermes 等 agent 查询、加入、暂停任务，运行工具箱，发送到达芬奇；不提供任何删除操作")
                            .font(.caption).foregroundStyle(MediaFetchTheme.secondaryText)
                    }
                    Spacer()
                    StatusPill(text: host.isListening ? String(localized: "已开启") : String(localized: "未开启"),
                               systemImage: host.isListening ? "dot.radiowaves.left.and.right" : "pause.circle",
                               color: host.isListening ? MediaFetchTheme.success : MediaFetchTheme.secondaryText)
                }
                Toggle("允许本机 agent 通过 MCP 控制（仅限当前用户的本机进程）", isOn: $enabled)
                    .onChange(of: enabled) { _, value in host.setEnabled(value) }
                if let error = host.errorMessage {
                    Text(error).font(.caption).foregroundStyle(MediaFetchTheme.danger)
                }
                if AgentControlHost.helperInstalled {
                    Text("Claude Code：").font(.caption.bold())
                    CopyableCommand(command: claudeCommand)
                    Text("其他 MCP 客户端（Hermes、Cursor 等）的配置：").font(.caption.bold())
                    CopyableCommand(command: jsonConfig)
                } else {
                    Text("开发运行时没有打包 sooogood-mcp；用 Scripts/package_app.sh 打包后这里会显示接入命令。")
                        .font(.caption).foregroundStyle(MediaFetchTheme.warning)
                }
                Text("agent 只能读写「下载」「影片」和你在应用中选择的文件夹；需要登录的网站使用你在设置里配置的登录方式；Torrent 仍需你先在应用内确认使用说明。")
                    .font(.caption).foregroundStyle(MediaFetchTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(MediaFetchTheme.primaryText)
        }
    }
}
#endif

#if !MEDIAFETCH_STORE_PROFILE
/// Reads the shared host from the environment so SettingsView stays unaware of it.
struct AgentSettingsPanelContainer: View {
    @EnvironmentObject private var host: AgentControlHost
    var body: some View { AgentSettingsPanel(host: host) }
}
#endif
