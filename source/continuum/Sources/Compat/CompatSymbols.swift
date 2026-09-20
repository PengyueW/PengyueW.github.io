//  CompatSymbols.swift — SF Symbols fallback for macOS 10.15 … 13.
//
//  Two separate problems, and for a long time only the first was handled:
//
//  1. SF Symbols (and `Image(systemName:)`) arrived in macOS 11. On Catalina
//     the glyphs do not exist at all, so `CompatSymbol` substitutes a Unicode
//     character chosen to carry the same meaning at the same optical weight.
//
//  2. The SF Symbols *catalogue* keeps growing, and a name added in a later
//     release simply does not resolve on an earlier one. `Image(systemName:)`
//     does not fail loudly when that happens — it renders **nothing**. So a
//     macOS 11 machine showed blank gaps wherever the app asked for a symbol
//     introduced in SF Symbols 3 (macOS 12) or 4 (macOS 13): `cross.vial`,
//     `eraser.line.dashed`, `puzzlepiece.extension`, `shield.lefthalf.filled`,
//     `wrench.adjustable`, `square.grid.3x3.topleft.filled` … That is what the
//     missing sidebar and page icons on the macOS 11 build were.
//
//  Rather than hard-code a name→OS-version table (which would need revisiting
//  for every future symbol and every future OS), `resolvedName` *asks the
//  running system* whether a symbol exists, via `NSImage(systemSymbolName:)`,
//  and walks a chain of progressively older equivalents until one answers.
//  Anything that resolves nowhere degrades to the Unicode glyph, so a symbol
//  can never render as empty space again — including on macOS 13, where
//  `internaldrive.badge.questionmark` turns out not to exist either.

import SwiftUI
import AppKit

enum CompatSymbol {
    /// Unicode stand-ins for the 71 SF Symbols used across the suite.
    static let fallback: [String: String] = [
        "antenna.radiowaves.left.and.right": "((\u{2022}))",
        "archivebox": "\u{1F5C3}", "archivebox.fill": "\u{1F5C3}",
        "arrow.clockwise": "\u{21BB}", "arrow.counterclockwise": "\u{21BA}",
        "arrow.triangle.2.circlepath": "\u{27F3}",
        "arrow.uturn.backward": "\u{21A9}", "arrow.uturn.backward.circle": "\u{21A9}",
        "battery.0": "\u{1F50B}", "bell.badge": "\u{1F514}",
        "chart.bar.xaxis": "\u{1F4CA}", "checkmark": "\u{2713}",
        "checkmark.circle.fill": "\u{2705}", "checkmark.seal": "\u{2714}",
        "checkmark.seal.fill": "\u{2714}", "checkmark.shield.fill": "\u{1F6E1}",
        "chevron.left": "\u{2039}", "chevron.right": "\u{203A}",
        "clock": "\u{1F553}", "clock.arrow.circlepath": "\u{1F553}",
        "cross.vial": "\u{1F9EA}", "doc": "\u{1F4C4}", "doc.on.doc": "\u{1F4CB}",
        "eraser.line.dashed": "\u{2327}", "exclamationmark.shield.fill": "\u{26A0}",
        "exclamationmark.triangle": "\u{26A0}", "exclamationmark.triangle.fill": "\u{26A0}",
        "eye.slash": "\u{1F648}", "folder": "\u{1F4C1}",
        "gearshape": "\u{2699}", "gearshape.2": "\u{2699}", "globe": "\u{1F310}",
        "hand.raised": "\u{270B}", "hand.raised.fill": "\u{270B}",
        "heart.fill": "\u{2665}", "house": "\u{1F3E0}", "house.fill": "\u{1F3E0}",
        "info.circle": "\u{2139}", "internaldrive": "\u{1F5B4}",
        "internaldrive.badge.questionmark": "\u{1F5B4}?", "internaldrive.fill": "\u{1F5B4}",
        "key": "\u{1F511}", "list.bullet.rectangle": "\u{2261}",
        "lock": "\u{1F512}", "lock.open.fill": "\u{1F513}",
        "lock.shield": "\u{1F512}", "lock.shield.fill": "\u{1F512}",
        "magnifyingglass": "\u{1F50D}", "magnifyingglass.circle": "\u{1F50D}",
        "minus.circle": "\u{2296}", "number": "#", "paintpalette": "\u{1F3A8}",
        "play.fill": "\u{25B6}", "plus": "+", "plus.magnifyingglass": "\u{1F50D}+",
        "puzzlepiece.extension": "\u{1F9E9}", "questionmark.folder": "\u{1F4C1}?",
        "scissors": "\u{2702}", "scissors.badge.ellipsis": "\u{2702}",
        "shield.lefthalf.filled": "\u{1F6E1}",
        "square.grid.3x3.topleft.filled": "\u{25A6}", "stop.fill": "\u{25A0}",
        "terminal": "\u{2318}", "thermometer.snowflake": "\u{2744}",
        "trash": "\u{1F5D1}", "trash.slash": "\u{1F5D1}", "trash.square": "\u{1F5D1}",
        "wand.and.stars": "\u{2728}", "wrench.adjustable": "\u{1F527}",
        "xmark.circle.fill": "\u{274C}", "xmark.seal": "\u{2717}",
    ]

