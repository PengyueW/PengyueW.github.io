import SwiftUI

/// Permission manager: service categories on the left, the apps holding that
/// permission (with revoke buttons) on the right.
struct PermissionsView: View {
    @EnvironmentObject private var model: PermissionsModel
    @State private var confirmResetAll: TCCService?

    var body: some View {
        HSplitView {
            serviceList
                .frame(minWidth: 240, idealWidth: 270, maxWidth: 340)
            detail
                .frame(minWidth: 420, maxWidth: .infinity)
        }
        .onAppear { if model.grants.isEmpty { model.refresh() } }
        .compatToolbar {
            Group {
                Button {
                    model.refresh()
                } label: {
                    CompatIcon("arrow.clockwise")
                }
                .disabled(model.isLoading)
                .compatHelp("Re-read the TCC databases")
            }
                }
        .compatNotice(Text("Permissions"),
                       isPresented: errorBinding,
                       dismissTitle: Text("OK"),
                       dismiss: { model.errorMessage = nil }) {
            Text(model.errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }

    // MARK: left pane

    private var serviceList: some View {
        VStack(spacing: 0) {
            if !model.systemReadable {
                fdaBanner
            }
            List(selection: $model.selectedServiceID) {
                ForEach(model.services, id: \.service.id) { entry in
                    CompatLabelView {
                        Text(entry.service.title)
                    } icon: {
                        CompatIcon(entry.service.symbol)
                    }
                    .compatBadge(entry.grants.filter(\.allowed).count)
                    .tag(entry.service.id)
                }
            }
            .compatSidebarList()
        }
    }

    private var fdaBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            CompatLabel("Partial view", systemImage: "exclamationmark.triangle")
                .font(.caption.weight(.semibold))
                .foregroundColor(.orange)
            Text("Without Full Disk Access, the machine-wide database (Camera, Microphone, Full Disk Access, Accessibility…) can’t be read — only user-domain services appear.")
                .font(Font.compatCaption2)
                .foregroundColor(.secondary)
            Button("Grant Full Disk Access…") {
                TCCReader.openSystemSettings(anchor: "Privacy_AllFiles")
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
    }

    // MARK: right pane

    @ViewBuilder
    private var detail: some View {
        if let entry = model.services.first(where: {
            $0.service.id == model.selectedServiceID
        }) {
            serviceDetail(entry.service, grants: entry.grants)
        } else if model.isLoading {
            CompatProgress("Reading TCC databases…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                CompatIcon("hand.raised")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(.secondary)
                Text("Select a permission category")
                    .font(Font.compatTitle3.weight(.semibold))
                Text("Continuum aggregates which apps can use the camera and microphone, and which hold sensitive access like Full Disk Access or Accessibility.")
                    .font(.callout).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func serviceDetail(_ service: TCCService,
                               grants: [TCCGrant]) -> some View {
        VStack(spacing: 0) {
            HStack {
                CompatLabel(service.title, systemImage: service.symbol)
                    .font(Font.compatTitle3.weight(.semibold))
                Spacer()
                Button("Open in System Settings") {
                    TCCReader.openSystemSettings(anchor: service.settingsAnchor)
                }
                CompatRoleButton(role: .destructive) {
                    confirmResetAll = service
                } label: {
                    Text("Reset All…")
                }
                .disabled(grants.isEmpty)
            }
            .padding(12)
            Divider()

            List(grants) { grant in
                grantRow(service: service, grant: grant)
            }
            .compatInsetList()

            Divider()
            Text("Revoking uses Apple’s supported `tccutil reset`. The app will ask again the next time it needs the permission; granting is only possible in System Settings.")
                .font(Font.compatCaption2).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .compatConfirm(Text("Reset every \(confirmResetAll?.title ?? "") entry?"),
                        isPresented: Binding(get: { confirmResetAll != nil },
                                 set: { if !$0 { confirmResetAll = nil } }),
                        confirmTitle: Text("Reset All"),
                        isDestructive: true,
                        confirm: { if let service = confirmResetAll {
                    model.reset(serviceID: service.id, client: nil)
                }
                confirmResetAll = nil },
                        cancelTitle: Text("Cancel"),
                        cancel: { confirmResetAll = nil }) {
            Text("Every app loses its \(confirmResetAll?.title ?? "") standing "
                 + "and must ask again.")
        }
    }

    private func grantRow(service: TCCService, grant: TCCGrant) -> some View {
        HStack(spacing: 8) {
            if let icon = grant.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
            } else {
                CompatIcon("terminal")
                    .frame(width: 24, height: 24)
                    .foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(grant.clientDisplayName)
                Text(grant.client)
                    .font(Font.compatCaption2).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let date = grant.lastModified {
                Text(date.compatFormatted(dateStyle: .medium, timeStyle: .none))
                    .font(Font.compatCaption2).foregroundColor(.secondary)
            }
            statusBadge(grant)
            Button("Revoke") {
                model.reset(serviceID: service.id, client: grant.client)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func statusBadge(_ grant: TCCGrant) -> some View {
        let label: LocalizedStringKey = grant.limited ? "Limited" : grant.allowed ? "Allowed" : "Denied"
        return Text(label)
            .font(Font.compatCaption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill((grant.allowed
                         ? (grant.limited ? Color.orange : Color.green)
                         : Color.secondary).opacity(0.18)))
            .foregroundColor(grant.allowed
                             ? (grant.limited ? Color.orange : Color.green)
                             : Color.secondary)
    }
}
