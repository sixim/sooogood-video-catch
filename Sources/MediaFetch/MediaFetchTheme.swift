import SwiftUI

enum MediaFetchTheme {
    static let background = Color(hex: 0x0A0C11)
    static let surface = Color(hex: 0x141821)
    static let surfaceSecondary = Color(hex: 0x1B202C)
    static let primaryText = Color(hex: 0xF5F7FA)
    static let secondaryText = Color(hex: 0x9BA4B5)
    static let videoAccent = Color(hex: 0x4B8DFF)
    static let musicPurple = Color(hex: 0x8067FF)
    static let musicGreen = Color(hex: 0x32C7A0)
    static let success = Color(hex: 0x57D397)
    static let warning = Color(hex: 0xF4B860)
    static let danger = Color(hex: 0xFF6B79)
    static let border = Color.white.opacity(0.09)

    static let musicGradient = LinearGradient(
        colors: [musicPurple, musicGreen],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: opacity
        )
    }
}

struct CinematicBackground: View {
    let accent: Color

    init(accent: Color = MediaFetchTheme.videoAccent) {
        self.accent = accent
    }

    var body: some View {
        ZStack {
            MediaFetchTheme.background
            RadialGradient(
                colors: [accent.opacity(0.16), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 620
            )
            RadialGradient(
                colors: [MediaFetchTheme.musicPurple.opacity(0.07), .clear],
                center: .bottomLeading,
                startRadius: 0,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}

struct MediaFetchPanel<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(20)
            .background(MediaFetchTheme.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(MediaFetchTheme.border, lineWidth: 1)
            }
    }
}

struct StatusPill: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(color.opacity(0.12), in: Capsule())
            .overlay {
                Capsule().stroke(color.opacity(0.22), lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
    }
}

struct PageBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("返回首页", systemImage: "chevron.left")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MediaFetchTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(MediaFetchTheme.border, lineWidth: 1)
        }
        .accessibilityLabel("返回首页")
    }
}
