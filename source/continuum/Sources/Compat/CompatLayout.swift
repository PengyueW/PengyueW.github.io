//  CompatLayout.swift — structural view shims (macOS 13 → 10.15).

import SwiftUI
import AppKit
import Combine

// MARK: - LabeledContent (macOS 13)

/// `LabeledContent` is macOS 13. The pre-13 spelling is a label/spacer/value
/// row, which is exactly what LabeledContent renders inside a Form.
struct CompatLabeledContent<Content: View>: View {
    private let title: Text
    private let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = Text(title); self.content = content()
    }
    init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {
        self.title = Text(title); self.content = content()
    }

    var body: some View {
        if #available(macOS 13.0, *) {
            LabeledContent { content } label: { title }
        } else {
            HStack(alignment: .firstTextBaseline) {
                title
                Spacer(minLength: 12)
                content.multilineTextAlignment(.trailing)
            }
        }
    }
}

// MARK: - Grid / GridRow (macOS 13)

private struct CompatGridSpacing: EnvironmentKey {
    static let defaultValue: CGFloat = 8
}
extension EnvironmentValues {
    var compatGridSpacing: CGFloat {
        get { self[CompatGridSpacing.self] }
        set { self[CompatGridSpacing.self] = newValue }
    }
}

/// `Grid`/`GridRow` are macOS 13. Every grid in this app is a plain uniform
/// row-major layout, so nested VStack/HStack reproduce it exactly; the
/// horizontal spacing rides down to the rows through the environment.
struct CompatGrid<Content: View>: View {
    var alignment: HorizontalAlignment = .center
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8
    @ViewBuilder var content: Content

    init(alignment: HorizontalAlignment = .center,
         horizontalSpacing: CGFloat = 8, verticalSpacing: CGFloat = 8,
         @ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        self.content = content()
    }

    var body: some View {
        if #available(macOS 13.0, *) {
            Grid(alignment: Alignment(horizontal: alignment, vertical: .center),
                 horizontalSpacing: horizontalSpacing,
                 verticalSpacing: verticalSpacing) { content }
        } else {
            VStack(alignment: alignment, spacing: verticalSpacing) { content }
                .environment(\.compatGridSpacing, horizontalSpacing)
        }
    }
}

struct CompatGridRow<Content: View>: View {
    @Environment(\.compatGridSpacing) private var spacing
    @ViewBuilder var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        if #available(macOS 13.0, *) { GridRow { content } }
        else { HStack(spacing: spacing) { content } }
    }
}

// MARK: - Form style / materials

extension View {
    /// `.formStyle(.grouped)` is macOS 13. Pre-13 the fallback is the identity,
    /// which is fine for a Form given a fixed width (all the Settings panes) —
    /// see `CompatFormPage` for the case where it is emphatically not fine.
    @ViewBuilder func compatGroupedForm() -> some View {
        if #available(macOS 13.0, *) { self.formStyle(.grouped) } else { self }
    }

    /// `.background(.regularMaterial, in:)` is macOS 12; pre-12 falls back to
    /// a translucent NSVisualEffectView-backed fill.
    @ViewBuilder func compatMaterialBackground(cornerRadius: CGFloat) -> some View {
        if #available(macOS 12.0, *) {
            self.background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: cornerRadius,
                                                 style: .continuous))
        } else {
            self.background(
                CompatVisualEffect()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius,
                                                style: .continuous)))
        }
    }
}

/// A whole detail page built out of `Section`s — the Free Space Wipe and
/// Sensors ▸ Automations pages.
///
/// `Form` + `.formStyle(.grouped)` is the macOS 13 answer, and below 13 the
/// style modifier is simply dropped. For a Form pinned to a fixed width (the
/// Settings panes) that degrades acceptably. For a page that fills the detail
/// pane it does not degrade, it collapses: a plain macOS `Form` has no scroll
/// container and no width resolution of its own, so it lays its content out in
/// a narrow column, wraps every paragraph to a few characters, and grows
/// without bound. Measured on the Free Space page, the identity fallback
/// produced a **21,262-point-tall** view inside a 560-point pane — the "fully
/// broken layout" on the macOS 11 and 12 builds.
///
/// `List` is the container that behaves: it scrolls, it takes the width it is
/// given, and it renders `Section` headers natively all the way back to 10.15.
/// So the page is a grouped Form on 13+ and a List below it. `Section` is
/// equally at home in either, which is why the call sites are unchanged apart
/// from the container.
struct CompatFormPage<Content: View>: View {
    @ViewBuilder var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        if #available(macOS 13.0, *) {
            Form { content }.formStyle(.grouped)
        } else {
            List { content }
        }
    }
}

