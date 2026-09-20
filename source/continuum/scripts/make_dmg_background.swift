// Renders the install DMG background (a gradient with the product name, a
// tagline, an arrow, and a "drag to install" hint) without Xcode.
//
// Usage: swift scripts/make_dmg_background.swift <output.png>
// Coordinates here are AppKit bottom-left; the Finder icon positions in
// make-dmg.sh are top-left, so the two are kept in sync by hand.

import AppKit

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : ".build/dmg-background.png"

// Logical window size (points). The Finder icon coordinates in make-dmg.sh
// are expressed in these same logical points, so the drawing math below stays
// in this coordinate space regardless of the render scale.
let W = 640, H = 400

// Render 1:1 with the window's point size. Finder lays out the DMG background
// by the PNG's *pixel* dimensions and ignores its DPI tag, so a 2× (1280×800)
// bitmap is treated as a 1280×800-point image and the 640-point window only
// shows a zoomed-in corner. Keeping pixels == points (640×400) makes the image
// fit the window exactly. `scale` stays here so the drawing math is unchanged.
let scale = 1
let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: W * scale, pixelsHigh: H * scale,
                           bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
ctx.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

let bounds = NSRect(x: 0, y: 0, width: W, height: H)

// Backdrop: a soft top-to-bottom gradient with a subtle accent glow.
NSGradient(
    starting: NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.18, alpha: 1),
    ending:   NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.09, alpha: 1)
)!.draw(in: bounds, angle: -90)

NSGradient(
    starting: NSColor(calibratedRed: 0.20, green: 0.55, blue: 1.0, alpha: 0.22),
    ending:   NSColor(calibratedRed: 0.20, green: 0.55, blue: 1.0, alpha: 0.0)
)!.draw(in: NSRect(x: -120, y: H - 360, width: 520, height: 520),
        relativeCenterPosition: NSPoint(x: 0, y: 0))

// Helper: draw centred text.
func draw(_ text: String, font: NSFont, color: NSColor, centerX: CGFloat, baselineY: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let s = NSAttributedString(string: text, attributes: attrs)
    let size = s.size()
    s.draw(at: NSPoint(x: centerX - size.width / 2, y: baselineY))
}

// Title + tagline (top of the window).
draw("Continuum",
     font: .systemFont(ofSize: 38, weight: .bold),
     color: .white,
     centerX: CGFloat(W) / 2, baselineY: 322)
draw("See it.  Clean it.  Secure it.",
     font: .systemFont(ofSize: 15, weight: .medium),
     color: NSColor.white.withAlphaComponent(0.62),
     centerX: CGFloat(W) / 2, baselineY: 296)

// Arrow between the app icon (left) and the Applications alias (right).
// Finder places both icon centres at y=230 (top-left) → AppKit y≈170.
let arrowY: CGFloat = 175
let arrow = NSBezierPath()
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 258, y: arrowY))
arrow.line(to: NSPoint(x: 372, y: arrowY))
arrow.move(to: NSPoint(x: 372, y: arrowY))
arrow.line(to: NSPoint(x: 356, y: arrowY + 13))
arrow.move(to: NSPoint(x: 372, y: arrowY))
arrow.line(to: NSPoint(x: 356, y: arrowY - 13))
NSColor(calibratedRed: 0.35, green: 0.7, blue: 1.0, alpha: 0.95).setStroke()
arrow.stroke()

// Footer hint.
draw("Drag Continuum onto the Applications folder to install",
     font: .systemFont(ofSize: 13, weight: .regular),
     color: NSColor.white.withAlphaComponent(0.5),
     centerX: CGFloat(W) / 2, baselineY: 40)

NSGraphicsContext.restoreGraphicsState()

let data = rep.representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
