#!/usr/bin/env swift

import AppKit
import Foundation

let repoRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func makeImage(width: Int, height: Int, opaque: Bool = false, draw: (NSRect) -> Void) -> NSImage {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fputs("Could not create bitmap \(width)x\(height)\n", stderr)
        exit(1)
    }

    let image = NSImage(size: NSSize(width: width, height: height))
    image.addRepresentation(rep)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSGraphicsContext.current?.shouldAntialias = true

    let rect = NSRect(x: 0, y: 0, width: width, height: height)
    if opaque {
        NSColor(srgbRed: 0.027, green: 0.055, blue: 0.086, alpha: 1).setFill()
        rect.fill()
    } else {
        NSColor.clear.setFill()
        rect.fill()
    }
    draw(rect)

    NSGraphicsContext.restoreGraphicsState()
    return image
}

func savePNG(_ image: NSImage, to url: URL) {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:])
    else {
        fputs("Failed to encode \(url.lastPathComponent)\n", stderr)
        exit(1)
    }
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
}

func drawCaptionIcon(in rect: NSRect, size: CGFloat) {
    let inset = size * 0.08
    let canvas = rect.insetBy(dx: inset, dy: inset)
    let corner = canvas.width * 0.223

    let background = NSBezierPath(roundedRect: canvas, xRadius: corner, yRadius: corner)
    NSColor(srgbRed: 0.027, green: 0.055, blue: 0.086, alpha: 1).setFill()
    background.fill()

    let glow = NSGradient(
        colors: [
            NSColor(srgbRed: 0.18, green: 0.83, blue: 0.75, alpha: 0.34),
            NSColor(srgbRed: 0.10, green: 0.46, blue: 1.0, alpha: 0.08),
            .clear,
        ]
    )
    glow?.draw(in: canvas.insetBy(dx: size * 0.06, dy: size * 0.06), relativeCenterPosition: NSPoint(x: 0, y: 0.12))

    let top = NSRect(
        x: canvas.minX + canvas.width * 0.12,
        y: canvas.minY + canvas.height * 0.52,
        width: canvas.width * 0.58,
        height: canvas.height * 0.24
    )
    let bottom = NSRect(
        x: canvas.minX + canvas.width * 0.30,
        y: canvas.minY + canvas.height * 0.22,
        width: canvas.width * 0.58,
        height: canvas.height * 0.24
    )

    NSColor(srgbRed: 0.176, green: 0.831, blue: 0.749, alpha: 1).setFill()
    NSBezierPath(roundedRect: top, xRadius: top.height * 0.42, yRadius: top.height * 0.42).fill()

    NSColor(srgbRed: 0.93, green: 0.97, blue: 0.98, alpha: 1).setFill()
    NSBezierPath(roundedRect: bottom, xRadius: bottom.height * 0.42, yRadius: bottom.height * 0.42).fill()

    func dashes(in bubble: NSRect, color: NSColor) {
        color.setFill()
        let lineHeight = max(1.2, bubble.height * 0.09)
        let left = bubble.minX + bubble.width * 0.14
        let widths: [CGFloat] = [0.58, 0.42, 0.50]
        for (index, widthFactor) in widths.enumerated() {
            let y = bubble.maxY - bubble.height * (0.30 + CGFloat(index) * 0.22)
            NSBezierPath(
                roundedRect: NSRect(
                    x: left,
                    y: y - lineHeight / 2,
                    width: bubble.width * widthFactor,
                    height: lineHeight
                ),
                xRadius: lineHeight / 2,
                yRadius: lineHeight / 2
            ).fill()
        }
    }

    if size >= 32 {
        dashes(in: top, color: NSColor.white.withAlphaComponent(0.72))
        dashes(in: bottom, color: NSColor(srgbRed: 0.05, green: 0.16, blue: 0.20, alpha: 0.55))
    }
}

func drawMenuBarIcon(in rect: NSRect) {
    NSColor.black.setFill()
    let radius = rect.height * 0.16
    let top = NSRect(
        x: rect.width * 0.06,
        y: rect.height * 0.56,
        width: rect.width * 0.58,
        height: rect.height * 0.28
    )
    let bottom = NSRect(
        x: rect.width * 0.36,
        y: rect.height * 0.16,
        width: rect.width * 0.58,
        height: rect.height * 0.28
    )
    NSBezierPath(roundedRect: top, xRadius: radius, yRadius: radius).fill()
    NSBezierPath(roundedRect: bottom, xRadius: radius, yRadius: radius).fill()
}

func drawWordmark(in rect: NSRect) {
    let connecting = NSAttributedString(
        string: "fluid",
        attributes: [
            .font: NSFont.systemFont(ofSize: rect.height * 0.42, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
    )
    let captions = NSAttributedString(
        string: "Subtitles",
        attributes: [
            .font: NSFont.systemFont(ofSize: rect.height * 0.42, weight: .semibold),
            .foregroundColor: NSColor(srgbRed: 0.176, green: 0.831, blue: 0.749, alpha: 1),
        ]
    )
    let mark = NSMutableAttributedString()
    mark.append(connecting)
    mark.append(captions)
    let size = mark.size()
    mark.draw(at: NSPoint(
        x: (rect.width - size.width) / 2,
        y: (rect.height - size.height) / 2
    ))
}

let iconDir = repoRoot.appendingPathComponent("Sources/FluidSubtitles/Assets.xcassets/AppIcon.appiconset")
let sizes: [(name: String, points: CGFloat, scale: CGFloat)] = [
    ("icon-16@1x.png", 16, 1),
    ("icon-16@2x.png", 16, 2),
    ("icon-32@1x.png", 32, 1),
    ("icon-32@2x.png", 32, 2),
    ("icon-128@1x.png", 128, 1),
    ("icon-128@2x.png", 128, 2),
    ("icon-256@1x.png", 256, 1),
    ("icon-256@2x.png", 256, 2),
    ("icon-512@1x.png", 512, 1),
    ("icon-512@2x.png", 512, 2),
]

for spec in sizes {
    let pixels = Int(spec.points * spec.scale)
    savePNG(
        makeImage(width: pixels, height: pixels, opaque: false) { rect in
            drawCaptionIcon(in: rect, size: CGFloat(pixels))
        },
        to: iconDir.appendingPathComponent(spec.name)
    )
}

let menuDir = repoRoot.appendingPathComponent("Sources/FluidSubtitles/Assets.xcassets/MenuBarIcon.imageset")
for (name, scale) in [("menubar-icon.png", 1), ("menubar-icon@2x.png", 2), ("menubar-icon@3x.png", 3)] {
    let pixels = 18 * scale
    savePNG(
        makeImage(width: pixels, height: pixels) { rect in
            drawMenuBarIcon(in: rect)
        },
        to: menuDir.appendingPathComponent(name)
    )
}

let wordDir = repoRoot.appendingPathComponent("Sources/FluidSubtitles/Assets.xcassets/BrandWordmark.imageset")
savePNG(
    makeImage(width: 640, height: 120) { rect in
        drawWordmark(in: rect)
    },
    to: wordDir.appendingPathComponent("BrandWordmark.png")
)
savePNG(
    makeImage(width: 1280, height: 240) { rect in
        drawWordmark(in: rect)
    },
    to: wordDir.appendingPathComponent("BrandWordmark@2x.png")
)

print("Generated fluidSubtitles brand assets.")
