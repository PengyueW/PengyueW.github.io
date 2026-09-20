import SwiftUI
import AppKit
import CacheCleanKit
import DiskScopeKit
import MacScanKit
import HardwareKit
import SensorsKit

/// Landing page: a glance at the startup disk plus one card per division.
struct HomeView: View {
    @ObservedObject var cleaner: CacheCleanController
    @ObservedObject var diskMap: DiskScopeController
    @ObservedObject var security: MacScanController
    let navigate: (SuiteSection) -> Void

    @State private var disk = DiskUsage.current()

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                storageCard
                divisionGrid
                toolsSection
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .background(backdrop)
        .onAppear { disk = DiskUsage.current() }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 88, height: 88)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
            Text("Continuum")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("See it. Clean it. Secure it.")
                .font(Font.compatTitle3)
                .foregroundColor(.secondary)
        }
        .padding(.top, 12)
    }

    // MARK: Storage overview

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CompatLabel(disk?.volumeName ?? "Startup Disk", systemImage: "internaldrive")
                    .font(.headline)
                Spacer()
                if let disk {
                    Text("\(format(disk.free)) free of \(format(disk.total))")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .compatMonospacedDigit()
                }
            }
            if let disk {
                CompatProgress(value: disk.usedFraction)
                    .compatTint(disk.usedFraction > 0.9 ? .red : .accentColor)
            } else {
                Text("Startup disk size unavailable")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .background(cardBackground)
    }

    // MARK: Division cards

    private var divisionGrid: some View {
        CompatGrid(horizontalSpacing: 20, verticalSpacing: 20) {
            CompatGridRow {
                DivisionCard(
                    title: "Disk Map",
                    symbol: "square.grid.3x3.topleft.filled",
                    gradient: [Color(red: 0.55, green: 0.35, blue: 0.95),
                               Color(red: 0.85, green: 0.35, blue: 0.75)],
                    description: "See where every gigabyte lives. An "
                        + "interactive treemap of any folder or volume — "
                        + "click to zoom, double-click to reveal in Finder.",
                    status: diskMap.lastScanSummary ?? "No folder scanned yet",
                    actionTitle: "Choose Folder…",
                    isBusy: diskMap.isScanning,
                    open: { navigate(.diskMap) },
                    action: {
                        navigate(.diskMap)
                        diskMap.openFolderAndScan()
                    })

                DivisionCard(
                    title: "Cleaner",
                    symbol: "sparkles",
                    gradient: [Color(red: 0.20, green: 0.55, blue: 1.0),
                               Color(red: 0.15, green: 0.80, blue: 0.95)],
                    description: "Reclaim space safely. Caches, logs and "
                        + "developer leftovers — everything previewed first, "
                        + "everything goes to the Trash, never hard-deleted.",
                    status: cleaner.lastRunSummary ?? "Ready to scan",
                    actionTitle: "Scan Now",
                    isBusy: cleaner.isBusy,
                    open: { navigate(.cleaner(.scan)) },
                    action: {
                        navigate(.cleaner(.scan))
                        cleaner.startScan()
                    })

                DivisionCard(
                    title: "Security",
                    symbol: "shield.lefthalf.filled",
                    gradient: [Color(red: 0.15, green: 0.70, blue: 0.45),
                               Color(red: 0.45, green: 0.85, blue: 0.40)],
                    description: "Scan for malware, adware, keyloggers and "
                        + "spyware. Findings are explained, and removal is a "
                        + "reversible quarantine — never a blind delete.",
                    status: security.lastScanSummary
                        ?? (security.engineAvailable ? "Engine ready" : "Engine not found"),
                    statusAttention: security.attentionCount > 0,
                    actionTitle: "Quick Scan",
                    isBusy: security.isScanning,
                    open: { navigate(.security(.dashboard)) },
                    action: {
                        navigate(.security(.scanner))
                        security.startStandardScan()
                    })
            }
        }
    }

    // MARK: More tools

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("More Tools")
                .font(Font.compatTitle3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            CompatAdaptiveGrid(items: ToolTile.all, minimum: 220, spacing: 14) { tile in
                    Button { navigate(tile.section) } label: {
                        HStack(spacing: 12) {
                            CompatIcon(tile.symbol)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(tile.color)
                                .frame(width: 38, height: 38)
                                .compatColorBackground(tile.color.opacity(0.14), cornerRadius: 10)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(LocalizedStringKey(tile.title))
                                    .font(.callout.weight(.semibold))
                                Text(LocalizedStringKey(tile.subtitle))
                                    .font(Font.compatCaption2).foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(cardBackground)
                    }
                    .buttonStyle(.plain)
            }
        }
    }

    // MARK: Chrome

    private var backdrop: some View {
        Color.compat(.windowBackgroundColor)
            .compatIgnoresSafeArea()
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.compat(.controlBackgroundColor).opacity(0.72))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07)))
            .shadow(color: .black.opacity(0.10), radius: 7, y: 3)
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Quick-access tiles for the secondary divisions

