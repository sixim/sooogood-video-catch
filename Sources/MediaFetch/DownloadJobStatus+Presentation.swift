import SwiftUI
import MediaFetchCore

/// Single source for how queue states look, shared by every task list.
extension DownloadJobStatus {
    var symbolName: String {
        switch self {
        case .queued, .paused: return "clock.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .suspended: return "pause.circle.fill"
        case .retrying: return "arrow.clockwise.circle.fill"
        case .packaging: return "checkmark.shield.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .queued, .paused, .suspended: return MediaFetchTheme.secondaryText
        case .downloading, .packaging: return MediaFetchTheme.videoAccent
        case .retrying: return MediaFetchTheme.warning
        case .completed: return MediaFetchTheme.success
        case .failed: return MediaFetchTheme.danger
        case .cancelled: return MediaFetchTheme.warning
        }
    }
}