    static func glyph(_ name: String) -> String { fallback[name] ?? "\u{2022}" }

    /// Older SF Symbols carrying the same meaning, tried in order when the
    /// requested name does not exist on the running system. Only names that
    /// have been in the catalogue since SF Symbols 1–2 (macOS 11) belong at
    /// the end of a chain, otherwise there is nothing to land on.
    private static let substitutes: [String: [String]] = [
        "cross.vial":                     ["cross.case", "bandage"],
        "eraser.line.dashed":             ["eraser", "scissors"],
        "puzzlepiece.extension":          ["puzzlepiece"],
        "shield.lefthalf.filled":         ["shield.lefthalf.fill", "shield"],
        "square.grid.3x3.topleft.filled": ["square.grid.3x3.fill", "square.grid.3x3"],
        "wrench.adjustable":              ["wrench"],
        "internaldrive.badge.questionmark": ["internaldrive", "externaldrive"],
        "internaldrive":                  ["externaldrive"],
        "internaldrive.fill":             ["externaldrive.fill", "internaldrive"],
        "trash.slash":                    ["trash"],
        "trash.square":                   ["trash"],
        "scissors.badge.ellipsis":        ["scissors"],
        "clock.arrow.circlepath":         ["clock"],
        "arrow.triangle.2.circlepath":    ["arrow.clockwise"],
        "chart.bar.xaxis":                ["chart.bar"],
        "list.bullet.rectangle":          ["list.bullet"],
        "thermometer.snowflake":          ["thermometer"],
        "magnifyingglass.circle":         ["magnifyingglass"],
        "plus.magnifyingglass":           ["magnifyingglass"],
        "questionmark.folder":            ["folder"],
        "bell.badge":                     ["bell"],
        "gearshape.2":                    ["gearshape", "gear"],
        "gearshape":                      ["gear"],
        "hand.raised.fill":               ["hand.raised"],
        "checkmark.shield.fill":          ["checkmark.shield"],
        "exclamationmark.shield.fill":    ["exclamationmark.shield"],
        "lock.shield.fill":               ["lock.shield", "lock"],
        "checkmark.seal.fill":            ["checkmark.seal", "checkmark.circle"],
        "xmark.seal":                     ["xmark.circle"],
        "eraser":                         ["scissors"],
        "wand.and.stars":                 ["sparkles"],
        "paintpalette":                   ["paintbrush"],
        "cross.case":                     ["bandage"],
    ]

    /// Cache of name → resolved name (or nil when nothing in the chain exists).
    /// `NSImage(systemSymbolName:)` is not free and icons re-render constantly,
    /// so each name is probed once per launch. Confined to the main actor,
    /// which is where SwiftUI evaluates view bodies.
    private static var resolutionCache: [String: String?] = [:]

