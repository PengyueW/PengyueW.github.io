import SwiftUI

/// Single dashboard with a category rail and the item table for the selected
/// category.
struct ExtensionsView: View {
    @EnvironmentObject private var model: ExtensionsModel
    @State private var pendingLoginItemRemoval: ExtensionItem?

    var body: some View {
        HSplitView {
            categoryRail
                .frame(minWidth: 230, idealWidth: 250, maxWidth: 320)
            detail
                .frame(minWidth: 440, maxWidth: .infinity)
        }
        .onAppear { if model.totalCount == 0 { model.refreshAll() } }
        .compatNotice(Text("Extensions"),
                       isPresented: errorBinding,
                       dismissTitle: Text("OK"),
                       dismiss: { model.errorMessage = nil }) {
            Text(model.errorMessage ?? "")
        }
        .compatConfirm(Text("Remove “\(pendingLoginItemRemoval?.name ?? "")” from login items?"),
                        isPresented: Binding(get: { pendingLoginItemRemoval != nil },
                                 set: { if !$0 { pendingLoginItemRemoval = nil } }),
                        confirmTitle: Text("Remove"),
                        isDestructive: true,
                        confirm: { if let item = pendingLoginItemRemoval { model.toggle(item) }
                pendingLoginItemRemoval = nil },
                        cancelTitle: Text("Cancel"),
                        cancel: { pendingLoginItemRemoval = nil }) {
            Text("The app stays installed; it just stops opening at login.")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }

    private var categoryRail: some View {
        CompatSelectionList(selection: $model.selectedCategory) {
            ForEach(ExtensionCategory.allCases) { category in
                CompatLabelView {
                    Text(category.displayName)
                } icon: {
                    CompatIcon(category.symbol)
                }
                .compatBadge(model.items[category]?.count ?? 0)
                .tag(category)
            }
        }
        .compatSidebarList()
    }

    private var detail: some View {
        let category = model.selectedCategory
        let items = model.items[category] ?? []
        return VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(category.displayName).font(Font.compatTitle3.weight(.semibold))
                    Text(category.explainer)
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if model.loading.contains(category) {
                    CompatProgress().controlSize(.small)
                }
                Button {
                    model.refresh(category)
                } label: {
                    CompatIcon("arrow.clockwise")
                }
                .disabled(model.loading.contains(category))
            }
            .padding(12)
            Divider()

            if items.isEmpty && !model.loading.contains(category) {
                VStack(spacing: 8) {
                    CompatIcon(category.symbol)
                        .font(.system(size: 36, weight: .light))
                        .foregroundColor(.secondary)
                    Text("Nothing found in this category")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items) { item in
                    row(item)
                }
                .compatInsetList()
            }
        }
    }

    private func row(_ item: ExtensionItem) -> some View {
        HStack(spacing: 8) {
            CompatIcon(item.category.symbol)
                .foregroundColor(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(Font.compatCaption2).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            if item.needsAdmin {
                CompatIcon("lock")
                    .foregroundColor(.orange)
                    .compatHelp("System domain — read-only here.")
            }
            Spacer()

            if let enabled = item.enabled, !item.canToggle {
                Text(enabled ? "active" : "inactive")
                    .font(Font.compatCaption2)
                    .foregroundColor(enabled ? .green : .secondary)
            }
            if item.canToggle {
                toggleControl(item)
            }
            if let path = item.path {
                Button {
                    ExtensionProbers.reveal(path: path)
                } label: {
                    CompatIcon("magnifyingglass")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .compatHelp("Reveal in Finder")
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func toggleControl(_ item: ExtensionItem) -> some View {
        switch item.category {
        case .loginItems:
            Button("Remove…") { pendingLoginItemRemoval = item }
                .controlSize(.small)
        case .vpn:
            Button(item.enabled == true ? "Disconnect" : "Connect") {
                model.toggle(item)
            }
            .controlSize(.small)
        default:
            Toggle("", isOn: Binding(
                get: { item.enabled ?? false },
                set: { _ in model.toggle(item) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}
