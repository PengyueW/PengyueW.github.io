// Renders the app icon (a page with the Markdown "M↓" mark) into an .iconset folder.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024

    // Page with a soft shadow.
    let page = NSRect(x: 150 * s, y: 90 * s, width: 724 * s, height: 844 * s)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 28 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(white: 0.985, alpha: 1).setFill()
    NSBezierPath(roundedRect: page, xRadius: 70 * s, yRadius: 70 * s).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Accent header band.
    let band = NSBezierPath(roundedRect: NSRect(x: page.minX, y: page.maxY - 190 * s, width: page.width, height: 190 * s),
                            xRadius: 70 * s, yRadius: 70 * s)
    band.append(NSBezierPath(rect: NSRect(x: page.minX, y: page.maxY - 190 * s, width: page.width, height: 90 * s)))
    NSGradient(starting: NSColor(red: 0.20, green: 0.47, blue: 0.98, alpha: 1),
               ending: NSColor(red: 0.42, green: 0.33, blue: 0.95, alpha: 1))!.draw(in: band, angle: 0)

    // Text lines.
    NSColor(white: 0.82, alpha: 1).setFill()
    for (i, w) in [520, 600, 430].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: 230 * s, y: (240 + CGFloat(i) * 70) * s, width: CGFloat(w) * s, height: 30 * s),
                     xRadius: 15 * s, yRadius: 15 * s).fill()
    }

    // "M↓" mark.
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 250 * s, weight: .heavy),
        .foregroundColor: NSColor(white: 0.16, alpha: 1),
    ]
    let mark = NSAttributedString(string: "M↓", attributes: attrs)
    let size = mark.size()
    mark.draw(at: NSPoint(x: (1024 * s - size.width) / 2, y: 470 * s))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