    /// The name to hand `Image(systemName:)`, or nil when the running system
    /// has no symbol for this concept and the caller should draw the glyph.
    @available(macOS 11.0, *)
    static func resolvedName(_ name: String) -> String? {
        if let cached = resolutionCache[name] { return cached }
        var result: String?
        for candidate in [name] + (substitutes[name] ?? []) {
            if NSImage(systemSymbolName: candidate, accessibilityDescription: nil) != nil {
                result = candidate
                break
            }
        }
        resolutionCache[name] = result
        return result
    }
}

/// Drop-in for `Image(systemName:)` that works back to macOS 10.15 — and, on
/// every version, degrades a symbol the OS does not know to a Unicode glyph
/// instead of rendering blank.
struct CompatIcon: View {
    let name: String
    init(_ name: String) { self.name = name }
    var body: some View {
        if #available(macOS 11.0, *), let resolved = CompatSymbol.resolvedName(name) {
            Image(systemName: resolved)
        } else {
            Text(CompatSymbol.glyph(name))
        }
    }
}

/// Drop-in for `Label(_:systemImage:)`, which is macOS 11+.
struct CompatLabel: View {
    private let text: Text
    private let systemImage: String

    /// Literals bind to this overload, so they keep resolving against the
    /// bundled .lproj tables — the suite ships 12 localisations.
    init(_ title: LocalizedStringKey, systemImage: String) {
        self.text = Text(title); self.systemImage = systemImage
    }
    /// Runtime strings (already-formatted messages, service names) bind here.
    init<S: StringProtocol>(_ title: S, systemImage: String) {
        self.text = Text(title); self.systemImage = systemImage
    }

    var body: some View {
        if #available(macOS 11.0, *), let resolved = CompatSymbol.resolvedName(systemImage) {
            Label { text } icon: { Image(systemName: resolved) }
        } else {
            HStack(spacing: 6) { Text(CompatSymbol.glyph(systemImage)); text }
        }
    }
}

/// Drop-in for `ProgressView`, which is macOS 11+. Covers the three shapes the
/// app uses: indeterminate spinner, determinate bar, and labelled bar.
struct CompatProgress: View {
    var value: Double?
    var total: Double = 1
    var label: LocalizedStringKey?

    init() {}
    init(_ label: LocalizedStringKey) { self.label = label }
    init<S: StringProtocol>(_ label: S) { self.label = LocalizedStringKey(String(label)) }
    init(value: Double?, total: Double = 1) { self.value = value; self.total = total }
    init(_ label: LocalizedStringKey, value: Double?, total: Double = 1) {
        self.label = label; self.value = value; self.total = total
    }

    var body: some View {
        if #available(macOS 11.0, *) {
            if let v = value {
                if let l = label { ProgressView(l, value: v, total: total) }
                else { ProgressView(value: v, total: total) }
            } else {
                if let l = label { ProgressView(l) } else { ProgressView() }
            }
        } else {
            LegacyProgress(value: value, total: total, label: label)
        }
    }
}

/// NSProgressIndicator bridge — the only progress control available on 10.15.
private struct LegacyProgress: View {
    var value: Double?
    var total: Double
    var label: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let l = label { Text(l).font(.caption) }
            LegacyIndicator(value: value, total: total)
                .frame(height: value == nil ? 18 : 10)
        }
    }
}

private struct LegacyIndicator: NSViewRepresentable {
    var value: Double?
    var total: Double

    func makeNSView(context: Context) -> NSProgressIndicator {
        let v = NSProgressIndicator()
        v.style = .bar
        v.controlSize = .small
        v.isIndeterminate = (value == nil)
        v.minValue = 0
        v.maxValue = total
        if value == nil { v.startAnimation(nil) }
        return v
    }

    func updateNSView(_ v: NSProgressIndicator, context: Context) {
        v.maxValue = total
        let indeterminate = (value == nil)
        if v.isIndeterminate != indeterminate {
            v.isIndeterminate = indeterminate
            if indeterminate { v.startAnimation(nil) } else { v.stopAnimation(nil) }
        }
        if let value { v.doubleValue = value }
    }
}
