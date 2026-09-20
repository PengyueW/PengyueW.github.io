import Foundation
import SwiftUI
import Combine

/// One dashboard over every category of extension/plug-in/background item.
@MainActor
final class ExtensionsModel: ObservableObject {
    @Published var items: [ExtensionCategory: [ExtensionItem]] = [:]
    @Published var loading: Set<ExtensionCategory> = []
    @Published var selectedCategory: ExtensionCategory = .appExtensions
    @Published var errorMessage: LocalizedStringKey?

    var totalCount: Int { items.values.reduce(0) { $0 + $1.count } }

    func refreshAll() {
        for category in ExtensionCategory.allCases { refresh(category) }
    }

    func refresh(_ category: ExtensionCategory) {
        guard !loading.contains(category) else { return }
        loading.insert(category)
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = ExtensionProbers.probe(category)
            await MainActor.run { [weak self] in
                self?.items[category] = found
                self?.loading.remove(category)
            }
        }
    }

    func toggle(_ item: ExtensionItem) {
        let target = !(item.enabled ?? false)
        Task.detached(priority: .userInitiated) { [weak self] in
            let ok: Bool
            switch item.category {
            case .appExtensions:
                ok = ExtensionProbers.setAppExtension(identifier: item.id,
                                                      enabled: target)
            case .launchAgents:
                guard let path = item.path else { return }
                ok = ExtensionProbers.setLaunchAgent(plistPath: path,
                                                     enabled: target)
            case .vpn:
                ok = ExtensionProbers.setVPN(named: item.name,
                                             connected: target)
            case .loginItems:
                ok = ExtensionProbers.removeLoginItem(named: item.name)
            default:
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if !ok {
                    self.errorMessage = self.failureText(for: item.category)
                }
                self.refresh(item.category)
            }
        }
    }

    private func failureText(for category: ExtensionCategory) -> LocalizedStringKey {
        switch category {
        case .loginItems:
            return "Couldn’t change the login item. macOS asks you to allow Continuum to control “System Events” the first time (System Settings → Privacy & Security → Automation)."
        case .launchAgents:
            return "launchctl refused. The job may already be in that state, or it belongs to a system domain."
        case .vpn:
            return "scutil couldn’t change the VPN state. Some VPN types can only be controlled by their own app."
        default:
            return "The change didn’t apply."
        }
    }
}