/// Pre-12 stand-in for SwiftUI `Material`.
struct CompatVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .contentBackground
        v.blendingMode = .withinWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - Navigation (macOS 13)

/// `NavigationSplitView` is macOS 13; `NavigationView` with a sidebar list is
/// the pre-13 two-column equivalent and behaves identically for this app's
/// single sidebar + single detail arrangement.
struct CompatNavigationSplit<Sidebar: View, Detail: View>: View {
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var detail: Detail

    init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
        self.sidebar = sidebar(); self.detail = detail()
    }

    var body: some View {
        if #available(macOS 13.0, *) {
            NavigationSplitView { sidebar } detail: { detail }
        } else {
            NavigationView { sidebar; detail }
        }
    }
}

extension View {
    /// `.navigationSplitViewColumnWidth(min:ideal:)` is macOS 13; a frame is
    /// the pre-13 way to size a NavigationView sidebar column.
    @ViewBuilder func compatColumnWidth(min: CGFloat, ideal: CGFloat) -> some View {
        if #available(macOS 13.0, *) {
            self.navigationSplitViewColumnWidth(min: min, ideal: ideal)
        } else {
            self.frame(minWidth: min, idealWidth: ideal)
        }
    }
}

// MARK: - Alerts (macOS 12)

/// The `alert(_:isPresented:actions:message:)` / `confirmationDialog` family is
/// macOS 12. Pre-12 uses the `Alert` value type, which supports exactly the
/// one- and two-button shapes this app uses.
/// Both shims take and return `Text`, so literal titles and messages keep
/// resolving through the bundled .lproj tables in either branch.
extension View {
    /// Title + message + one destructive-or-default confirm + a cancel. Covers
    /// every `confirmationDialog` in the suite.
    @ViewBuilder
    func compatConfirm(_ title: Text,
                       isPresented: Binding<Bool>,
                       confirmTitle: Text,
                       isDestructive: Bool = true,
                       confirm: @escaping () -> Void,
                       cancelTitle: Text = Text("Cancel"),
                       cancel: @escaping () -> Void = {},
                       @ViewBuilder message: () -> Text) -> some View {
        let messageText = message()
        if #available(macOS 12.0, *) {
            self.confirmationDialog(title, isPresented: isPresented,
                                    titleVisibility: .visible) {
                Button(role: isDestructive ? .destructive : nil, action: confirm) {
                    confirmTitle
                }
                Button(role: .cancel, action: cancel) { cancelTitle }
            } message: {
                messageText
            }
        } else {
            self.alert(isPresented: isPresented) {
                Alert(title: title,
                      message: messageText,
                      primaryButton: isDestructive
                        ? .destructive(confirmTitle, action: confirm)
                        : .default(confirmTitle, action: confirm),
                      secondaryButton: .cancel(cancelTitle, action: cancel))
            }
        }
    }

    /// Title + message + a single dismiss button. Covers every error `alert`.
    @ViewBuilder
    func compatNotice(_ title: Text,
                      isPresented: Binding<Bool>,
                      dismissTitle: Text = Text("OK"),
                      dismiss: @escaping () -> Void = {},
                      @ViewBuilder message: () -> Text) -> some View {
        let messageText = message()
        if #available(macOS 12.0, *) {
            self.alert(title, isPresented: isPresented) {
                Button(role: .cancel, action: dismiss) { dismissTitle }
            } message: {
                messageText
            }
        } else {
            self.alert(isPresented: isPresented) {
                Alert(title: title, message: messageText,
                      dismissButton: .default(dismissTitle, action: dismiss))
            }
        }
    }
}

// MARK: - Sections, backgrounds, buttons

/// `Section(_:content:)` taking a title string is macOS 12; pre-12 the title
/// goes through the `header:` parameter.
struct CompatSection<Content: View>: View {
    private let title: Text
    private let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = Text(title); self.content = content()
    }
    init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {
        self.title = Text(title); self.content = content()
    }

    var body: some View {
        if #available(macOS 12.0, *) { Section { content } header: { title } }
        else { Section(header: title) { content } }
    }
}

