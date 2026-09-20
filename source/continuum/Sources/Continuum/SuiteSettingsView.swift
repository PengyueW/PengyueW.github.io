import SwiftUI
import AppKit

/// Suite-wide Full Disk Access panel. It's shell-level on purpose: FDA is
/// granted to the **whole app** (one TCC entry for Continuum), and every
/// module — Cleaner, Disk Map, the bundled security engine, Permissions,
/// Drive Health, etc. — runs inside this one process (or as its child) and so
/// shares that single grant. Granting it here once covers everything.
struct SuiteSettingsView: View {
    @State private var hasFDA = SuiteFullDiskAccess.isGranted()
    @State private var ticker = Timer.publish(every: 2, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        Form {
            CompatSection("Full Disk Access") {
                CompatLabeledContent("Status") {
                    CompatLabel(
                        hasFDA
                            ? LocalizedStringKey("Granted to Continuum")
                            : LocalizedStringKey("Not granted"),
                        systemImage: hasFDA ? "checkmark.seal.fill" : "xmark.seal")
                        .foregroundColor(hasFDA ? .green : .orange)
                }
                Text(explanation)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !hasFDA {
                    Button("Open Full Disk Access Settings…") {
                        SuiteFullDiskAccess.openSettings()
                    }
                }
                Text(rebuildTip)
                    .font(Font.compatCaption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .compatGroupedForm()
        .frame(width: 540)
        .onReceive(ticker) { _ in hasFDA = SuiteFullDiskAccess.isGranted() }
        .onAppear { hasFDA = SuiteFullDiskAccess.isGranted() }
    }

    private var explanation: LocalizedStringKey {
        if hasFDA {
            return "Continuum has Full Disk Access. This one grant covers every module, including the bundled security engine (it runs as a child of this app and inherits the grant)."
        }
        return "Grant Full Disk Access to Continuum once — a single entry covers all modules. You don’t grant it per feature; the whole app, and the security engine it launches, share this one grant."
    }

    private var rebuildTip: LocalizedStringKey {
        "Tip: if you rebuild Continuum and the grant disappears, that’s ad-hoc signing — run ./scripts/make-signing-identity.sh once so the grant persists across rebuilds."
    }
}

/// Shell-level Full Disk Access probe shared by the whole suite: it answers
/// "can this app process read a protected file?", which is exactly the grant
/// every module depends on.
enum SuiteFullDiskAccess {
    static func isGranted() -> Bool {
        let probe = NSHomeDirectory()
            + "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = open(probe, O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    static func openSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference."
            + "security?Privacy_AllFiles"
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }
}
