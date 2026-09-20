import SwiftUI

/// Onboarding-style walkthrough for granting Full Disk Access, shown when a
/// forensic capability is blocked by TCC or on demand from Settings/Dashboard.
struct PermissionsHelpView: View {
    @EnvironmentObject private var model: AppModel
    // `\.dismiss` is macOS 12; `presentationMode` is the universal spelling.
    @Environment(\.presentationMode) private var presentationMode

    private static let fdaSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// What the user must add to the FDA list: the bundled app when running
    /// from MacScan.app, otherwise the host (Terminal/IDE) the binary runs in.
    private var subjectName: String {
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasSuffix(".app") {
            return (bundlePath as NSString).lastPathComponent
        }
        return "the terminal app running MacScan (e.g. Terminal)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                CompatIcon("lock.shield.fill")
                    .font(.system(size: 38))
                    .foregroundColor(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Grant Full Disk Access")
                        .font(Font.compatTitle2.weight(.bold))
                    Text("macOS protects the privacy database (TCC.db) and network-usage records. MacScan needs Full Disk Access to audit them — without it those checks become blind spots, not failures.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                step(1, symbol: "gearshape",
                     title: "Open System Settings",
                     detail: "Go to Privacy & Security → Full Disk Access. The button below takes you straight there.")
                step(2, symbol: "plus.circle",
                     title: "Add \(subjectName)",
                     detail: "Click the + button (or drag the app into the list) and switch its toggle on. macOS may ask you to authenticate.")
                step(3, symbol: "arrow.counterclockwise.circle",
                     title: "Relaunch and re-scan",
                     detail: "Quit and reopen MacScan, then run the forensic scan again — the blind-spot list should shrink.")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .compatColorBackground(Color.compatQuaternary.opacity(0.3), cornerRadius: 10)

            VStack(alignment: .leading, spacing: 6) {
                CompatLabel("Going further", systemImage: "terminal")
                    .font(.subheadline.weight(.semibold))
                Text("Some checks (EFI integrity, system-domain databases, Background Task Management) additionally require root. For maximum forensic coverage run this in Terminal:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    Text("sudo ./macscan scan --forensic")
                        .font(.callout.compatMonospaced())
                        .compatTextSelection()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .compatColorBackground(Color.black.opacity(0.06), cornerRadius: 6)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            "sudo ./macscan scan --forensic", forType: .string)
                    } label: {
                        CompatIcon("doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .compatHelp("Copy command")
                }
            }

            HStack {
                CompatLabel(model.hasFullDiskAccess
                      ? "Full Disk Access is granted"
                      : "Full Disk Access not yet detected",
                      systemImage: model.hasFullDiskAccess
                      ? "checkmark.seal.fill" : "xmark.seal")
                    .font(.callout)
                    .foregroundColor(model.hasFullDiskAccess ? .green : .orange)
                Button {
                    model.refreshFullDiskAccess()
                } label: {
                    CompatIcon("arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .compatHelp("Re-check")
                Spacer()
                Button("Open System Settings") {
                    NSWorkspace.shared.open(Self.fdaSettingsURL)
                }
                .compatBorderedProminent()
                Button("Done") { presentationMode.wrappedValue.dismiss() }
                    .compatCancelAction()
            }
        }
        .padding(24)
        .frame(width: 620)
        .onAppear { model.refreshFullDiskAccess() }
    }

    private func step(_ number: Int, symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 30, height: 30)
                Text("\(number)")
                    .font(.callout.weight(.bold))
                    .foregroundColor(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                CompatLabel(title, systemImage: symbol)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