extension View {
    /// `.background(.quaternary.opacity(x), in: RoundedRectangle(...))` — both
    /// the hierarchical style and the `in:` shape overload are macOS 12.
    @ViewBuilder
    func compatFillBackground(cornerRadius: CGFloat, opacity: Double = 1) -> some View {
        self.background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.compatQuaternary.opacity(opacity)))
    }

    /// `.background(.bar)` — the toolbar/status-bar material, macOS 12.
    @ViewBuilder func compatBarBackground() -> some View {
        if #available(macOS 12.0, *) { self.background(.bar) }
        else { self.background(CompatVisualEffect()) }
    }
}

/// `Button(role:)` is macOS 12. Pre-12 there are no button roles, so the
/// button renders normally — the role only ever affected presentation.
struct CompatRoleButton<Label: View>: View {
    enum Role { case destructive, cancel }
    let role: Role
    let action: () -> Void
    @ViewBuilder var label: Label

    init(role: Role, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.role = role; self.action = action; self.label = label()
    }

    var body: some View {
        if #available(macOS 12.0, *) {
            Button(role: role == .destructive ? .destructive : .cancel,
                   action: action) { label }
        } else {
            Button(action: action) { label }
        }
    }
}


/// A small line plot. `Canvas` is macOS 12, so the sparklines are drawn as a
/// plain SwiftUI `Path` inside a `GeometryReader`, which works back to 10.15.
struct CompatSparkline: View {
    let values: [Double]
    /// Maps a value to a y coordinate within the given height.
    let yFor: (Double, CGFloat) -> CGFloat
    let color: Color
    /// Draws a horizontal rule at this y fraction (0…1) when non-nil.
    var zeroLineFraction: CGFloat?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let zeroLineFraction {
                    Path { p in
                        let y = geo.size.height * zeroLineFraction
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                }
                if values.count > 1 {
                    Path { p in
                        let step = geo.size.width / CGFloat(values.count - 1)
                        for (i, v) in values.enumerated() {
                            let point = CGPoint(x: CGFloat(i) * step,
                                                y: yFor(v, geo.size.height))
                            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                        }
                    }
                    .stroke(color, lineWidth: 1.5)
                }
            }
        }
    }
}

// MARK: - Odds and ends

extension View {
    /// `.lineLimit(_:reservesSpace:)` is macOS 13; pre-13 loses only the
    /// space reservation, not the clamp.
    @ViewBuilder func compatLineLimit(_ limit: Int, reservesSpace: Bool) -> some View {
        if #available(macOS 13.0, *) { self.lineLimit(limit, reservesSpace: reservesSpace) }
        else { self.lineLimit(limit) }
    }

    /// `.help()` is macOS 11; localised overload.
    @ViewBuilder func compatHelp(_ key: LocalizedStringKey) -> some View {
        if #available(macOS 11.0, *) { self.help(key) } else { self }
    }
}

extension CompatSymbol {
    /// `Text(Image(systemName:))` — an SF Symbol inlined into a Text run.
    static func text(_ name: String) -> Text {
        if #available(macOS 11.0, *), let resolved = resolvedName(name) {
            return Text(Image(systemName: resolved))
        }
        return Text(glyph(name))
    }
}

/// A `List` with a non-optional selection binding. The macOS 13 initializer
/// accepts that directly; pre-13 the selection binding must be optional, so it
/// is bridged here (nil selections are ignored, which matches the rail's
/// always-one-selected behaviour).
struct CompatSelectionList<Selection: Hashable, Content: View>: View {
    @Binding var selection: Selection
    @ViewBuilder var content: Content

    init(selection: Binding<Selection>, @ViewBuilder content: () -> Content) {
        self._selection = selection; self.content = content()
    }

    var body: some View {
        if #available(macOS 13.0, *) {
            List(selection: $selection) { content }
        } else {
            List(selection: Binding<Selection?>(
                get: { selection },
                set: { if let new = $0 { selection = new } })) { content }
        }
    }
}

/// `Gauge` and the `.accessoryCircularCapacity` style are macOS 13. Pre-13 gets
/// an equivalent hand-drawn capacity ring with the same centre label.
struct CompatCircularGauge<Label: View>: View {
    let value: Double
    let range: ClosedRange<Double>
    let tint: Color
    @ViewBuilder var centerLabel: Label

