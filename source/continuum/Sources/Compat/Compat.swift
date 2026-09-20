//  Compat.swift — back-deployment shims for Continuum.
//
//  Continuum ships in four flavours (macOS 13 / 12 / 11 / 10.15) built from
//  ONE source tree. Nothing here is conditionally compiled: every shim uses a
//  runtime `#available` check, so a single source file compiles at every
//  deployment target *and* still lights up the newest API when the binary
//  happens to run on a newer OS. A 10.15-targeted build running on macOS 13
//  therefore gets the real NavigationSplitView, the real LabeledContent, and
//  so on — which is exactly the "old builds must also work on new machines"
//  requirement, satisfied at full fidelity rather than by degrading.
//
//  These files are compiled INTO every kit module (see build.sh), so each kit
//  gets its own internal copy; no cross-module imports are needed and nothing
//  here widens a kit's public surface.

import SwiftUI
import AppKit
import Combine

// MARK: - Colour

extension Color {
    /// Both `Color(nsColor:)` and `Color(cgColor:)` are macOS 12+. Below that,
    /// decompose the colour in sRGB and rebuild it component-wise.
    static func compat(_ ns: NSColor) -> Color {
        if #available(macOS 12.0, *) { return Color(nsColor: ns) }
        let c = ns.usingColorSpace(.sRGB) ?? .labelColor
        return Color(.sRGB,
                     red: Double(c.redComponent),
                     green: Double(c.greenComponent),
                     blue: Double(c.blueComponent),
                     opacity: Double(c.alphaComponent))
    }

    /// `.tertiary`/`.quaternary` are macOS 12 hierarchical shape styles with no
    /// pre-12 equivalent; approximate them by fading the secondary label colour.
    static var compatTertiary: Color { Color.secondary.opacity(0.62) }
    static var compatQuaternary: Color { Color.secondary.opacity(0.38) }
    /// `Color.teal` is macOS 12+.
    static var compatTeal: Color {
        if #available(macOS 12.0, *) { return .teal }
        return Color(.sRGB, red: 0.19, green: 0.69, blue: 0.71, opacity: 1)
    }
}

// MARK: - Typography

extension Font {
    /// `.caption2`, `.title2` and `.title3` all arrived in macOS 11.
    static var compatCaption2: Font {
        if #available(macOS 11.0, *) { return .caption2 }
        return .system(size: 10)
    }
    static var compatTitle2: Font {
        if #available(macOS 11.0, *) { return .title2 }
        return .system(size: 17, weight: .semibold)
    }
    static var compatTitle3: Font {
        if #available(macOS 11.0, *) { return .title3 }
        return .system(size: 15, weight: .semibold)
    }
}

extension View {
    /// `.monospacedDigit()` is macOS 12; the design-based font is universal.
    @ViewBuilder func compatMonospacedDigit() -> some View {
        if #available(macOS 12.0, *) { self.monospacedDigit() }
        else { self.font(.system(.body, design: .monospaced)) }
    }

    /// `.monospaced()` on View is macOS 13.3.
    @ViewBuilder func compatMonospaced() -> some View {
        if #available(macOS 13.3, *) { self.monospaced() }
        else { self.font(.system(.body, design: .monospaced)) }
    }

    /// `.textSelection()` is macOS 12; below it text simply isn't selectable.
    @ViewBuilder func compatTextSelection() -> some View {
        if #available(macOS 12.0, *) { self.textSelection(.enabled) } else { self }
    }

    /// `.badge()` is macOS 12. The fallback appends a trailing count capsule.
    @ViewBuilder func compatBadge(_ count: Int) -> some View {
        if #available(macOS 12.0, *) { self.badge(count) }
        else {
            HStack(spacing: 6) {
                self
                if count > 0 {
                    Text("\(count)")
                        .font(.compatCaption2).foregroundColor(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.compatQuaternary))
                }
            }
        }
    }

    /// `.tint()` is macOS 12 on most controls; accentColor is the pre-12 spelling.
    @ViewBuilder func compatTint(_ color: Color) -> some View {
        if #available(macOS 12.0, *) { self.tint(color) } else { self.accentColor(color) }
    }

    /// `.help()` is macOS 11.
    @ViewBuilder func compatHelp(_ text: String) -> some View {
        if #available(macOS 11.0, *) { self.help(text) } else { self }
    }
}

