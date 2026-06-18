import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate_app_icon.swift <output-iconset-directory>\n", stderr)
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let background = NSColor(srgbRed: 0.075, green: 0.082, blue: 0.095, alpha: 1)
let border = NSColor(srgbRed: 0.19, green: 0.21, blue: 0.24, alpha: 1)
let accent = NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)

func renderIcon(size: Int, filename: String) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "GameChatTranslatorIcon", code: 1)
    }

    bitmap.size = NSSize(width: size, height: size)
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "GameChatTranslatorIcon", code: 2)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let inset = CGFloat(size) * 0.065
    let tileRect = NSRect(
        x: inset,
        y: inset,
        width: CGFloat(size) - inset * 2,
        height: CGFloat(size) - inset * 2
    )
    let tilePath = NSBezierPath(
        roundedRect: tileRect,
        xRadius: CGFloat(size) * 0.21,
        yRadius: CGFloat(size) * 0.21
    )
    background.setFill()
    tilePath.fill()

    border.setStroke()
    tilePath.lineWidth = max(1, CGFloat(size) * 0.012)
    tilePath.stroke()

    let baseConfiguration = NSImage.SymbolConfiguration(
        pointSize: CGFloat(size) * 0.58,
        weight: .semibold
    )
    let colorConfiguration = NSImage.SymbolConfiguration(paletteColors: [accent])
    let configuration = baseConfiguration.applying(colorConfiguration)
    guard let symbol = NSImage(
        systemSymbolName: "waveform.and.mic",
        accessibilityDescription: "Game Chat Translator"
    )?.withSymbolConfiguration(configuration) else {
        throw NSError(domain: "GameChatTranslatorIcon", code: 3)
    }

    let maximumWidth = CGFloat(size) * 0.74
    let maximumHeight = CGFloat(size) * 0.64
    let scale = min(maximumWidth / symbol.size.width, maximumHeight / symbol.size.height)
    let symbolSize = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
    let symbolRect = NSRect(
        x: (CGFloat(size) - symbolSize.width) / 2,
        y: (CGFloat(size) - symbolSize.height) / 2,
        width: symbolSize.width,
        height: symbolSize.height
    )
    symbol.draw(in: symbolRect)

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GameChatTranslatorIcon", code: 4)
    }
    try png.write(to: outputDirectory.appendingPathComponent(filename), options: .atomic)
}

let variants: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for (size, filename) in variants {
    try renderIcon(size: size, filename: filename)
}