    init(value: Double, in range: ClosedRange<Double>, tint: Color,
         @ViewBuilder centerLabel: () -> Label) {
        self.value = value; self.range = range; self.tint = tint
        self.centerLabel = centerLabel()
    }

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    var body: some View {
        if #available(macOS 13.0, *) {
            Gauge(value: value, in: range) { EmptyView() }
                currentValueLabel: { centerLabel }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(tint)
        } else {
            ZStack {
                Circle().stroke(Color.compatQuaternary, lineWidth: 7)
                Circle()
                    .trim(from: 0, to: CGFloat(fraction))
                    .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                centerLabel.font(.system(size: 15, weight: .semibold))
            }
            .frame(width: 54, height: 54)
        }
    }
}

// MARK: - Bar chart

/// A horizontal bar chart drawn in plain SwiftUI.
///
/// The Swift Charts framework is macOS 13 only — and worse, *linking* it at all
/// would make the binary fail to load on an older system, since
/// Charts.framework doesn't exist there. So the suite's one chart is drawn
/// directly instead: same horizontal bars, same hidden legend, same x-axis
/// gridlines with byte-formatted labels.
struct CompatBarChart: View {
    struct Bar: Identifiable {
        let id: String
        let label: String
        let value: Double
        let color: Color
    }

    let bars: [Bar]
    /// Formats an x-axis tick (bytes → "1.2 GB").
    let axisLabel: (Double) -> String

    private var maxValue: Double { max(bars.map(\.value).max() ?? 1, 1) }

    /// Four evenly spaced ticks, matching the default AxisMarks density.
    private var ticks: [Double] { (0...4).map { maxValue * Double($0) / 4 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(bars) { bar in
                HStack(spacing: 10) {
                    Text(bar.label)
                        .font(.caption)
                        .frame(width: 118, alignment: .trailing)
                        .lineLimit(1)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            // Gridlines behind the bar — the AxisGridLine equivalent.
                            ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                                Rectangle()
                                    .fill(Color.compatQuaternary)
                                    .frame(width: 1)
                                    .offset(x: geo.size.width * CGFloat(tick / maxValue))
                            }
                            RoundedRectangle(cornerRadius: 4)
                                .fill(bar.color)
                                .frame(width: max(2, geo.size.width
                                                     * CGFloat(bar.value / maxValue)))
                        }
                    }
                    .frame(height: 22)
                    Text(axisLabel(bar.value))
                        .font(.compatCaption2)
                        .foregroundColor(.secondary)
                        .frame(width: 74, alignment: .leading)
                }
            }

            // X-axis tick labels.
            HStack(spacing: 0) {
                Spacer().frame(width: 128)
                ForEach(Array(ticks.enumerated()), id: \.offset) { index, tick in
                    Text(axisLabel(tick))
                        .font(.compatCaption2)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity,
                               alignment: index == 0 ? .leading : .center)
                }
                Spacer().frame(width: 74)
            }
        }
    }
}

// MARK: - Backgrounds with an explicit colour

extension View {
    /// `.background(SomeColor, in: Shape)` — the `in:` shape overload is
    /// macOS 12; filling the shape directly is equivalent and universal.
    @ViewBuilder
    func compatColorBackground(_ color: Color, cornerRadius: CGFloat) -> some View {
        self.background(RoundedRectangle(cornerRadius: cornerRadius).fill(color))
    }
}

extension Date {
    /// `.formatted(.relative(presentation:))` is macOS 12;
    /// RelativeDateTimeFormatter is the universal equivalent.
    func compatRelativeFormatted() -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: self, relativeTo: Date())
    }
}

/// `GroupBox(_:content:)` taking a title string is macOS 12; pre-12 the title
/// goes through the `label:` parameter.
struct CompatGroupBox<Content: View>: View {
    private let title: Text
    private let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = Text(title); self.content = content()
    }
    init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {
        self.title = Text(title); self.content = content()
    }

    var body: some View {
        GroupBox(label: title) { content }
    }
}

extension CompatRoleButton where Label == Text {
    /// `Button(_:role:action:)` — the title-string form.
    init(_ title: LocalizedStringKey, role: Role, action: @escaping () -> Void) {
        self.init(role: role, action: action) { Text(title) }
    }
}

extension View {
    /// `.interactiveDismissDisabled()` is macOS 12; pre-12 sheets are already
    /// non-interactively-dismissable on macOS, so the fallback is the identity.
    @ViewBuilder func compatInteractiveDismissDisabled() -> some View {
        if #available(macOS 12.0, *) { self.interactiveDismissDisabled() } else { self }
    }
}