private struct ToolTile: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color
    let section: SuiteSection

    static let all: [ToolTile] = [
        .init(title: "Uninstaller", subtitle: "Purge an app and every leftover",
              symbol: "trash.square", color: .red, section: .uninstaller),
        .init(title: "Extensions", subtitle: "Govern plug-ins, login & launch items",
              symbol: "puzzlepiece.extension", color: .purple, section: .extensions),
        .init(title: "Permissions", subtitle: "Camera, mic, Full Disk Access & more",
              symbol: "hand.raised", color: .blue, section: .permissions),
        .init(title: "Network Monitor", subtitle: "Watch & block outbound connections",
              symbol: "antenna.radiowaves.left.and.right", color: .orange,
              section: .netGuard),
        .init(title: "Shredder", subtitle: "Securely erase files (DoD 5220.22-M)",
              symbol: "scissors", color: .pink, section: .shredder),
        .init(title: "Free Space Wipe", subtitle: "Overwrite free space so deletes are unrecoverable",
              symbol: "eraser.line.dashed", color: .red, section: .freeSpace),
        .init(title: "Thermal & Fans", subtitle: "Sensors and custom fan curves",
              symbol: "fanblades", color: .compatCyan, section: .hardware(.thermal)),
        .init(title: "Battery", subtitle: "Health, cycles & live wattage",
              symbol: "battery.75", color: .green, section: .hardware(.battery)),
        .init(title: "Power & Peripherals", subtitle: "USB-PD & per-device draw",
              symbol: "powerplug", color: .yellow, section: .hardware(.power)),
        .init(title: "Drive Health", subtitle: "TBW & S.M.A.R.T. attributes",
              symbol: "internaldrive", color: .compatIndigo, section: .driveHealth),
        .init(title: "Sensors", subtitle: "Ambient light, lid angle, accelerometer",
              symbol: "sensor", color: .compatMint, section: .sensors(.sensors)),
        .init(title: "Automations", subtitle: "Run scripts on sensor conditions",
              symbol: "wand.and.stars", color: .compatTeal, section: .sensors(.automations)),
        .init(title: "Menu Bar Monitors", subtitle: "CPU, RAM & network at a glance",
              symbol: "chart.bar.xaxis", color: .gray, section: .monitors),
    ]
}

// MARK: - One division card

private struct DivisionCard: View {
    let title: String
    let symbol: String
    let gradient: [Color]
    let description: String
    let status: String
    var statusAttention = false
    let actionTitle: String
    let isBusy: Bool
    let open: () -> Void
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                CompatIcon(symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(colors: gradient,
                                                 startPoint: .topLeading,
                                                 endPoint: .bottomTrailing)))
                    .shadow(color: gradient[0].opacity(0.45), radius: 6, y: 3)
                Text(LocalizedStringKey(title))
                    .font(Font.compatTitle2.weight(.semibold))
                Spacer()
                CompatIcon("chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Color.compatTertiary)
                    .opacity(hovering ? 1 : 0.4)
            }

            Text(LocalizedStringKey(description))
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)

            HStack(spacing: 6) {
                Circle()
                    .fill(statusAttention ? Color.orange : Color.green)
                    .frame(width: 7, height: 7)
                Text(LocalizedStringKey(status))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Button(action: action) {
                if isBusy {
                    HStack(spacing: 6) {
                        CompatProgress().controlSize(.small)
                        Text("Working…")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text(LocalizedStringKey(actionTitle))
                        .frame(maxWidth: .infinity)
                }
            }
            .compatBorderedProminent()
            .compatTint(gradient[0])
            .compatControlSize(.large)
            .disabled(isBusy)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.compat(.controlBackgroundColor).opacity(hovering ? 0.95 : 0.72))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(hovering ? 0.12 : 0.07)))
                .shadow(color: .black.opacity(hovering ? 0.18 : 0.10),
                        radius: hovering ? 12 : 7, y: hovering ? 6 : 3))
        .scaleEffect(hovering ? 1.015 : 1.0)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .compatAccessibilityLabel("\(title). \(status)")
    }
}

// MARK: - Startup-disk usage

private struct DiskUsage {
    var volumeName: String
    var total: Int64
    var free: Int64
    var usedFraction: Double { total > 0 ? Double(total - free) / Double(total) : 0 }

    /// `volumeAvailableCapacityForImportantUsage` matches the "available"
    /// figure Finder shows (purgeable space counts as free).
    static func current() -> DiskUsage? {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys:
                [.volumeTotalCapacityKey,
                 .volumeAvailableCapacityForImportantUsageKey,
                 .volumeLocalizedNameKey]),
              let total = values.volumeTotalCapacity
        else { return nil }
        let free = values.volumeAvailableCapacityForImportantUsage ?? 0
        return DiskUsage(volumeName: values.volumeLocalizedName ?? "Startup Disk",
                         total: Int64(total), free: free)
    }
}
