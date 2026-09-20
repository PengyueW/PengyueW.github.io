import SwiftUI
import CacheCleanKit
import DiskScopeKit
import MacScanKit
import ShredKit
import FreeSpaceKit
import UninstallKit
import DriveHealthKit
import HardwareKit
import PermissionsKit
import ExtensionsKit
import NetGuardKit
import SensorsKit
import StatsKit
import AppKit

/// The suite shell: one sidebar across all divisions, with the Home page as
/// the landing section.
struct RootView: View {
    @ObservedObject var suite: SuiteModel
    @ObservedObject var cleaner: CacheCleanController
    @ObservedObject var diskMap: DiskScopeController
    @ObservedObject var security: MacScanController
    @ObservedObject var shredder: ShredController
    @ObservedObject var freeSpace: FreeSpaceController
    @ObservedObject var uninstaller: UninstallController
    @ObservedObject var driveHealth: DriveHealthController
    @ObservedObject var hardware: HardwareController
    @ObservedObject var permissions: PermissionsController
    @ObservedObject var extensions: ExtensionsController
    @ObservedObject var netGuard: NetGuardController
    @ObservedObject var sensors: SensorsController
    @ObservedObject var stats: StatsController

    var body: some View {
        CompatNavigationSplit {
            sidebar
        } detail: {
            detail
        }
        .compatToolbar {
            Group {
                DonateButton { suite.selection = .donate }
            }
                }
        // Dashboard shortcuts and the scan engine itself can ask for a page
        // change; mirror those requests into the shell's own selection.
        .onReceive(security.pageRequests) { page in
            suite.selection = .security(page)
        }
        .onAppear {
            // Start metric sampling and apply the saved app-presentation mode.
            // `showWindow` reopens the main window when the user returns to
            // Dock & Window from a menu-bar-only / hidden mode.
            stats.start {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.canBecomeMain }?
                    .makeKeyAndOrderFront(nil)
            }
        }
    }

    private var sidebar: some View {
        List(selection: $suite.selection) {
            CompatLabel("Home", systemImage: "house.fill")
                .tag(SuiteSection.home)

            CompatSection("Cleaner") {
                ForEach(CleanerPage.allCases) { page in
                    CompatLabel(LocalizedStringKey(page.title), systemImage: page.symbol)
                        .compatBadge(cleanerBadge(for: page))
                        .tag(SuiteSection.cleaner(page))
                }
            }

            CompatSection("Disk Map") {
                CompatLabel("Treemap", systemImage: "square.grid.3x3.topleft.filled")
                    .tag(SuiteSection.diskMap)
            }

            CompatSection("Security") {
                ForEach(SecurityPage.allCases) { page in
                    CompatLabel(LocalizedStringKey(page.title), systemImage: page.symbol)
                        .compatBadge(securityBadge(for: page))
                        .tag(SuiteSection.security(page))
                }
            }

            CompatSection("Apps") {
                CompatLabel("Uninstaller", systemImage: "trash.square")
                    .tag(SuiteSection.uninstaller)
                CompatLabel("Extensions", systemImage: "puzzlepiece.extension")
                    .tag(SuiteSection.extensions)
                CompatLabel("Permissions", systemImage: "hand.raised")
                    .tag(SuiteSection.permissions)
            }

            CompatSection("Privacy") {
                CompatLabel("Network Monitor", systemImage: "antenna.radiowaves.left.and.right")
                    .compatBadge(netGuard.isMonitoring ? netGuard.alertCount : 0)
                    .tag(SuiteSection.netGuard)
                CompatLabel("Shredder", systemImage: "scissors")
                    .compatBadge(shredder.queuedCount)
                    .tag(SuiteSection.shredder)
                CompatLabel("Free Space Wipe", systemImage: "eraser.line.dashed")
                    .tag(SuiteSection.freeSpace)
            }

            CompatSection("Hardware") {
                ForEach(HardwarePage.allCases) { page in
                    CompatLabel(LocalizedStringKey(page.title), systemImage: page.symbol)
                        .tag(SuiteSection.hardware(page))
                }
                CompatLabel("Drive Health", systemImage: "internaldrive")
                    .compatBadge(driveHealth.hasCriticalWarning ? "!" : nil)
                    .tag(SuiteSection.driveHealth)
                ForEach(SensorsPage.allCases) { page in
                    CompatLabel(LocalizedStringKey(page.title), systemImage: page.symbol)
                        .tag(SuiteSection.sensors(page))
                }
            }

            CompatSection("Monitors") {
                CompatLabel("Menu Bar", systemImage: "chart.bar.xaxis")
                    .tag(SuiteSection.monitors)
            }

            CompatSection("Support") {
                CompatLabel("Donate", systemImage: "heart.fill")
                    .tag(SuiteSection.donate)
            }
        }
        .compatSidebarList()
        .compatColumnWidth(min: 210, ideal: 230)
    }

    @ViewBuilder
    private var detail: some View {
        switch suite.selection ?? .home {
        case .home:
            HomeView(cleaner: cleaner, diskMap: diskMap, security: security,
                     navigate: { suite.selection = $0 })
                .compatNavigationTitle("Continuum")
        case .cleaner(let page):
            CleanerDetailView(controller: cleaner, page: page,
                              goToClean: { suite.selection = .cleaner(.clean) })
                .compatNavigationTitle(LocalizedStringKey(page.title))
        case .diskMap:
            DiskMapView(controller: diskMap)
                .compatNavigationTitle("Disk Map")
        case .security(let page):
            SecurityDetailView(controller: security, page: page)
                .compatNavigationTitle(LocalizedStringKey(page.title))
        case .uninstaller:
            UninstallerDetailView(controller: uninstaller)
                .compatNavigationTitle("Uninstaller")
        case .extensions:
            ExtensionsDetailView(controller: extensions)
                .compatNavigationTitle("Extensions")
        case .permissions:
            PermissionsDetailView(controller: permissions)
                .compatNavigationTitle("Permissions")
        case .netGuard:
            NetGuardDetailView(controller: netGuard)
                .compatNavigationTitle("Network Monitor")
        case .shredder:
            ShredderDetailView(controller: shredder)
                .compatNavigationTitle("Shredder")
        case .freeSpace:
            FreeSpaceDetailView(controller: freeSpace)
                .compatNavigationTitle("Free Space Wipe")
        case .driveHealth:
            DriveHealthDetailView(controller: driveHealth)
                .compatNavigationTitle("Drive Health")
        case .hardware(let page):
            HardwareDetailView(controller: hardware, page: page)
                .compatNavigationTitle(LocalizedStringKey(page.title))
        case .sensors(let page):
            SensorsDetailView(controller: sensors, page: page)
                .compatNavigationTitle(LocalizedStringKey(page.title))
        case .monitors:
            MonitorsDetailView(controller: stats)
                .compatNavigationTitle("Menu Bar Monitors")
        case .donate:
            DonationView()
                .compatNavigationTitle("Support Continuum")
        }
    }

    private func cleanerBadge(for page: CleanerPage) -> Int {
        switch page {
        case .clean:   return cleaner.pendingItemCount
        case .history: return cleaner.historyCount
        default:       return 0
        }
    }

    private func securityBadge(for page: SecurityPage) -> Int {
        switch page {
        case .scanner:    return security.attentionCount
        case .quarantine: return security.quarantineCount
        default:          return 0
        }
    }
}

