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

/// Caption gold. Matches AccentColor.
let captionGold = NSColor(srgbRed: 0.910, green: 0.647, blue: 0.294, alpha: 1)
let ink = NSColor(srgbRed: 0.043, green: 0.067, blue: 0.102, alpha: 1)
let spokenWhite = NSColor(srgbRed: 0.96, green: 0.95, blue: 0.92, alpha: 0.78)

/// Show-as title over a shorter spoken line, both left-aligned.
func drawCaptionBars(in rect: NSRect, title: NSColor, spoken: NSColor) {
    let barHeight = rect.height * 0.38
    let gap = rect.height * 0.18
    let spokenHeight = barHeight * 0.78
    let stack = barHeight + gap + spokenHeight
    let originY = rect.minY + (rect.height - stack) / 2
    title.setFill()
    NSBezierPath(
        roundedRect: NSRect(x: rect.minX, y: originY + spokenHeight + gap, width: rect.width, height: barHeight),
        xRadius: barHeight / 2,
        yRadius: barHeight / 2
    ).fill()
    spoken.setFill()
    NSBezierPath(
        roundedRect: NSRect(x: rect.minX, y: originY, width: rect.width * 0.58, height: spokenHeight),
        xRadius: spokenHeight / 2,
        yRadius: spokenHeight / 2
    ).fill()
}

func drawCaptionIcon(in rect: NSRect, size: CGFloat) {
    let inset = size * 0.04
    let canvas = rect.insetBy(dx: inset, dy: inset)
    let corner = canvas.width * 0.223
    let plate = NSBezierPath(roundedRect: canvas, xRadius: corner, yRadius: corner)
    ink.setFill()
    plate.fill()

    NSGraphicsContext.saveGraphicsState()
    plate.addClip()
    NSColor.white.withAlphaComponent(0.05).setFill()
    NSBezierPath(
        roundedRect: NSRect(x: canvas.minX, y: canvas.midY, width: canvas.width, height: canvas.height / 2),
        xRadius: 0,
        yRadius: 0
    ).fill()
    NSGraphicsContext.restoreGraphicsState()

    let mark = canvas.insetBy(dx: canvas.width * 0.16, dy: canvas.height * 0.30)
    drawCaptionBars(in: mark, title: captionGold, spoken: spokenWhite)
}

/// Menu bar mark, 22×18pt. The rounded FS, with the caption pills underneath.
func drawMenuBarIcon(in rect: NSRect) {
    let height = rect.height
    let fontSize = height * 0.58
    let base = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    let rounded = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
    let font = NSFont(descriptor: rounded, size: fontSize) ?? base
    let letters = NSAttributedString(
        string: "FS",
        attributes: [
            .font: font,
            .foregroundColor: NSColor.black,
            .kern: -0.5,
        ]
    )
    let box = letters.size()
    let bar = height * 0.12
    let gap = height * 0.05
    let spoken = bar * 0.78
    let stack = bar + gap + spoken
    let bottom = rect.minY + height * 0.02
    let originX = rect.midX - box.width / 2
    letters.draw(at: NSPoint(x: originX, y: bottom + stack + height * 0.03))

    NSColor.black.setFill()
    NSBezierPath(
        roundedRect: NSRect(x: originX, y: bottom + spoken + gap, width: box.width, height: bar),
        xRadius: bar / 2,
        yRadius: bar / 2
    ).fill()
    NSBezierPath(
        roundedRect: NSRect(x: originX, y: bottom, width: box.width * 0.58, height: spoken),
        xRadius: spoken / 2,
        yRadius: spoken / 2
    ).fill()
}

func wordmarkName(fontSize: CGFloat) -> NSAttributedString {
    let name = NSMutableAttributedString()
    name.append(NSAttributedString(
        string: "fluid",
        attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
    ))
    name.append(NSAttributedString(
        string: "Subtitles",
        attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: captionGold,
        ]
    ))
    return name
}

func drawWordmark(in rect: NSRect) {
    let available = rect.width * 0.88
    var fontSize = rect.height * 0.42
    var name = wordmarkName(fontSize: fontSize)
    var nameSize = name.size()
    var markWidth = nameSize.height * 0.92
    var gap = nameSize.height * 0.22
    while markWidth + gap + nameSize.width > available, fontSize > 12 {
        fontSize *= 0.94
        name = wordmarkName(fontSize: fontSize)
        nameSize = name.size()
        markWidth = nameSize.height * 0.92
        gap = nameSize.height * 0.22
    }
    let total = markWidth + gap + nameSize.width
    let originX = (rect.width - total) / 2
    let originY = (rect.height - nameSize.height) / 2
    drawCaptionBars(
        in: NSRect(x: originX, y: originY, width: markWidth, height: nameSize.height),
        title: captionGold,
        spoken: spokenWhite
    )
    name.draw(at: NSPoint(x: originX + markWidth + gap, y: originY))
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
    savePNG(
        makeImage(width: 22 * scale, height: 18 * scale) { rect in
            drawMenuBarIcon(in: rect)
        },
        to: menuDir.appendingPathComponent(name)
    )
}

let wordDir = repoRoot.appendingPathComponent("Sources/FluidSubtitles/Assets.xcassets/BrandWordmark.imageset")
savePNG(
    makeImage(width: 1024, height: 512) { rect in
        drawWordmark(in: rect)
    },
    to: wordDir.appendingPathComponent("BrandWordmark.png")
)
savePNG(
    makeImage(width: 2048, height: 1024) { rect in
        drawWordmark(in: rect)
    },
    to: wordDir.appendingPathComponent("BrandWordmark@2x.png")
)

print("Generated fluidSubtitles brand assets.")
