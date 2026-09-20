import SwiftUI
import AppKit

/// Renders the treemap and handles hover, click-to-zoom, double-click-to-reveal,
/// the right-click context menu, and the animated zoom transition between levels.
///
/// This is an AppKit view rather than a SwiftUI `Canvas`. `Canvas`, `TimelineView`,
/// `.onContinuousHover` and `SpatialTapGesture` are all macOS 12/13 API, and this
/// one view needed all four — so the whole surface is drawn through CoreGraphics
/// and tracked through `NSTrackingArea` instead, which works identically from
/// macOS 10.15 through the current release. Drawing math is unchanged: the view
/// is flipped so its coordinate space matches the layout engine's top-left origin.
struct TreemapCanvasView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TreemapRepresentable(model: model)
            .contextMenu {
                if let block = model.hoveredBlock {
                    Text(block.node.name)
                    Divider()
                    Button("Reveal in Finder") { model.revealInFinder(block.node) }
                    if block.node.isDirectory, !block.node.children.isEmpty {
                        Button("Zoom In") { model.zoomIn(block.node) }
                    }
                    Button("Copy Path") { model.copyPath(block.node) }
                }
            }
    }
}

private struct TreemapRepresentable: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeNSView(context: Context) -> TreemapNSView {
        let v = TreemapNSView()
        v.model = model
        return v
    }

    func updateNSView(_ v: TreemapNSView, context: Context) {
        v.model = model
        // A running zoom transition drives its own frame clock; otherwise the
        // view repaints only when observed state actually changes.
        v.syncAnimation()
        v.needsDisplay = true
    }
}

// MARK: - The drawing view

final class TreemapNSView: NSView {
    weak var model: AppModel?
    private var timer: Timer?
    private var tracking: NSTrackingArea?

