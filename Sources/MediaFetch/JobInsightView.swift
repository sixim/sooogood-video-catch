import AppKit
import SwiftUI
import MediaFetchCore

/// Failure cause with one action, retry progress, and the audited engine command.
struct JobInsightView: View {
    let job: DownloadJob
    let onRetry: () -> Void
    let openSettings: () -> Void
    @State private var showsCommand = false
    @State private var copiedHint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if job.status == .retrying, let note = job.retryNote {
                Label(note, systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(MediaFetchTheme.warning)
            }
            if job.status == .failed {
                failureCard
            }
            if let command = job.lastCommand {
                DisclosureGroup(isExpanded: $showsCommand) {
                    HStack(alignment: .top) {
                        Text(command)
                            .font(.caption2.monospaced())
                            .foregroundStyle(MediaFetchTheme.secondaryText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("复制") { copy(command, hint: String(localized: "已复制命令")) }
                            .buttonStyle(.link)
                    }
                    .padding(.top, 4)
                } label: {
                    Text(String(localized: "实际执行的命令") + ((job.attempts ?? 1) > 1 ? String(localized: "（第 \(job.attempts ?? 1) 次尝试）") : ""))
                        .font(.caption)
                        .foregroundStyle(MediaFetchTheme.secondaryText)
                }
            }
            if let copiedHint {
                Text(copiedHint).font(.caption2).foregroundStyle(MediaFetchTheme.success)
            }
        }
    }

    private var failureCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let diagnosis = job.diagnosis {
                Label(diagnosis.title, systemImage: "stethoscope")
                    .font(.caption.bold())
                    .foregroundStyle(MediaFetchTheme.danger)
            }
            if let error = job.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(MediaFetchTheme.danger)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            HStack(spacing: 10) {
                if let diagnosis = job.diagnosis, let title = diagnosis.actionTitle {
                    Button(title) { perform(diagnosis.remedy) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                if job.diagnosis?.remedy != .waitAndRetry {
                    Button("重新尝试", action: onRetry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MediaFetchTheme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func perform(_ remedy: EngineRemedy) {
        switch remedy {
        case .signIn: openSettings()
        case .updateEngine: copy("brew upgrade yt-dlp", hint: String(localized: "已复制：brew upgrade yt-dlp，请在终端运行后重试"))
        case .installJSRuntime: copy("brew install deno", hint: String(localized: "已复制：brew install deno，请在终端运行后重试"))
        case .waitAndRetry: onRetry()
        case .freeDiskSpace:
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") {
                NSWorkspace.shared.open(url)
            }
        case .none: break
        }
    }

    private func copy(_ text: String, hint: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedHint = hint
    }
}
