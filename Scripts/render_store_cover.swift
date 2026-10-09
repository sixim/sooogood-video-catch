import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let isLocalVariant = CommandLine.arguments.contains("--local")
let outputName = isLocalVariant
    ? "Sooogood-Media-Catch-local-cover-1440x900.png"
    : "Sooogood-Media-Catch-store-cover-1440x900.png"
let outputURL = root.appendingPathComponent("StoreAssets/\(outputName)")
let logoURL = root.appendingPathComponent("Resources/Brand/SooogoodMediaCatchLogo.svg")
let canvasSize = NSSize(width: 1440, height: 900)
// Render directly into an opaque RGB bitmap. Keeping the cover free of an
// alpha channel makes it safe to reuse in storefront/marketing workflows and
// prevents a later export step from accidentally producing a transparent
// canvas. (AppIcon assets intentionally keep their own alpha contract.)
let bytesPerRow = Int(canvasSize.width) * 4
var pixelData = Data(repeating: 0, count: bytesPerRow * Int(canvasSize.height))
var renderedImage: CGImage?
try pixelData.withUnsafeMutableBytes { rawBuffer in
    guard let cgContext = CGContext(
        data: rawBuffer.baseAddress,
        width: Int(canvasSize.width),
        height: Int(canvasSize.height),
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ) else {
        return
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cgContext, flipped: false)

NSColor(calibratedRed: 0.039, green: 0.047, blue: 0.067, alpha: 1).setFill()
NSRect(origin: .zero, size: canvasSize).fill()

func glow(_ center: NSPoint, radius: CGFloat, color: NSColor) {
    let gradient = NSGradient(colors: [color.withAlphaComponent(0.22), color.withAlphaComponent(0)])!
    gradient.draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
}

glow(NSPoint(x: 1190, y: 730), radius: 430, color: NSColor(calibratedRed: 0.50, green: 0.40, blue: 1, alpha: 1))
glow(NSPoint(x: 260, y: 110), radius: 360, color: NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.63, alpha: 1))

let logoImage = NSImage(data: try Data(contentsOf: logoURL))!
logoImage.draw(in: NSRect(x: 96, y: 590, width: 112, height: 112), from: .zero, operation: .sourceOver, fraction: 1)

let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont(name: "SF Pro Display", size: isLocalVariant ? 64 : 52) ?? NSFont.systemFont(ofSize: isLocalVariant ? 64 : 52, weight: .bold),
    .foregroundColor: NSColor(calibratedWhite: 0.96, alpha: 1)
]
let subtitleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont(name: "SF Pro Text", size: 24) ?? NSFont.systemFont(ofSize: 24),
    .foregroundColor: NSColor(calibratedWhite: 0.62, alpha: 1)
]
let bodyAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont(name: "SF Pro Text", size: 20) ?? NSFont.systemFont(ofSize: 20),
    .foregroundColor: NSColor(calibratedWhite: 0.72, alpha: 1)
]
let title = isLocalVariant ? "把可保存的媒体，带回本地。" : "把属于你的音频，整理在本地。"
let subtitle = isLocalVariant ? "Sooogood Media Catch · 视频下载与个人音乐整理" : "Sooogood Media Catch · 音乐桥接与可追溯素材"
let body = isLocalVariant ? "本地优先 · 非 DRM · 可追溯素材包" : "本地优先 · 权限清晰 · 可追溯素材包"
title.draw(at: NSPoint(x: 96, y: 505), withAttributes: titleAttributes)
subtitle.draw(at: NSPoint(x: 100, y: 456), withAttributes: subtitleAttributes)
body.draw(at: NSPoint(x: 100, y: 408), withAttributes: bodyAttributes)

func card(_ rect: NSRect, title: String, accent: NSColor, detail: String) {
    let path = NSBezierPath(roundedRect: rect, xRadius: 24, yRadius: 24)
    NSColor(calibratedWhite: 0.08, alpha: 0.94).setFill()
    path.fill()
    accent.withAlphaComponent(0.72).setStroke()
    path.lineWidth = 2
    path.stroke()
    let stripe = NSBezierPath(roundedRect: NSRect(x: rect.minX + 30, y: rect.minY + 34, width: 8, height: rect.height - 68), xRadius: 4, yRadius: 4)
    accent.setFill()
    stripe.fill()
    [title, detail].enumerated().forEach { index, value in
        let attrs = index == 0 ? titleAttributes : bodyAttributes
        value.draw(at: NSPoint(x: rect.minX + 64, y: rect.maxY - 78 - CGFloat(index) * 44), withAttributes: attrs)
    }
}

if isLocalVariant {
    card(NSRect(x: 850, y: 490, width: 490, height: 190), title: "视频", accent: NSColor(calibratedRed: 0.29, green: 0.55, blue: 1, alpha: 1), detail: "查看实际格式，再决定如何保存。")
    card(NSRect(x: 850, y: 255, width: 490, height: 190), title: "音乐", accent: NSColor(calibratedRed: 0.50, green: 0.40, blue: 1, alpha: 1), detail: "用 Spotify 曲序整理你自己的音频。")
} else {
    card(NSRect(x: 850, y: 490, width: 490, height: 190), title: "音乐", accent: NSColor(calibratedRed: 0.50, green: 0.40, blue: 1, alpha: 1), detail: "用 Spotify 曲序整理你拥有的本地音频。")
    card(NSRect(x: 850, y: 255, width: 490, height: 190), title: "可追溯", accent: NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.63, alpha: 1), detail: "来源、顺序与校验值一起保存。")
}

let footer = "保存来源、格式与 SHA-256，留下一份可以复核的本地记录。"
footer.draw(at: NSPoint(x: 100, y: 92), withAttributes: subtitleAttributes)

    NSGraphicsContext.restoreGraphicsState()
    renderedImage = cgContext.makeImage()
}
guard let renderedImage,
      let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
      ) else {
    throw NSError(domain: "SooogoodMediaCatchStoreCover", code: 1)
}
CGImageDestinationAddImage(destination, renderedImage, nil)
guard CGImageDestinationFinalize(destination) else {
    throw NSError(domain: "SooogoodMediaCatchStoreCover", code: 4)
}
