import SwiftUI

/// Landing page: start a scan, watch progress, see the per-category breakdown.
struct ScanView: View {
    /// Stands in for Swift Charts' per-series colouring — its default
    /// categorical colour sequence, one hue per category.
    static let categoryPalette: [Color] = [
        Color(red: 0.20, green: 0.47, blue: 0.90),
        Color(red: 0.99, green: 0.60, blue: 0.13),
        Color(red: 0.90, green: 0.29, blue: 0.30),
        Color(red: 0.30, green: 0.72, blue: 0.53),
        Color(red: 0.62, green: 0.42, blue: 0.87),
    ]

    @EnvironmentObject private var state: AppState
    var goToClean: () -> Void

    /// Before a scan runs (and with no results to show) the page is centred in
    /// the window; the moment a scan begins — or results exist — it anchors to
    /// the top so the progress/results have room to grow.
    private var isIdle: Bool {
        state.phase != .scanning && state.items.isEmpty
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 24) {
                    header

                    if state.phase == .scanning {
                        scanningCard
                    } else if !state.items.isEmpty {
                        resultsCard
                    } else {
                        emptyCard
                    }
                }
                .padding(28)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .frame(minHeight: isIdle ? geo.size.height : nil,
                       alignment: isIdle ? .center : .top)
            }
        }
        .background(Color.compat(.windowBackgroundColor))
    }

    private var header: some View {
        VStack(spacing: 6) {
            CompatIcon("internaldrive")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(.accentColor)
            Text("Disk Scan")
                .font(.largeTitle.weight(.semibold))
            Text("Read-only preview of caches, logs, Xcode build data, broken symlinks and orphaned app folders. Nothing is deleted in this step.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var emptyCard: some View {
        VStack(spacing: 16) {
            Text("No scan results yet.")
                .foregroundColor(.secondary)
            Button {
                state.startScan()
            } label: {
                CompatLabel("Start Scan", systemImage: "magnifyingglass")
                    .frame(minWidth: 160)
            }
            .compatControlSize(.large)
            .compatBorderedProminent()
        }
        .padding(.top, 20)
    }

    private var scanningCard: some View {
        VStack(spacing: 18) {
            ProgressGauge(progress: state.progress)
                .frame(width: 140, height: 140)
            Text(state.progressLabel)
                .font(.callout.compatMonospaced())
                .foregroundColor(.secondary)
                .lineLimit(1)
            CompatRoleButton("Cancel", role: .cancel) { state.cancel() }
        }
        .padding(.top, 12)
    }

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.totalFoundBytes.formattedBytes)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("\(state.items.count) items reclaimable")
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    state.startScan()
                } label: {
                    CompatLabel("Rescan", systemImage: "arrow.clockwise")
                }
                Button {
                    goToClean()
                } label: {
                    CompatLabel("Review & Clean", systemImage: "trash")
                }
                .compatBorderedProminent()
            }

            // Per-category size breakdown
            CompatBarChart(
                bars: CleanCategory.allCases
                    .filter { state.totalBytes(in: $0) > 0 }
                    .enumerated()
                    .map { index, category in
                        CompatBarChart.Bar(
                            id: category.id,
                            label: category.displayName,
                            value: Double(state.totalBytes(in: category)),
                            color: Self.categoryPalette[index % Self.categoryPalette.count])
                    },
                axisLabel: { Int64($0).formattedBytes })
            .frame(height: CGFloat(max(120, state.itemsByCategory.keys.count * 44)))

            Divider()

            ForEach(CleanCategory.allCases) { category in
                if let count = state.itemsByCategory[category]?.count, count > 0 {
                    HStack {
                        CompatLabel(LocalizedStringKey(category.displayName), systemImage: category.systemImage)
                        Spacer()
                        Text("\(count) items")
                            .foregroundColor(.secondary)
                        Text(state.totalBytes(in: category).formattedBytes)
                            .compatMonospacedDigit()
                            .frame(width: 90, alignment: .trailing)
                    }
                    .font(.callout)
                }
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.compat(.controlBackgroundColor)))
    }
}

/// Circular progress gauge used by both the scan and clean phases.
struct ProgressGauge: View {
    var progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: 10)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.25), value: progress)
            Text("\(Int(progress * 100))%")
                .font(Font.compatTitle2.weight(.semibold).compatMonospacedDigit())
        }
    }
}
