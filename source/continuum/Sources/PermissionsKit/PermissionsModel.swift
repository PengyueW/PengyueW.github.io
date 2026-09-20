import Foundation
import Combine

/// Aggregated TCC permission state, grouped by service, with revocation.
@MainActor
final class PermissionsModel: ObservableObject {
    @Published var grants: [TCCGrant] = []
    @Published var systemReadable = false
    @Published var isLoading = false
    @Published var lastRefresh: Date?
    @Published var errorMessage: String?
    @Published var selectedServiceID: String?

    /// Services that actually have at least one entry, hardware/sensitive
    /// first (camera & mic, then data access), then everything else found.
    var services: [(service: TCCService, grants: [TCCGrant])] {
        var byService: [String: [TCCGrant]] = [:]
        for grant in grants {
            byService[grant.serviceID, default: []].append(grant)
        }
        let knownOrder = TCCService.known.map(\.id)
        let sortedIDs = byService.keys.sorted {
            let a = knownOrder.firstIndex(of: $0) ?? Int.max
            let b = knownOrder.firstIndex(of: $1) ?? Int.max
            return a == b ? $0 < $1 : a < b
        }
        return sortedIDs.map { id in
            (TCCService.lookup(id),
             byService[id]!.sorted {
                 $0.clientDisplayName.localizedCaseInsensitiveCompare(
                     $1.clientDisplayName) == .orderedAscending
             })
        }
    }

    var allowedCount: Int { grants.filter(\.allowed).count }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let (grants, systemReadable) = TCCReader.readAll()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.grants = grants
                self.systemReadable = systemReadable
                self.lastRefresh = Date()
                self.isLoading = false
                if self.selectedServiceID == nil {
                    self.selectedServiceID = self.services.first?.service.id
                }
            }
        }
    }

    /// Revokes one app for one service (passing nil resets the whole service)
    /// then re-reads the databases.
    func reset(serviceID: String, client: String?) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let error = TCCReader.reset(serviceID: serviceID, client: client)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let error {
                    self.errorMessage =
                        "Couldn’t reset: \(error)\n\nNote that macOS protects "
                        + "some system entries from tccutil."
                }
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            await MainActor.run { [weak self] in
                self?.isLoading = false
                self?.refresh()
            }
        }
    }
}
