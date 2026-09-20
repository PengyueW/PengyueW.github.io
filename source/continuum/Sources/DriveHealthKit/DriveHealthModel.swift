import Foundation
import Combine

/// Aggregates the NVMe SMART snapshot for the UI and refreshes it on demand
/// (and every minute while the page is visible).
@MainActor
final class DriveHealthModel: ObservableObject {
    @Published var log: NVMeSMARTLog?
    @Published var identity = NVMeIdentity()
    @Published var diskSize: Int64?
    @Published var lastRefresh: Date?
    @Published var isRefreshing = false
    @Published var isUnavailable = false

    private var timer: AnyCancellable?

    /// Rough endurance budget used for the lifespan estimate when the drive
    /// only reports percentage-used: scale TBW against it.
    var estimatedLifePercentLeft: Int? {
        guard let log else { return nil }
        return max(0, 100 - log.percentageUsed)
    }

    func startAutoRefresh() {
        refresh()
        timer = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    func stopAutoRefresh() {
        timer = nil
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = NVMeSMARTReader.read()
            let size = BootDiskInfo.wholeDiskSize()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRefreshing = false
                self.diskSize = size
                self.lastRefresh = Date()
                if let result {
                    self.log = result.log
                    self.identity = result.identity
                    self.isUnavailable = false
                } else if self.log == nil {
                    self.isUnavailable = true
                }
            }
        }
    }
}
