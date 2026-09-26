import SwiftUI

/// Temporary page until the creator toolbox lands.
struct ToolsPlaceholderView: View {
    let onBack: () -> Void

    var body: some View {
        ZStack {
            CinematicBackground(accent: MediaFetchTheme.toolsAccent)
            VStack(alignment: .leading, spacing: 16) {
                PageBackButton(action: onBack)
                Text("工具箱").font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(MediaFetchTheme.primaryText)
                Text("本地媒体处理（转录、剪辑代理、转码）正在开发中。")
                    .foregroundStyle(MediaFetchTheme.secondaryText)
            }
            .padding(36)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