// MARK: - Donate

/// The developer's donation link, shared by the toolbar button and the
/// donation page.
let donationURL = URL(string: "https://buymeacoffee.com/itswpy")!

/// A small red Donate button pinned to the window's toolbar header. Opens the
/// in-app donation page so the user sees the ask before being sent out.
private struct DonateButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                CompatIcon("heart.fill")
                Text("Donate")
                    .fontWeight(.semibold)
            }
            .font(.callout)
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [Color(red: 0.95, green: 0.26, blue: 0.30),
                                 Color(red: 0.80, green: 0.12, blue: 0.18)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
            .shadow(color: .black.opacity(hovering ? 0.25 : 0.12),
                    radius: hovering ? 6 : 3, y: 2)
            .scaleEffect(hovering ? 1.04 : 1.0)
        }
        .buttonStyle(.plain)
        .compatHelp("Support Continuum’s development ❤️")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Donation page

/// A heartfelt ask, shown as its own sidebar section at the very end. Continuum
/// is free and non-commercial; donations are the only thing that keep it going.
struct DonationView: View {
    @State private var hovering = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                CompatIcon("heart.fill")
                    .font(.system(size: 64, weight: .regular))
                    .compatGradientForeground(
                        LinearGradient(
                            colors: [Color(red: 0.95, green: 0.26, blue: 0.30),
                                     Color(red: 0.80, green: 0.12, blue: 0.18)],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        fallback: Color(red: 0.90, green: 0.20, blue: 0.25))
                    .shadow(color: .red.opacity(0.30), radius: 12, y: 6)
                    .padding(.top, 24)

                Text("Keep Continuum going")
                    .font(.system(size: 30, weight: .bold, design: .rounded))

                VStack(spacing: 14) {
                    Text(LocalizedStringKey(
                        "Continuum is free, open and completely non-commercial — "
                        + "no ads, no tracking, no subscriptions. It's built and "
                        + "maintained in my own time."))
                    Text(LocalizedStringKey(
                        "If it has earned a place on your Mac — reclaimed some "
                        + "space, mapped a full disk, or caught something nasty — "
                        + "please consider chipping in. Even a small donation "
                        + "directly funds the late nights, the testing hardware, "
                        + "and the next features."))
                    Text(LocalizedStringKey(
                        "Every contribution, however small, genuinely keeps the "
                        + "project alive. Thank you for being here. ❤️"))
                }
                .font(Font.compatTitle3)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560)

                Button {
                    NSWorkspace.shared.open(donationURL)
                } label: {
                    HStack(spacing: 8) {
                        CompatIcon("heart.fill")
                        Text("Donate")
                            .fontWeight(.semibold)
                    }
                    .font(Font.compatTitle3)
                    .foregroundColor(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [Color(red: 0.95, green: 0.26, blue: 0.30),
                                         Color(red: 0.80, green: 0.12, blue: 0.18)],
                                startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .shadow(color: .red.opacity(hovering ? 0.45 : 0.25),
                            radius: hovering ? 12 : 6, y: 4)
                    .scaleEffect(hovering ? 1.03 : 1.0)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .padding(.top, 4)

                Text("Made with care by Pengyue Wang · CC BY-NC-SA 4.0")
                    .font(.caption)
                    .foregroundColor(Color.compatTertiary)
                    .padding(.bottom, 32)
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity)
        }
        .background(
            Color.compat(.windowBackgroundColor)
                .compatIgnoresSafeArea())
    }
}
