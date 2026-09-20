import SwiftUI
import AppKit

/// User-selectable color scheme: the hue range that top-level color families
/// are drawn from. Shading within a family (depth + sibling gradients) is the
/// same for every palette.
enum TreemapPalette: String, CaseIterable, Identifiable {
    case spectrum = "Spectrum"
    case ocean = "Ocean"
    case sunset = "Sunset"
    case forest = "Forest"
    case mono = "Monochrome"

    var id: String { rawValue }

    var hueRange: (start: Double, span: Double) {
        switch self {
        case .spectrum: return (0.0, 1.0)
        case .ocean: return (0.45, 0.30)
        case .sunset: return (0.86, 0.28)
        case .forest: return (0.16, 0.30)
        case .mono: return (0.58, 0.0)
        }
    }
}

/// A positioned, draw-ready treemap block.
struct LayoutBlock: Identifiable {
    let node: FileNode
    let rect: CGRect
    let depth: Int
    let color: Color
    /// The same fill as `color`, in AppKit form. The treemap is drawn through
    /// CoreGraphics (see TreemapCanvasView), and SwiftUI `Color` cannot be
    /// converted to `NSColor`/`CGColor` before macOS 11 — so the layout engine
    /// hands both spellings out, built from the identical HSB components.
    let nsColor: NSColor
    /// HSB brightness of `color` — used to pick a readable label color.
    let brightness: Double
    /// True when this directory block's children are laid out inside it.
    let subdivided: Bool
    /// True when a title strip is reserved at the top of a subdivided block.
    let hasTitleStrip: Bool
    /// True for root-locked items (owned by root, not user-writable) surfaced by
    /// the privileged scan — drawn with a red inner outline.
    let restricted: Bool

    var id: ObjectIdentifier { ObjectIdentifier(node) }
}

/// Builds the multi-level block list for one zoom level.
///
/// Depth 0 blocks are the current node's children and partition the full
/// canvas exactly (they are the interactive layer: hover/click/zoom). Each
/// directory block is then subdivided *inside* an inset rect down to
/// `maxDepth`, skipping blocks too small to read — so layout cost is bounded
/// by visible pixels, never by total file count.
enum TreemapLayout {
    static let titleStripHeight: CGFloat = 20

    static func build(node: FileNode, in rect: CGRect, maxDepth: Int = 3,
                      palette: TreemapPalette = .spectrum) -> [LayoutBlock] {
        var blocks: [LayoutBlock] = []
        layoutChildren(of: node, in: rect, depth: 0, maxDepth: maxDepth,
                       palette: palette, familyHue: nil, into: &blocks)
        return blocks
    }

    private static func layoutChildren(of node: FileNode, in rect: CGRect, depth: Int,
                                       maxDepth: Int, palette: TreemapPalette,
                                       familyHue: Double?,
                                       into blocks: inout [LayoutBlock]) {
        let children = node.children.filter { $0.size > 0 }
        guard !children.isEmpty, rect.width >= 2, rect.height >= 2 else { return }

        let rects = Squarify.layout(weights: children.map { Double($0.size) },
                                    in: rect)
        for (index, (child, childRect)) in zip(children, rects).enumerated() {
            guard childRect.width >= 0.5, childRect.height >= 0.5 else { continue }
            let hue = familyHue ?? topLevelHue(index: index, palette: palette)
            // 0 for the largest sibling … 1 for the smallest: drives the
            // bright-to-dark gradient across a subdivision.
            let position = children.count > 1
                ? Double(index) / Double(children.count - 1) : 0

            var subdivided = false
            var hasTitleStrip = false
            var inner = CGRect.zero
            if child.isDirectory, depth + 1 < maxDepth, !child.children.isEmpty {
                let stripFits = depth == 0
                    ? childRect.width > 60 && childRect.height > 44
                    : childRect.width > 110 && childRect.height > 68
                let topInset: CGFloat = stripFits ? titleStripHeight : 3
                inner = CGRect(x: childRect.minX + 2,
                               y: childRect.minY + topInset,
                               width: childRect.width - 4,
                               height: childRect.height - topInset - 2)
                if inner.width > 8, inner.height > 8, inner.width * inner.height > 400 {
                    subdivided = true
                    hasTitleStrip = stripFits
                }
            }

            let fill = fill(for: child, depth: depth, hue: hue, position: position)
            blocks.append(LayoutBlock(node: child, rect: childRect, depth: depth,
                                      color: fill.color, nsColor: fill.nsColor,
                                      brightness: fill.brightness,
                                      subdivided: subdivided, hasTitleStrip: hasTitleStrip,
                                      restricted: child.restricted))
            if subdivided {
                layoutChildren(of: child, in: inner, depth: depth + 1,
                               maxDepth: maxDepth, palette: palette,
                               familyHue: hue, into: &blocks)
            }
        }
    }

    // MARK: - Colors

    /// Each depth-0 block claims its own hue; every block nested inside it
    /// reuses that hue, so a whole subdivision reads as one color family.
    /// Golden-angle steps keep neighboring top-level hues far apart, mapped
    /// into the palette's hue range; the order is stable per scan (children
    /// are sorted by size).
    private static func topLevelHue(index: Int, palette: TreemapPalette) -> Double {
        let fraction = (0.12 + Double(index) * 0.61803398875).truncatingRemainder(dividingBy: 1)
        let (start, span) = palette.hueRange
        return (start + fraction * span).truncatingRemainder(dividingBy: 1)
    }

    /// Shade within a subdivision's color family. Two gradients compose:
    /// depth darkens every level, and `position` (size rank among siblings)
    /// sweeps each folder's children from bright to dark — so every sub-block
    /// is a distinct shade of its family color. Directories stay markedly
    /// darker than files at the same level so containers remain obvious.
    static func fill(for node: FileNode, depth: Int, hue: Double,
                     position: Double) -> (color: Color, nsColor: NSColor, brightness: Double) {
        if node.isDirectory {
            let brightness = max(0.18, 0.42 - Double(depth) * 0.05 - position * 0.14)
            return (Color(hue: hue, saturation: 0.45, brightness: brightness),
                    NSColor(hue: hue, saturation: 0.45, brightness: brightness, alpha: 1),
                    brightness)
        }
        let brightness = min(0.92, max(0.32, 0.86 - Double(depth) * 0.08 - position * 0.30))
        let saturation = max(0.32, 0.58 - Double(depth) * 0.05)
        return (Color(hue: hue, saturation: saturation, brightness: brightness),
                NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1),
                brightness)
    }
}