// MARK: - Buttons

extension View {
    /// `.buttonStyle(.bordered)` (the static member) is macOS 12, but the
    /// concrete `BorderedButtonStyle` type goes back to 10.15.
    @ViewBuilder func compatBordered() -> some View {
        if #available(macOS 12.0, *) { self.buttonStyle(.bordered) }
        else { self.buttonStyle(BorderedButtonStyle()) }
    }

    /// `.borderedProminent` is macOS 12 with no pre-12 equivalent; the default
    /// (blue, key-equivalent) button style is the closest match.
    @ViewBuilder func compatBorderedProminent() -> some View {
        if #available(macOS 12.0, *) { self.buttonStyle(.borderedProminent) }
        else { self.buttonStyle(DefaultButtonStyle()) }
    }

    /// `.controlSize()` is macOS 10.15 for most controls but the `.large` case
    /// is macOS 11; callers pass a compat case instead.
    @ViewBuilder func compatControlSize(_ size: CompatControlSize) -> some View {
        switch size {
        case .small:  self.controlSize(.small)
        case .regular: self.controlSize(.regular)
        case .large:
            if #available(macOS 11.0, *) { self.controlSize(.large) }
            else { self.controlSize(.regular) }
        }
    }
}

enum CompatControlSize { case small, regular, large }

// MARK: - Formatting

extension BinaryInteger {
    /// `.formatted()` is macOS 12 (Foundation's FormatStyle).
    func compatFormatted() -> String {
        if #available(macOS 12.0, *) { return (self as? Int ?? Int(self)).formatted() }
        return CompatFormatters.decimal.string(from: NSNumber(value: Int(self)))
            ?? String(Int(self))
    }
}

extension Double {
    func compatFormatted(fractionDigits: Int = 1) -> String {
        let f = CompatFormatters.decimal
        f.minimumFractionDigits = fractionDigits
        f.maximumFractionDigits = fractionDigits
        defer { f.minimumFractionDigits = 0; f.maximumFractionDigits = 0 }
        return f.string(from: NSNumber(value: self)) ?? String(self)
    }
}

extension Date {
    /// `.formatted()` and `.formatted(date:time:)` are macOS 12.
    func compatFormatted() -> String {
        if #available(macOS 12.0, *) { return self.formatted() }
        return CompatFormatters.dateTime.string(from: self)
    }
}

enum CompatFormatters {
    static let decimal: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; return f
    }()
    static let dateTime: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
}

// MARK: - Badge overloads

extension View {
    /// `.badge(String?)` — the sidebar's "!" warning marker.
    @ViewBuilder func compatBadge(_ text: String?) -> some View {
        if #available(macOS 12.0, *) { self.badge(text.map { Text($0) }) }
        else {
            HStack(spacing: 6) {
                self
                if let text {
                    Text(text)
                        .font(.compatCaption2).foregroundColor(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.compatQuaternary))
                }
            }
        }
    }
}

// MARK: - Font-level shims

extension Font {
    /// `Font.monospaced()` / `.monospacedDigit()` on a *Font* (as opposed to a
    /// View) are macOS 12; the design-based system font is the pre-12 spelling.
    func compatMonospaced() -> Font {
        if #available(macOS 12.0, *) { return self.monospaced() }
        return .system(.body, design: .monospaced)
    }
    func compatMonospacedDigit() -> Font {
        if #available(macOS 12.0, *) { return self.monospacedDigit() }
        return .system(.body, design: .monospaced)
    }
}

