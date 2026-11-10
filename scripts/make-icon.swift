// Renders the app icon (white waveform bars on a warm rounded square) to a 1024×1024 PNG.
// Drawn entirely in code, so it isn't derived from an SF Symbol (Apple doesn't allow those in app icons).
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = URL(fileURLWithPath: CommandLine.arguments[1])

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // macOS icon grid: 824 pt body, centred, ~185 pt corner radius.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGradient(colors: [
        NSColor(red: 0.98, green: 0.45, blue: 0.29, alpha: 1),
        NSColor(red: 0.86, green: 0.22, blue: 0.36, alpha: 1),
    ])!.draw(in: shape, angle: -90)

    // Seven rounded bars of a spoken phrase: quiet in, loud in the middle, trailing off.
    let heights: [CGFloat] = [150, 290, 440, 310, 480, 250, 130]
    let barWidth: CGFloat = 58, gap: CGFloat = 36
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    NSColor.white.setFill()
    for (i, height) in heights.enumerated() {
        let x = (size - total) / 2 + CGFloat(i) * (barWidth + gap)
        let bar = NSRect(x: x, y: (size - height) / 2, width: barWidth, height: height)
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: output)
