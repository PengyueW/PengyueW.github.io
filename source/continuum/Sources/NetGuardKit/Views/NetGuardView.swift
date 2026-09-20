import SwiftUI

/// Network monitor page: a start/stop reverse firewall, the live connection
/// list grouped by app, the new-connection alert feed, and the block list.
struct NetGuardView: View {
    @EnvironmentObject private var model: NetGuardModel
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            Picker("", selection: $tab) {
                Text("Connections").tag(0)
                Text("Alerts (\(model.alerts.count))").tag(1)
                Text("Blocked (\(model.firewall.rules.count))").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            Group {
                switch tab {
                case 1:  alertsList
                case 2:  blockedList
                default: connectionList
                }
            }
        }
        .compatNotice(Text("Firewall"),
                       isPresented: firewallErrorBinding,
                       dismissTitle: Text("OK"),
                       dismiss: { model.firewall.lastError = nil }) {
            Text(model.firewall.lastError ?? "")
        }
    }

    private var firewallErrorBinding: Binding<Bool> {
        Binding(get: { model.firewall.lastError != nil },
                set: { if !$0 { model.firewall.lastError = nil } })
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button {
                model.toggleMonitoring()
            } label: {
                CompatLabel(model.isMonitoring ? "Stop Monitoring" : "Start Monitoring",
                      systemImage: model.isMonitoring ? "stop.circle" : "play.circle")
            }
            .compatBorderedProminent()
            .compatTint(model.isMonitoring ? .red : .accentColor)

            Toggle("Alert on new apps", isOn: $model.alertOnNewApps)
                .toggleStyle(.switch)

            if model.isMonitoring {
                HStack(spacing: 5) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("\(model.connections.count) active connections")
                        .font(.callout).foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
    }

    // MARK: connections

    @ViewBuilder
    private var connectionList: some View {
        if model.connections.isEmpty {
            placeholder("network.slash",
                        model.isMonitoring
                        ? "No outbound connections right now."
                        : "Start monitoring to watch outbound connections in real time.")
        } else {
            List {
                ForEach(model.connectionsByApp, id: \.app) { group in
                    Section {
                        ForEach(group.conns) { conn in
                            connectionRow(conn)
                        }
                    } header: {
                        HStack {
                            Text(group.app)
                            if let bundle = group.bundleID {
                                Text(bundle).font(Font.compatCaption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("\(group.conns.count)")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .compatInsetList()
        }
    }

    private func connectionRow(_ conn: Connection) -> some View {
        HStack(spacing: 8) {
            CompatIcon(conn.proto == "UDP" ? "dot.radiowaves.left.and.right"
                                                  : "arrow.up.right")
                .foregroundColor(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(conn.remoteEndpoint).font(.callout.compatMonospaced())
                Text("\(conn.proto) · local :\(conn.localPort) · since "
                     + conn.firstSeen.compatFormatted(dateStyle: .none, timeStyle: .medium))
                    .font(Font.compatCaption2).foregroundColor(.secondary)
            }
            Spacer()
            if model.firewall.isBlocked(conn.remoteAddress) {
                CompatLabel("Blocked", systemImage: "hand.raised.fill")
                    .font(Font.compatCaption2).foregroundColor(.red)
                Button("Unblock") { model.unblock(host: conn.remoteAddress) }
                    .controlSize(.small)
            } else {
                CompatRoleButton(role: .destructive) {
                    model.block(conn)
                } label: {
                    Text("Block")
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: alerts

    @ViewBuilder
    private var alertsList: some View {
        if model.alerts.isEmpty {
            placeholder("bell.slash",
                        "No new-connection alerts yet. While monitoring, the first time each app opens an outbound connection it shows up here.")
        } else {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Clear") { model.clearAlerts() }
                        .controlSize(.small).padding(8)
                }
                List(model.alerts) { alert in
                    HStack(spacing: 8) {
                        CompatIcon("bell.badge")
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(alert.connection.processName) → "
                                 + alert.connection.remoteEndpoint)
                                .font(.callout)
                            Text(alert.date.compatFormatted(dateStyle: .none, timeStyle: .medium))
                                .font(Font.compatCaption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        if !model.firewall.isBlocked(alert.connection.remoteAddress) {
                            CompatRoleButton(role: .destructive) {
                                model.block(alert.connection)
                            } label: { Text("Block") }
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .compatInsetList()
            }
        }
    }

    // MARK: blocked

    @ViewBuilder
    private var blockedList: some View {
        VStack(spacing: 0) {
            if model.firewall.rules.isEmpty {
                placeholder("checkmark.shield",
                            "No blocked hosts. Blocking writes a pf anchor (one administrator prompt) that drops outbound traffic to a remote IP.")
            } else {
                HStack {
                    Spacer()
                    Button("Unblock All") { model.firewall.unblockAll() }
                        .controlSize(.small).padding(8)
                }
                List(model.firewall.rules) { rule in
                    HStack {
                        CompatIcon("hand.raised.fill").foregroundColor(.red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.host).font(.callout.compatMonospaced())
                            Text("from \(rule.note) · "
                                 + rule.date.compatFormatted(dateStyle: .medium, timeStyle: .short))
                                .font(Font.compatCaption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Unblock") { model.unblock(host: rule.host) }
                            .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
                .compatInsetList()
            }
            Divider()
            Text("Continuum has no kernel network filter entitlement, so it reports connections that are already established and enforces blocks with pf. It can’t silently drop the very first packet the way a NetworkExtension content filter can.")
                .font(Font.compatCaption2).foregroundColor(.secondary)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func placeholder(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        VStack(spacing: 10) {
            CompatIcon(symbol)
                .font(.system(size: 38, weight: .light))
                .foregroundColor(.secondary)
            Text(text)
                .font(.callout).foregroundColor(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
