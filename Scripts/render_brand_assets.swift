import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let svgURL = root.appendingPathComponent("Resources/Brand/SooogoodMediaCatchLogo.svg")
let iconDirectory = root.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let svgData = try Data(contentsOf: svgURL)
guard let image = NSImage(data: svgData) else {
    throw NSError(domain: "SooogoodMediaCatchBrand", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to render logo SVG"])
}

let outputs: [(String, Int)] = [
    ("icon_16.png", 16), ("icon_32.png", 32), ("icon_32_1x.png", 32),
    ("icon_64.png", 64), ("icon_128.png", 128), ("icon_256.png", 256),
    ("icon_256_1x.png", 256), ("icon_512.png", 512), ("icon_512_1x.png", 512),
    ("icon_1024.png", 1024)
]
for (fileName, size) in outputs {
    let target = NSSize(width: size, height: size)
    let canvas = NSImage(size: target)
    canvas.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .sourceOver, fraction: 1)
    canvas.unlockFocus()
    guard let tiff = canvas.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "SooogoodMediaCatchBrand", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to encode icon \(size)"])
    }
    try png.write(to: iconDirectory.appendingPathComponent(fileName), options: .atomic)
}