/// The lid-angle dial. `Canvas` is macOS 12, so this draws with `Path` instead.
struct CompatLidDial: View {
    let degrees: Double

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height - 6)
            let radius = min(geo.size.width, geo.size.height) - 12
            ZStack {
                // Base (keyboard).
                Path { p in
                    p.move(to: center)
                    p.addLine(to: CGPoint(x: center.x + radius, y: center.y))
                }
                .stroke(Color.secondary, lineWidth: 3)
                // Lid at the measured angle (0° closed, 180° flat back).
                Path { p in
                    let radians = -degrees * .pi / 180
                    p.move(to: center)
                    p.addLine(to: CGPoint(x: center.x + radius * cos(radians),
                                          y: center.y + radius * sin(radians)))
                }
                .stroke(Color.accentColor, lineWidth: 3)
            }
        }
    }
}

// MARK: - List styles (macOS 11)

extension View {
    /// `.inset` and `.sidebar` list styles are macOS 11. Pre-11 the plain and
    /// sidebar-ish styles that do exist are the closest equivalents.
    @ViewBuilder func compatInsetList() -> some View {
        if #available(macOS 11.0, *) { self.listStyle(.inset) }
        else { self.listStyle(PlainListStyle()) }
    }

    @ViewBuilder func compatSidebarList() -> some View {
        if #available(macOS 11.0, *) { self.listStyle(.sidebar) }
        else { self.listStyle(SidebarListStyle()) }
    }

    /// `.ignoresSafeArea()` is macOS 11; `.edgesIgnoringSafeArea` is the
    /// pre-11 spelling.
    @ViewBuilder func compatIgnoresSafeArea() -> some View {
        if #available(macOS 11.0, *) { self.ignoresSafeArea() }
        else { self.edgesIgnoringSafeArea(.all) }
    }

    /// `.keyboardShortcut()` is macOS 11 — purely an accelerator, so pre-11
    /// simply loses the shortcut and keeps the button.
    @ViewBuilder func compatKeyboardShortcut(_ key: Character) -> some View {
        if #available(macOS 11.0, *) { self.keyboardShortcut(KeyEquivalent(key)) }
        else { self }
    }

    /// `.toolbar { }` is macOS 11, but only usable below 13 in the narrow
    /// sense — see `CompatToolbarContainer`. Below that the same controls are
    /// laid out as a trailing-aligned bar pinned above the content.
    @ViewBuilder
    func compatToolbar<T: View>(@ViewBuilder _ content: () -> T) -> some View {
        CompatToolbarContainer(bar: content(), content: self)
    }
}

/// Places toolbar controls above the content below macOS 13, and hands them to
/// the real window toolbar on 13+.
///
/// The cut-off is 13 rather than 11 because of how `CompatNavigationSplit`
/// degrades: 13+ gets a real `NavigationSplitView`, which merges a `.toolbar`
/// declared on the shell with one declared inside the detail column. On 11/12
/// it falls back to `NavigationView`, where a window hosts exactly **one**
/// toolbar — the shell's (the Donate button) — and every `.toolbar` applied
/// further down the detail column is silently dropped. That is why the scan
/// engine's "New Scan" button was reachable on 13 and unreachable on 11,
/// leaving the user stranded on the results page with no way back to the tier
/// picker. Conditional items are the worst case: the toolbar is reconciled
/// once, so anything that only appears after a state change never lands.
///
/// Rendering the bar inline sidesteps the whole question — it is ordinary view
/// content, so it appears and updates wherever it is declared, however deeply
/// nested and however conditional.
struct CompatToolbarContainer<Bar: View, Content: View>: View {
    let bar: Bar
    let content: Content

    /// Height of the laid-out bar. Callers routinely emit *nothing* for a
    /// given state (the scan engine shows no items while idle), and an empty
    /// row would still claim its padding and draw a stray divider — so the
    /// whole strip is dropped until something in it has size.
    @State private var barHeight: CGFloat = 0