    /// Matches the layout engine's top-left origin, so every rect computed by
    /// `TreemapLayout` is used verbatim.
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopAnimation() }
    }

    deinit { timer?.invalidate() }

    // MARK: Mouse tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        let hit = model.hitTest(point)
        if hit?.id != model.hoveredBlock?.id {
            model.hoveredBlock = hit
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard let model, model.hoveredBlock != nil else { return }
        model.hoveredBlock = nil
        needsDisplay = true
    }

    /// Single click zooms into a folder, double click reveals in Finder — the
    /// same disambiguation the old `ExclusiveGesture` provided.
    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let block = model.hitTest(point) else { return }
        if event.clickCount >= 2 {
            model.revealInFinder(block.node)
        } else if block.node.isDirectory {
            model.zoomIn(block.node)
        }
    }

    /// Keep the hovered block in sync before the SwiftUI context menu opens, so
    /// the menu always describes the block actually under the cursor.
    override func rightMouseDown(with event: NSEvent) {
        if let model {
            let point = convert(event.locationInWindow, from: nil)
            model.hoveredBlock = model.hitTest(point)
        }
        super.rightMouseDown(with: event)
    }

    // MARK: Transition clock

    /// Runs a ~60 fps repaint only while a zoom transition is in flight.
    func syncAnimation() {
        if model?.transition != nil {
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0,
                                             repeats: true) { [weak self] _ in
                    guard let self else { return }
                    if self.model?.transition == nil { self.stopAnimation() }
                    self.needsDisplay = true
                }
                if let timer { RunLoop.main.add(timer, forMode: .common) }
            }
        } else {
            stopAnimation()
        }
    }

    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let model,
              let cg = NSGraphicsContext.current?.cgContext else { return }
        var ctx = TreemapContext(cg: cg)
        draw(in: &ctx, size: bounds.size, at: Date())
    }

    private func draw(in context: inout TreemapContext, size: CGSize, at date: Date) {
        guard let model else { return }
        let canvasRect = CGRect(origin: .zero, size: size)
        context.fill(CGPath(rect: canvasRect, transform: nil), with: NSColor(white: 0.07, alpha: 1))

        let blocks = model.blocks(for: size)
        guard !blocks.isEmpty else { return }

        if let t = model.transition {
            let raw = min(max(date.timeIntervalSince(t.start) / t.duration, 0), 1)
            if raw < 1, let focus = focusRect(for: t, newBlocks: blocks) {
                drawTransition(t, progress: easeInOut(raw), focusRect: focus,
                               newBlocks: blocks, canvasRect: canvasRect, in: &context)
                return
            }
        }

        drawBlocks(blocks, in: &context,
                   totalBytes: model.currentNode?.size ?? 0, detailed: true)

        // Hover highlight painted last so it sits above nested levels.
        if model.transition == nil, let hovered = model.hoveredBlock {
            let rect = hovered.rect.insetBy(dx: 1, dy: 1)
            context.stroke(CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3,
                                  transform: nil),
                           with: NSColor.white.withAlphaComponent(0.9), lineWidth: 2)
        }
    }

    /// The rect the transition zooms into/out of. zoomIn: the clicked block in
    /// the old layout; zoomOut: the departed node in the new layout. Walks up
    /// the parent chain so deep breadcrumb jumps still find a visible anchor.
    private func focusRect(for t: AppModel.ZoomTransition,
                           newBlocks: [LayoutBlock]) -> CGRect? {
        let searchBlocks = t.direction == .zoomIn ? t.oldBlocks : newBlocks
        var node: FileNode? = t.focusNode
        while let current = node {
            if let match = searchBlocks.first(where: { $0.node === current }) {
                return match.rect.width > 1 && match.rect.height > 1 ? match.rect : nil
            }
            node = current.parent
        }
        return nil
    }

    /// Geometric zoom: the entered level is drawn squeezed into the focus rect
    /// and expands to fill the canvas while the departed level scales away
    /// around it (reversed when zooming out) — so every element slides from its
    /// old position to its new one.
    private func drawTransition(_ t: AppModel.ZoomTransition, progress: Double,
                                focusRect: CGRect, newBlocks: [LayoutBlock],
                                canvasRect: CGRect, in context: inout TreemapContext) {
        let outerBlocks: [LayoutBlock]
        let innerBlocks: [LayoutBlock]
        let frame: CGRect
        switch t.direction {
        case .zoomIn:
            frame = lerp(focusRect, canvasRect, progress)
            outerBlocks = t.oldBlocks
            innerBlocks = newBlocks
        case .zoomOut:
            frame = lerp(canvasRect, focusRect, progress)
            outerBlocks = newBlocks
            innerBlocks = t.oldBlocks
        }

        // Outer layer: the surrounding level, transformed so the focus rect
        // tracks `frame`.
        let sx = frame.width / focusRect.width
        let sy = frame.height / focusRect.height
        context.drawLayer { ctx in
            ctx.translateBy(x: frame.minX - focusRect.minX * sx,
                            y: frame.minY - focusRect.minY * sy)
            ctx.scaleBy(x: sx, y: sy)
            drawBlocks(outerBlocks, in: &ctx, totalBytes: 0, detailed: false)
        }

        // Inner layer: the entered/departed level, compressed into `frame`.
        context.drawLayer { ctx in
            ctx.clip(to: frame)
            ctx.translateBy(x: frame.minX, y: frame.minY)
            ctx.scaleBy(x: frame.width / canvasRect.width,
                        y: frame.height / canvasRect.height)
            drawBlocks(innerBlocks, in: &ctx, totalBytes: 0, detailed: false)
        }

        context.stroke(CGPath(roundedRect: frame, cornerWidth: 3, cornerHeight: 3,
                              transform: nil),
                       with: NSColor.white.withAlphaComponent(0.55), lineWidth: 1.5)
    }

    private func drawBlocks(_ blocks: [LayoutBlock], in context: inout TreemapContext,
                            totalBytes: Int64, detailed: Bool) {
        // Blocks arrive parent-before-children, so nested levels paint on top
        // of their containing directory block.
        for block in blocks {
            // Wider gaps between top-level blocks than between nested ones —
            // the dark canvas showing through is what separates subdivisions.
            let inset: CGFloat = block.depth == 0 ? 1.75 : 1.25
            let rect = block.rect.insetBy(dx: inset, dy: inset)
            guard rect.width > 0.5, rect.height > 0.5 else { continue }
            let radius = min(3, min(rect.width, rect.height) / 4)
            let path = CGPath(roundedRect: rect, cornerWidth: radius,
                              cornerHeight: radius, transform: nil)
            context.fill(path, with: block.nsColor)
            context.stroke(path, with: NSColor.black.withAlphaComponent(0.5), lineWidth: 0.6)

            // Root-locked items get a red inner outline: you can't modify (and
            // usually can't open) them without admin rights.
            if block.restricted, rect.width > 3, rect.height > 3 {
                let innerRect = rect.insetBy(dx: 1.2, dy: 1.2)
                let innerRadius = min(2.5, min(innerRect.width, innerRect.height) / 4)
                context.stroke(CGPath(roundedRect: innerRect, cornerWidth: innerRadius,
                                      cornerHeight: innerRadius, transform: nil),
                               with: NSColor(red: 0.95, green: 0.23, blue: 0.21, alpha: 1),
                               lineWidth: 1.2)
            }

            if block.hasTitleStrip {
                drawStripLabel(for: block, rect: rect, in: &context)
            } else if detailed, !block.subdivided {
                drawCenteredLabel(for: block, rect: rect, in: &context,
                                  totalBytes: totalBytes)
            }
        }
    }

    /// Folder name in the reserved title strip of a subdivided directory block.
    private func drawStripLabel(for block: LayoutBlock, rect: CGRect,
                                in context: inout TreemapContext) {
        guard rect.width > 48 else { return }
        var title = block.node.name
        if rect.width > 200 {
            title += "  —  " + AppModel.format(bytes: block.node.size)
        }
        context.drawText(title,
                         size: block.depth == 0 ? 12.5 : 11.5, weight: .semibold,
                         color: NSColor.white.withAlphaComponent(0.95),
                         in: CGRect(x: rect.minX + 6, y: rect.minY + 2.5,
                                    width: rect.width - 12,
                                    height: TreemapLayout.titleStripHeight - 4))
    }

    /// Name centered in a leaf block, with "share% · size" beneath it. Each
    /// line is measured first and omitted entirely if it would overflow.
    private func drawCenteredLabel(for block: LayoutBlock, rect: CGRect,
                                   in context: inout TreemapContext, totalBytes: Int64) {
        guard rect.width >= 36, rect.height >= 22 else { return }
        let fontSize = max(11, min(17, min(rect.width, rect.height) * 0.15))

        // Cheap over-estimate to skip measuring text that can't possibly fit.
        guard CGFloat(block.node.name.count) * fontSize * 0.5 < rect.width else { return }

        let textColor: NSColor = block.brightness > 0.62
            ? NSColor.black.withAlphaComponent(0.78) : NSColor.white

        let nameSize = context.measure(block.node.name, size: fontSize, weight: .semibold)
        guard nameSize.width <= rect.width - 8, nameSize.height <= rect.height - 4 else { return }

        var detailString: String?
        var detailFontSize: CGFloat = 0
        var detailSize = CGSize.zero
        if totalBytes > 0 {
            let pct = Double(block.node.size) / Double(totalBytes) * 100
            let pctString = pct >= 10 ? String(format: "%.0f%%", pct)
                                      : String(format: "%.1f%%", pct)
            let string = "\(pctString) · \(AppModel.format(bytes: block.node.size))"
            let size = max(9, fontSize - 3.5)
            let measured = context.measure(string, size: size, weight: .medium)
            if measured.width <= rect.width - 8,
               nameSize.height + measured.height + 1 <= rect.height - 6 {
                detailString = string
                detailFontSize = size
                detailSize = measured
            }
        }

        if let detailString {
            let totalHeight = nameSize.height + 1 + detailSize.height
            let nameCenterY = rect.midY - totalHeight / 2 + nameSize.height / 2
            context.drawTextCentered(block.node.name, size: fontSize, weight: .semibold,
                                     color: textColor,
                                     at: CGPoint(x: rect.midX, y: nameCenterY))
            context.drawTextCentered(detailString, size: detailFontSize, weight: .medium,
                                     color: textColor.withAlphaComponent(0.75),
                                     at: CGPoint(x: rect.midX,
                                                 y: nameCenterY + nameSize.height / 2
                                                    + 1 + detailSize.height / 2))
        } else {
            context.drawTextCentered(block.node.name, size: fontSize, weight: .semibold,
                                     color: textColor,
                                     at: CGPoint(x: rect.midX, y: rect.midY))
        }
    }

    // MARK: - Animation helpers

    private func easeInOut(_ x: Double) -> Double {
        x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
    }

    private func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t,
               y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t,
               height: a.height + (b.height - a.height) * t)
    }
}

