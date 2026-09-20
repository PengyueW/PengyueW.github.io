import SwiftUI

// MARK: - Severity badge

struct SeverityBadge: View {
    let severity: Severity

    var body: some View {
        CompatLabel(severity.label, systemImage: severity.symbol)
            .font(.caption.weight(.semibold))
            .foregroundColor(severity.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(severity.color.opacity(0.14)))
    }
}

// MARK: - Severity count chip (dashboard / summaries)

struct SeverityCountChip: View {
    let severity: Severity
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            CompatIcon(severity.symbol)
                .foregroundColor(severity.color)
            Text("\(count)")
                .fontWeight(.semibold)
                .compatMonospacedDigit()
            Text(severity.label)
                .foregroundColor(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.compatQuaternary.opacity(0.5)))
    }
}

// MARK: - Card container

struct Card<Content: View>: View {
    var title: LocalizedStringKey?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 6) {
                    if let systemImage {
                        CompatIcon(systemImage)
                            .foregroundColor(.secondary)
                    }
                    Text(title)
                        .font(.headline)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .compatMaterialBackground(cornerRadius: 10)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.compat(.separatorColor).opacity(0.5))
        )
    }
}

// MARK: - Empty state (ContentUnavailableView is macOS 14+, so roll our own)

struct EmptyState: View {
    var symbol: String
    var title: LocalizedStringKey
    var message: LocalizedStringKey
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            CompatIcon(symbol)
                .font(.system(size: 42, weight: .light))
                .foregroundColor(Color.compatTertiary)
            Text(title)
                .font(Font.compatTitle3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .compatBorderedProminent()
                    .compatControlSize(.large)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Posture tile (dashboard)

struct PostureTile: View {
    var title: LocalizedStringKey
    var symbol: String
    var status: AppModel.PostureStatus
    var detail: LocalizedStringKey

    private var statusText: LocalizedStringKey {
        switch status {
        case .enabled:  return "Enabled"
        case .disabled: return "Disabled"
        case .unknown:  return "Run a scan"
        }
    }

    private var statusColor: Color {
        switch status {
        case .enabled:  return .green
        case .disabled: return .red
        case .unknown:  return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CompatIcon(symbol)
                    .font(Font.compatTitle2)
                    .foregroundColor(statusColor)
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(statusText)
                .font(Font.compatTitle3.weight(.bold))
                .foregroundColor(statusColor)
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .compatLineLimit(2, reservesSpace: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .compatMaterialBackground(cornerRadius: 10)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.compat(.separatorColor).opacity(0.5))
        )
    }
}

// MARK: - Path row with a Finder affordance

struct PathRow: View {
    let path: String

    var body: some View {
        HStack(spacing: 6) {
            CompatIcon("doc")
                .font(.caption)
                .foregroundColor(Color.compatTertiary)
            Text(path)
                .font(.caption.compatMonospaced())
                .foregroundColor(.secondary)
                .compatTextSelection()
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath) {
                Button {
                    let expanded = (path as NSString).expandingTildeInPath
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: expanded)])
                } label: {
                    CompatIcon("magnifyingglass.circle")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .compatHelp("Reveal in Finder")
            }
        }
    }
}

// MARK: - Formatting helpers

enum Format {
    static let scanDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// "2026-06-12 10:00:00" (quarantine) and "2026-06-12T10:00:00" (manifest).
    static func prettyTimestamp(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "T", with: " ")
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd HH:mm:ss"
        parser.timeZone = .current
        guard let date = parser.date(from: normalized) else { return raw }
        return scanDate.string(from: date)
    }
}