    var body: some View {
        if #available(macOS 13.0, *) {
            content.toolbar { ToolbarItemGroup(placement: .automatic) { bar } }
        } else {
            VStack(spacing: 0) {
                // Measured *before* the padding is applied, so the padding can
                // depend on the result without the measurement feeding back
                // into itself. An item-less bar is a bare `Spacer`, which is
                // zero-height in a horizontal stack.
                HStack(spacing: 8) { Spacer(); bar }
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: CompatToolbarHeightKey.self,
                                               value: proxy.size.height)
                    })
                    .padding(.horizontal, barHeight > 0 ? 12 : 0)
                    .padding(.vertical, barHeight > 0 ? 7 : 0)
                if barHeight > 0 { Divider() }
                content
            }
            .onPreferenceChange(CompatToolbarHeightKey.self) { barHeight = $0 }
            // These containers nest (the shell wraps a division that wraps a
            // page), and preferences travel upward — so clear the value after
            // consuming it, or an outer bar would size itself from an inner
            // one's items.
            .preference(key: CompatToolbarHeightKey.self, value: 0)
        }
    }
}

private struct CompatToolbarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// `Menu` is macOS 11. Pre-11 renders the same choices as a `Picker`-backed
/// pull-down, which AppKit draws as an NSPopUpButton.
struct CompatMenu<Label: View, Content: View>: View {
    @ViewBuilder var label: Label
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content(); self.label = label()
    }

    var body: some View {
        if #available(macOS 11.0, *) {
            Menu { content } label: { label }
        } else {
            // Pre-11 has no Menu; a disclosure-free popover of the same items.
            VStack(alignment: .leading, spacing: 4) { content }
        }
    }
}


/// `TextEditor` is macOS 11; an NSTextView bridge covers 10.15.
struct CompatTextEditor: View {
    @Binding var text: String

    var body: some View {
        if #available(macOS 11.0, *) { TextEditor(text: $text) }
        else { LegacyTextEditor(text: $text) }
    }
}

private struct LegacyTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let tv = scroll.documentView as? NSTextView {
            tv.delegate = context.coordinator
            tv.isRichText = false
            tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            tv.string = text
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        tv.string = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: LegacyTextEditor
        init(_ parent: LegacyTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}

// MARK: - File import / drop (macOS 11)

extension View {
    /// `.fileImporter` and `UTType` are macOS 11. Pre-11 the same job is done
    /// by an `NSOpenPanel`, which is what fileImporter wraps anyway.
    @ViewBuilder
    func compatFileImporter(isPresented: Binding<Bool>,
                            allowsMultipleSelection: Bool = false,
                            onCompletion: @escaping ([URL]) -> Void) -> some View {
        // NSOpenPanel on every version: `fileImporter` needs `UTType`, and
        // importing UniformTypeIdentifiers would hard-link a framework that
        // does not exist on 10.15. This is what fileImporter wraps anyway.
        self.onReceive(Just(isPresented.wrappedValue)) { presented in
            guard presented else { return }
            isPresented.wrappedValue = false
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = allowsMultipleSelection
            panel.canChooseDirectories = true
            panel.canChooseFiles = true
            if panel.runModal() == .OK { onCompletion(panel.urls) }
        }
    }

    /// `.onDrop(of: [UTType…])` is macOS 11; the pre-11 overload takes UTI
    /// strings, and `kUTTypeFileURL` is the file-URL identifier.
    @ViewBuilder
    func compatFileDrop(isTargeted: Binding<Bool>,
                        perform: @escaping ([NSItemProvider]) -> Bool) -> some View {
        // The string-UTI overload works on every supported release.
        self.onDrop(of: ["public.file-url"], isTargeted: isTargeted, perform: perform)
    }

    /// `.keyboardShortcut(.defaultAction/.cancelAction)` is macOS 11.
    @ViewBuilder func compatDefaultAction() -> some View {
        if #available(macOS 11.0, *) { self.keyboardShortcut(.defaultAction) } else { self }
    }
    @ViewBuilder func compatCancelAction() -> some View {
        if #available(macOS 11.0, *) { self.keyboardShortcut(.cancelAction) } else { self }
    }
}

/// `ScrollViewReader` is macOS 11. Pre-11 the content is shown without
/// programmatic auto-scroll — everything stays readable, it just doesn't
/// follow the tail on its own.
struct CompatAutoScroll<Value: Equatable, Content: View>: View {
    /// Changes to this value trigger a scroll to `targetID`.
    let trigger: Value
    let targetID: AnyHashable?
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 11.0, *) {
            ScrollViewReader { proxy in
                content.onChange(of: trigger) { _ in
                    if let targetID {
                        withAnimation { proxy.scrollTo(targetID, anchor: .bottom) }
                    }
                }
            }
        } else {
            content
        }
    }
}