// MARK: - Gradient foregrounds

extension View {
    /// Filling a symbol with a gradient needs `.foregroundStyle` (macOS 12).
    /// Pre-12 there is no gradient fill for text/symbols, so a representative
    /// flat colour stands in.
    @ViewBuilder
    func compatGradientForeground<S: ShapeStyle>(_ style: S, fallback: Color) -> some View {
        if #available(macOS 12.0, *) { self.foregroundStyle(style) }
        else { self.foregroundColor(fallback) }
    }
}

// MARK: - Date formatting overloads

extension Date {
    /// `.formatted(date:time:)` is macOS 12.
    func compatFormatted(dateStyle: DateFormatter.Style,
                         timeStyle: DateFormatter.Style) -> String {
        let f = DateFormatter()
        f.dateStyle = dateStyle
        f.timeStyle = timeStyle
        return f.string(from: self)
    }
}

// MARK: - Line-by-line pipe reading

extension FileHandle {
    /// `FileHandle.bytes.lines` is macOS 12. This is the same thing built on
    /// `readabilityHandler`, which works back to 10.15: bytes are buffered and
    /// split on newlines, and the stream finishes at EOF.
    func compatLines() -> AsyncStream<String> {
        AsyncStream { continuation in
            var buffer = Data()
            readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    // EOF — flush any trailing partial line, then close.
                    if !buffer.isEmpty,
                       let tail = String(data: buffer, encoding: .utf8), !tail.isEmpty {
                        continuation.yield(tail)
                    }
                    handle.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if let line = String(data: lineData, encoding: .utf8) {
                        continuation.yield(line)
                    }
                }
            }
            continuation.onTermination = { @Sendable _ in
                self.readabilityHandler = nil
            }
        }
    }
}

// MARK: - Colours added in macOS 12

extension Color {
    static var compatCyan: Color {
        if #available(macOS 12.0, *) { return .cyan }
        return Color(.sRGB, red: 0.20, green: 0.68, blue: 0.90, opacity: 1)
    }
    static var compatIndigo: Color {
        if #available(macOS 12.0, *) { return .indigo }
        return Color(.sRGB, red: 0.35, green: 0.34, blue: 0.84, opacity: 1)
    }
    static var compatMint: Color {
        if #available(macOS 12.0, *) { return .mint }
        return Color(.sRGB, red: 0.24, green: 0.78, blue: 0.66, opacity: 1)
    }
}

// MARK: - FileHandle (macOS 10.15.4)

extension FileHandle {
    /// `readToEnd()` is macOS 10.15.4; the throwing-free spelling is universal.
    func compatReadToEnd() -> Data? {
        if #available(macOS 10.15.4, *) { return try? readToEnd() }
        return readDataToEndOfFile()
    }

    /// `write(contentsOf:)` is macOS 10.15.4.
    func compatWrite(_ data: Data) {
        if #available(macOS 10.15.4, *) { try? write(contentsOf: data) }
        else { write(data) }
    }
}

extension FileHandle {
    /// `read(upToCount:)` is macOS 10.15.4.
    func compatRead(upToCount count: Int) -> Data? {
        if #available(macOS 10.15.4, *) { return (try? read(upToCount: count)) ?? nil }
        let data = readData(ofLength: count)
        return data.isEmpty ? nil : data
    }
}

// MARK: - UserDefaults-backed string (macOS 11's @AppStorage)

/// `@AppStorage` is macOS 11. This is the same idea as an ObservableObject:
/// a published value mirrored into UserDefaults, so a `Picker` bound to it
/// writes through to the same key `@AppStorage` uses on newer systems.
final class CompatDefaultsString: ObservableObject {
    private let key: String

    @Published var value: String {
        didSet {
            guard value != oldValue else { return }
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    init(key: String, default defaultValue: String = "") {
        self.key = key
        self.value = UserDefaults.standard.string(forKey: key) ?? defaultValue
    }
}
