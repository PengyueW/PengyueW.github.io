import SwiftUI
import AppKit
import CryptoKit

/// Lets a user verify that the shipped binaries haven't been tampered with by
/// computing the MD5 checksum of each critical file in the bundle. They can
/// compare a value against one published with the release, or hash any file of
/// their choosing. MD5 is used purely as a quick, widely-recognised integrity
/// fingerprint — not as a security signature (Gatekeeper / codesign do that).
struct IntegrityView: View {
    @State private var items: [IntegrityItem] = []
    @State private var computing = false
    @State private var expected = ""

    var body: some View {
        Form {
            CompatSection("App Integrity (MD5)") {
                Text("This is the checksum of Continuum's own application binary. Compare it with the line for your build in the CHECKSUMS.txt published with the release — a mismatch means the binary was modified after it was built.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if items.isEmpty && computing {
                    HStack(spacing: 8) {
                        CompatProgress().controlSize(.small)
                        Text("Computing checksums…").foregroundColor(.secondary)
                    }
                }

                ForEach(items) { item in
                    IntegrityRow(item: item, expected: expected)
                }
            }

            CompatSection("Compare a Checksum") {
                Text("Paste the MD5 published for your build to confirm it matches, or hash any other file yourself.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Expected MD5", text: $expected)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                HStack {
                    Button("Recompute") { recompute() }
                        .disabled(computing)
                    Button("Hash a File…") { hashArbitraryFile() }
                    Spacer()
                }
            }
        }
        .compatGroupedForm()
        .frame(width: 540)
        .onAppear { if items.isEmpty { recompute() } }
    }

    private func recompute() {
        computing = true
        let targets = IntegrityItem.bundledTargets()
        DispatchQueue.global(qos: .userInitiated).async {
            let computed = targets.map { target -> IntegrityItem in
                var t = target
                t.md5 = MD5Hasher.hexDigest(ofFileAt: target.url)
                return t
            }
            DispatchQueue.main.async {
                items = computed
                computing = false
            }
        }
    }

    private func hashArbitraryFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let digest = MD5Hasher.hexDigest(ofFileAt: url)
            DispatchQueue.main.async {
                let item = IntegrityItem(name: url.lastPathComponent,
                                         detail: url.path, url: url, md5: digest)
                // Replace any prior arbitrary hash with the new one.
                items.removeAll { !$0.isBundled }
                items.append(item)
            }
        }
    }
}

private struct IntegrityRow: View {
    let item: IntegrityItem
    let expected: String

    private var matches: Bool {
        guard let md5 = item.md5, !expected.isEmpty else { return false }
        return md5.caseInsensitiveCompare(
            expected.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                CompatLabel(item.name, systemImage: item.isBundled ? "doc.badge.gearshape" : "doc")
                    .font(.callout.weight(.medium))
                Spacer()
                if matches {
                    CompatLabel("Match", systemImage: "checkmark.seal.fill")
                        .foregroundColor(.green)
                        .font(.caption.weight(.semibold))
                } else if !expected.isEmpty && item.md5 != nil {
                    CompatLabel("No match", systemImage: "xmark.seal")
                        .foregroundColor(.orange)
                        .font(.caption.weight(.semibold))
                }
            }
            HStack(spacing: 8) {
                Text(item.md5 ?? "unavailable")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(item.md5 == nil ? .secondary : .primary)
                    .compatTextSelection()
                if let md5 = item.md5 {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(md5, forType: .string)
                    } label: {
                        CompatIcon("doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .compatHelp("Copy checksum")
                }
            }
            Text(item.detail)
                .font(Font.compatCaption2)
                .foregroundColor(Color.compatTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }
}

/// One file whose integrity can be checked.
private struct IntegrityItem: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let url: URL
    var md5: String?
    var isBundled = true

    /// The one file this page vouches for: Continuum's own application binary.
    ///
    /// It used to also list `diskscope-scan` and the `macscan` engine script.
    /// Three hashes made the page impossible to actually use — the release
    /// manifest published one number per build, so two of the three rows could
    /// never match anything and read as failures. `scripts/write-checksums.sh`
    /// emits the MD5 of exactly this file, per deployment target, and that is
    /// the number a user pastes into "Expected MD5" below.
    static func bundledTargets() -> [IntegrityItem] {
        guard let exe = Bundle.main.executableURL else { return [] }
        return [.init(name: "Continuum (application binary)",
                      detail: exe.path, url: exe, md5: nil)]
    }
}

/// Streaming MD5 so even large binaries hash without loading fully into memory.
enum MD5Hasher {
    static func hexDigest(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while true {
            let chunk = handle.compatRead(upToCount: 1 << 20)
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