// MARK: - CoreGraphics drawing context

/// The subset of `GraphicsContext` the treemap needs, backed by CGContext so it
/// works on every supported macOS. Text is measured and drawn through
/// NSAttributedString, which is the AppKit equivalent of resolving a `Text`.
struct TreemapContext {
    let cg: CGContext

    func fill(_ path: CGPath, with color: NSColor) {
        cg.saveGState()
        cg.addPath(path)
        cg.setFillColor(color.cgColor)
        cg.fillPath()
        cg.restoreGState()
    }

    func stroke(_ path: CGPath, with color: NSColor, lineWidth: CGFloat) {
        cg.saveGState()
        cg.addPath(path)
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(lineWidth)
        cg.strokePath()
        cg.restoreGState()
    }

    /// Mirrors `GraphicsContext.drawLayer`: a saved/restored nested context.
    func drawLayer(_ body: (inout TreemapContext) -> Void) {
        cg.saveGState()
        var nested = self
        body(&nested)
        cg.restoreGState()
    }

    func translateBy(x: CGFloat, y: CGFloat) { cg.translateBy(x: x, y: y) }
    func scaleBy(x: CGFloat, y: CGFloat) { cg.scaleBy(x: x, y: y) }
    func clip(to rect: CGRect) { cg.clip(to: rect) }

    // MARK: Text

    private func attributes(size: CGFloat, weight: NSFont.Weight,
                            color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size, weight: weight),
         .foregroundColor: color]
    }

    func measure(_ string: String, size: CGFloat, weight: NSFont.Weight) -> CGSize {
        NSAttributedString(string: string,
                           attributes: attributes(size: size, weight: weight,
                                                  color: .white)).size()
    }

    func drawText(_ string: String, size: CGFloat, weight: NSFont.Weight,
                  color: NSColor, in rect: CGRect) {
        let attributed = NSAttributedString(
            string: string,
            attributes: attributes(size: size, weight: weight, color: color))
        cg.saveGState()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        attributed.draw(with: rect, options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
        cg.restoreGState()
    }

    func drawTextCentered(_ string: String, size: CGFloat, weight: NSFont.Weight,
                          color: NSColor, at point: CGPoint) {
        let attributed = NSAttributedString(
            string: string,
            attributes: attributes(size: size, weight: weight, color: color))
        let measured = attributed.size()
        let origin = CGPoint(x: point.x - measured.width / 2,
                             y: point.y - measured.height / 2)
        cg.saveGState()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        attributed.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
        cg.restoreGState()
    }
}
