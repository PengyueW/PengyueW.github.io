import SwiftUI

/// Power & Peripherals page: USB-PD negotiation state + log, and the
/// bus-power draw of attached USB / Thunderbolt devices.
struct PowerView: View {
    @EnvironmentObject private var model: HardwareModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                adapterSection
                pdProfilesSection
                logSection
                peripheralSection
            }
            .padding(16)
        }
        .onAppear {
            model.beginObserving()
            model.refreshPeripherals()
        }
        .onDisappear { model.endObserving() }
    }

    private var adapter: AdapterSnapshot { model.adapter }

    // MARK: adapter

    private var adapterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("USB-PD Negotiation").font(.headline)
            if adapter.connected {
                HStack(spacing: 12) {
                    card("Contract",
                         String(format: "%.0f W", adapter.watts),
                         adapter.name.isEmpty ? "Connected charger" : adapter.name,
                         "bolt.fill", .green)
                    card("Voltage",
                         String(format: "%.1f V", adapter.voltage),
                         "Negotiated rail", "powerplug", .blue)
                    card("Current",
                         String(format: "%.2f A", adapter.current),
                         "Negotiated limit", "wave.3.forward", Color.compatTeal)
                    card("Charger Max",
                         String(format: "%.0f W", adapter.maxOfferedWatts),
                         "Highest offered profile", "gauge.high", .purple)
                }
                let intake = model.battery.voltage * max(0, model.battery.amperage)
                Text(String(format:
                    "Battery intake right now: %.1f W of the %.0f W contract.",
                    intake, adapter.watts))
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Text("No charger connected. Plug in a USB-C power adapter to see the negotiated voltage, amperage and wattage.")
                    .font(.callout).foregroundColor(.secondary)
            }
        }
    }

    private func card(_ title: LocalizedStringKey, _ value: String, _ detail: String,
                      _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CompatLabel(title, systemImage: symbol)
                .font(.caption).foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundColor(tint)
            Text(detail).font(Font.compatCaption2).foregroundColor(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .compatFillBackground(cornerRadius: 10, opacity: 0.5)
    }

    @ViewBuilder
    private var pdProfilesSection: some View {
        if !adapter.profiles.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Offered PD Profiles").font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    ForEach(adapter.profiles) { profile in
                        VStack(spacing: 2) {
                            Text(String(format: "%.0f W", profile.maxWatts))
                                .font(.callout.weight(.semibold))
                            Text(String(format: "%.0f V × %.1f A",
                                        profile.maxVoltage, profile.maxCurrent))
                                .font(Font.compatCaption2).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .compatFillBackground(cornerRadius: 7, opacity: 0.5)
                    }
                }
            }
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Negotiation Log").font(.headline)
            if model.adapterLog.isEmpty {
                Text("Connect, disconnect or swap chargers while this page is open and each renegotiation is recorded here.")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.adapterLog) { entry in
                        HStack(alignment: .top) {
                            Text(entry.date.compatFormatted(dateStyle: .none, timeStyle: .medium))
                                .font(.caption.compatMonospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(width: 84, alignment: .leading)
                            Text(entry.message).font(.caption)
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        Divider().padding(.leading, 12)
                    }
                }
                .compatFillBackground(cornerRadius: 8, opacity: 0.4)
            }
        }
    }

    // MARK: peripherals

    private var peripheralSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Peripheral Power Draw").font(.headline)
                Spacer()
                if model.isLoadingPeripherals {
                    CompatProgress().controlSize(.small)
                }
                Button("Refresh") { model.refreshPeripherals() }
                    .disabled(model.isLoadingPeripherals)
            }
            let total = model.peripherals.reduce(0) {
                $0 + $1.currentRequiredMilliAmps + $1.extraOperatingCurrent
            }
            if model.peripherals.isEmpty {
                Text("No bus-powered devices found on USB or Thunderbolt.")
                    .font(.callout).foregroundColor(.secondary)
            } else {
                Text("Total allocated: \(total) mA")
                    .font(.caption).foregroundColor(.secondary)
                VStack(spacing: 0) {
                    ForEach(model.peripherals) { device in
                        HStack {
                            CompatIcon(device.bus == "USB"
                                  ? "cable.connector" : "bolt.horizontal")
                                .foregroundColor(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name).font(.callout)
                                Text(device.vendor.isEmpty ? device.bus
                                     : "\(device.vendor) — \(device.bus)")
                                    .font(Font.compatCaption2).foregroundColor(.secondary)
                            }
                            Spacer()
                            if device.currentRequiredMilliAmps > 0 {
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text("\(device.currentRequiredMilliAmps + device.extraOperatingCurrent) mA")
                                        .font(.callout.weight(.semibold))
                                        .compatMonospacedDigit()
                                    if device.extraOperatingCurrent > 0 {
                                        Text("incl. \(device.extraOperatingCurrent) mA extra")
                                            .font(Font.compatCaption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            } else {
                                Text("self-powered / n.a.")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        Divider().padding(.leading, 12)
                    }
                }
                .compatFillBackground(cornerRadius: 8, opacity: 0.4)
            }
            Text("USB devices report the bus current they requested during enumeration (plus negotiated extra operating current). Thunderbolt devices are listed but don’t expose per-device draw to software.")
                .font(Font.compatCaption2).foregroundColor(.secondary)
        }
    }
}