/// `Label { } icon: { }` (the view-builder form) is macOS 11.
struct CompatLabelView<Title: View, Icon: View>: View {
    @ViewBuilder var title: Title
    @ViewBuilder var icon: Icon

    init(@ViewBuilder title: () -> Title, @ViewBuilder icon: () -> Icon) {
        self.title = title(); self.icon = icon()
    }

    var body: some View {
        if #available(macOS 11.0, *) {
            Label { title } icon: { icon }
        } else {
            HStack(spacing: 6) { icon; title }
        }
    }
}

extension View {
    /// `.pickerStyle(.menu)` and `.inline` are macOS 11.
    @ViewBuilder func compatMenuPicker() -> some View {
        if #available(macOS 11.0, *) { self.pickerStyle(MenuPickerStyle()) }
        else { self.pickerStyle(PopUpButtonPickerStyle()) }
    }

    @ViewBuilder func compatInlinePicker() -> some View {
        if #available(macOS 11.0, *) { self.pickerStyle(InlinePickerStyle()) }
        else { self.pickerStyle(RadioGroupPickerStyle()) }
    }
}

/// An adaptive-width grid. `LazyVGrid`/`GridItem` are macOS 11, so pre-11 the
/// same content is chunked into fixed rows sized from the available width.
struct CompatAdaptiveGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    let minimum: CGFloat
    let spacing: CGFloat
    @ViewBuilder let cell: (Item) -> Cell

    var body: some View {
        if #available(macOS 11.0, *) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: spacing)],
                      spacing: spacing) {
                ForEach(items) { cell($0) }
            }
        } else {
            GeometryReader { geo in
                let columns = max(1, Int(geo.size.width / (minimum + spacing)))
                let rows = stride(from: 0, to: items.count, by: columns).map {
                    Array(items[$0..<min($0 + columns, items.count)])
                }
                VStack(spacing: spacing) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: spacing) {
                            ForEach(row) { cell($0) }
                            if row.count < columns {
                                ForEach(0..<(columns - row.count), id: \.self) { _ in
                                    Spacer().frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

extension View {
    /// `.navigationTitle` is macOS 11.
    @ViewBuilder func compatNavigationTitle(_ title: String) -> some View {
        if #available(macOS 11.0, *) { self.navigationTitle(title) } else { self }
    }
    @ViewBuilder func compatNavigationTitle(_ title: LocalizedStringKey) -> some View {
        if #available(macOS 11.0, *) { self.navigationTitle(title) } else { self }
    }
}

/// The adaptive grid for statically-listed content (as opposed to a data
/// array). `LazyVGrid` is macOS 11; pre-11 the tiles stack vertically at full
/// width, which keeps every tile readable without a measuring pass.
struct CompatAdaptiveVGrid<Content: View>: View {
    let minimum: CGFloat
    let spacing: CGFloat
    @ViewBuilder var content: Content

    init(minimum: CGFloat, spacing: CGFloat, @ViewBuilder content: () -> Content) {
        self.minimum = minimum; self.spacing = spacing; self.content = content()
    }

    var body: some View {
        if #available(macOS 11.0, *) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: spacing)],
                      spacing: spacing) { content }
        } else {
            VStack(spacing: spacing) { content }
        }
    }
}

/// `DisclosureGroup` is macOS 11. Pre-11 gets an equivalent click-to-expand
/// header with a rotating chevron.
struct CompatDisclosureGroup<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content
    @ViewBuilder var label: Label

    init(isExpanded: Binding<Bool>,
         @ViewBuilder content: () -> Content,
         @ViewBuilder label: () -> Label) {
        self._isExpanded = isExpanded; self.content = content(); self.label = label()
    }

    var body: some View {
        if #available(macOS 11.0, *) {
            DisclosureGroup(isExpanded: $isExpanded) { content } label: { label }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button(action: { isExpanded.toggle() }) {
                    HStack(spacing: 6) {
                        Text(isExpanded ? "\u{25BE}" : "\u{25B8}")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        label
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                if isExpanded { content.padding(.leading, 14) }
            }
        }
    }
}

extension View {
    /// `.accessibilityLabel` is macOS 11; `.accessibility(label:)` is the
    /// pre-11 spelling of the same thing.
    @ViewBuilder func compatAccessibilityLabel(_ text: String) -> some View {
        if #available(macOS 11.0, *) { self.accessibilityLabel(Text(text)) }
        else { self.accessibility(label: Text(text)) }
    }
}
