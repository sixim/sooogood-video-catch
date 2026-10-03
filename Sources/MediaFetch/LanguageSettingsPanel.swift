import AppKit
import SwiftUI
import MediaFetchCore

/// Interface language: follow macOS, or one of the bundled translations.
/// AppKit reads the language list at launch, so a change needs a restart.
struct LanguageSettingsPanel: View {
    @State private var chosen: String? = L10n.chosenLanguage()
    @State private var launchedWith: String? = L10n.chosenLanguage()

    var body: some View {
        MediaFetchPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "globe").foregroundStyle(MediaFetchTheme.secondaryText)
                    // Always bilingual, so the setting can be found in any language.
                    Text(verbatim: "Language · 语言").font(.headline).foregroundStyle(MediaFetchTheme.primaryText)
                    Spacer()
                }
                Picker("界面语言", selection: Binding(get: { chosen ?? "" }, set: { choose($0.isEmpty ? nil : $0) })) {
                    Text("跟随系统").tag("")
                    ForEach(L10n.supportedLanguages, id: \.code) { language in
                        Text(verbatim: language.name).tag(language.code)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 320, alignment: .leading)
                if chosen != launchedWith {
                    HStack(spacing: 10) {
                        Text("重新打开应用后生效").font(.caption).foregroundStyle(MediaFetchTheme.warning)
                        Button("立即重新打开", action: relaunch).buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func choose(_ code: String?) {
        L10n.choose(code)
        chosen = code
    }

    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
