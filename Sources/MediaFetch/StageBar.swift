import SwiftUI
import MediaFetchCore

/// 解析 → 下载 → 合并 → 校验 → 清单, with the current step highlighted.
struct StageBar: View {
    let job: DownloadJob

    private var currentIndex: Int? {
        if job.status == .completed { return DownloadStage.allCases.count }
        return job.stage?.rawValue
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(DownloadStage.allCases, id: \.self) { stage in
                let state = stateFor(stage)
                HStack(spacing: 4) {
                    Image(systemName: state.symbol)
                        .font(.system(size: 10, weight: .bold))
                    Text(stage.displayName)
                }
                .font(.caption2.weight(state == .current ? .bold : .regular))
                .foregroundStyle(state.color)
                if stage != DownloadStage.allCases.last {
                    Rectangle().fill(state == .done ? MediaFetchTheme.success : MediaFetchTheme.border)
                        .frame(width: 14, height: 1)
                }
            }
            if let speed = job.speedText, job.stage == .downloading {
                Text("· \(speed)").font(.caption2.monospacedDigit()).foregroundStyle(MediaFetchTheme.secondaryText)
            }
            if let eta = job.etaText, job.stage == .downloading {
                Text("· 剩余 \(eta)").font(.caption2.monospacedDigit()).foregroundStyle(MediaFetchTheme.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("阶段：\(job.stage?.displayName ?? job.status.displayName)")
    }

    private enum StepState { case done, current, pending
        var symbol: String {
            switch self { case .done: return "checkmark.circle.fill"; case .current: return "circle.inset.filled"; case .pending: return "circle" }
        }
        var color: Color {
            switch self {
            case .done: return MediaFetchTheme.success
            case .current: return MediaFetchTheme.videoAccent
            case .pending: return MediaFetchTheme.secondaryText.opacity(0.6)
            }
        }
    }

    private func stateFor(_ stage: DownloadStage) -> StepState {
        guard let current = currentIndex else { return .pending }
        if stage.rawValue < current { return .done }
        return stage.rawValue == current ? .current : .pending
    }
}
