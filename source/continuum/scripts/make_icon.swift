// Generates AppIcon.icns without Xcode: draws a rounded-rect gradient tile
// with a white internal-drive symbol at every required size, then compiles
// the iconset with the system `iconutil`.
//
// Usage: swift scripts/make_icon.swift <output.icns>

import AppKit

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : ".build/AppIcon.icns"

/// (pixel size, iconset filename) pairs required by iconutil.
let variants: [(Int, String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

func renderIcon(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(pixels)
    // macOS-style margin: the tile does not fill the full canvas.
    let inset = s * 0.09
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: tile, xRadius: s * 0.20, yRadius: s * 0.20)

    NSGradient(
        starting: NSColor(calibratedRed: 0.22, green: 0.55, blue: 0.98, alpha: 1),
        ending:   NSColor(calibratedRed: 0.04, green: 0.22, blue: 0.55, alpha: 1)
    )!.draw(in: path, angle: -90)

    drawSymbol("internaldrive.fill", pointSize: s * 0.40, weight: .medium,
               center: NSPoint(x: s * 0.5, y: s * 0.48), canvas: s)
    drawSymbol("sparkles", pointSize: s * 0.16, weight: .semibold,
               center: NSPoint(x: s * 0.70, y: s * 0.70), canvas: s)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// Draws an SF Symbol tinted white, centered at `center`.
func drawSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight,
                center: NSPoint, canvas: CGFloat) {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
          let sized = base.withSymbolConfiguration(
              NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
    else { return }

    // Tint: draw the symbol, then flood with white using sourceAtop so only
    // the symbol's own pixels are recolored.
    let tinted = NSImage(size: sized.size)
    tinted.lockFocus()
    sized.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor.white.set()
    NSRect(origin: .zero, size: sized.size).fill(using: .sourceAtop)
    tinted.unlockFocus()

    let rect = NSRect(x: center.x - sized.size.width / 2,
                      y: center.y - sized.size.height / 2,
                      width: sized.size.width, height: sized.size.height)
    tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
}

// Assemble the .iconset and compile it.
let fm = FileManager.default
let iconsetURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("CacheClean-\(ProcessInfo.processInfo.processIdentifier).iconset")
try fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconsetURL) }

for (pixels, filename) in variants {
    try renderIcon(pixels: pixels).write(to: iconsetURL.appendingPathComponent(filename))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputPath]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fputs("iconutil failed with status \(iconutil.terminationStatus)\n", stderr)
    exit(1)
}
print("Wrote \(outputPath)")
