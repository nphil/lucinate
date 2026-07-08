import SwiftUI
import Observation

// MARK: - Quick radios controller (private to this file)

/// Minimal state behind the "Wi-Fi Radios" quick toggles: every broadcast AP
/// from `uci get wireless`, flipped via `setWirelessSectionDisabled`. Kept
/// deliberately tiny — the full editor lives in the Wi-Fi feature.
@MainActor
@Observable
private final class QuickRadiosController {
    struct APRow: Identifiable, Equatable {
        /// wifi-iface uci section name.
        let section: String
        let ssid: String
        /// "2.4 GHz" / "5 GHz" / "6 GHz" / "" when unknown.
        let bandLabel: String
        var enabled: Bool

        var id: String { section }
    }

    private(set) var radios: [APRow] = []
    private(set) var loaded = false
    private(set) var isBusy = false

    func load(service: RouterService) async {
        guard let wireless = try? await service.uciGet(config: "wireless"),
            let sections = wireless.objectValue
        else { return }

        // wifi-device name -> friendly band label.
        var bandByRadio: [String: String] = [:]
        for (name, section) in sections
        where section[".type"].stringValue == "wifi-device" {
            switch section["band"].coercedString ?? "" {
            case "2g": bandByRadio[name] = "2.4 GHz"
            case "5g": bandByRadio[name] = "5 GHz"
            case "6g": bandByRadio[name] = "6 GHz"
            default: bandByRadio[name] = ""
            }
        }

        // Deterministic order — uci section dictionaries are unordered.
        var rows: [APRow] = []
        for name in sections.keys.sorted() {
            let section = sections[name] ?? .null
            guard section[".type"].stringValue == "wifi-iface",
                section["mode"].coercedString == "ap"
            else { continue }
            let device = section["device"].coercedString ?? ""
            rows.append(
                APRow(
                    section: name,
                    ssid: section["ssid"].coercedString ?? name,
                    bandLabel: bandByRadio[device] ?? "",
                    enabled: (section["disabled"].coercedString ?? "0") != "1"
                ))
        }
        radios = rows
        loaded = true
    }

    /// Optimistically flips the row, then applies. Returns an error message
    /// (after reverting the row) or nil on success.
    func setEnabled(_ enabled: Bool, section: String, service: RouterService)
        async -> String?
    {
        guard let index = radios.firstIndex(where: { $0.section == section })
        else { return nil }
        let previous = radios[index].enabled
        radios[index].enabled = enabled
        isBusy = true
        defer { isBusy = false }
        do {
            try await service.setWirelessSectionDisabled(
                section: section, disabled: !enabled)
            return nil
        } catch {
            if let idx = radios.firstIndex(where: { $0.section == section }) {
                radios[idx].enabled = previous
            }
            return error.localizedDescription
        }
    }
}

// MARK: - Sheet

/// Expanded quick-controls sheet opened from the Connection accessory: the
/// app's Control Center. Connection + throughput summary, per-AP Wi-Fi radio
/// toggles, TravelMate master switch, Tailscale exit-node picker, and reboot.
struct ControlCenterSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReboot) private var requestReboot

    @State private var radiosController = QuickRadiosController()
    @State private var travelmateController = TravelmateController()
    @State private var tailscaleController = TailscaleController()

    /// Set when the user flips an AP off — confirmed via alert before applying.
    @State private var radioToDisable: QuickRadiosController.APRow?

    /// Nothing may mutate while rebooting or disconnected.
    private var mutationsLocked: Bool {
        appState.isRebooting || appState.service == nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.md) {
                    connectionCard
                    throughputCard
                    if radiosController.loaded && !radiosController.radios.isEmpty {
                        radiosCard
                    }
                    if travelmateController.loaded {
                        travelmateCard
                    }
                    if tailscaleController.loaded && !tailscaleController.notInstalled {
                        tailscaleCard
                    }
                    rebootButton
                }
                .padding(Spacing.md)
            }
            .background(theme.background)
            .navigationTitle(appState.hostname)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                guard let service = appState.service else { return }
                await radiosController.load(service: service)
                await travelmateController.load(service: service)
                await tailscaleController.load(service: service)
            }
            .alert(
                "Turn Off Radio?",
                isPresented: Binding(
                    get: { radioToDisable != nil },
                    set: { if !$0 { radioToDisable = nil } }
                ),
                presenting: radioToDisable
            ) { radio in
                Button("Turn Off", role: .destructive) {
                    applyRadio(radio, enabled: false)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Turn off this radio? Devices on it will disconnect.")
            }
        }
    }

    // MARK: Connection + throughput (unchanged summary)

    private var connectionCard: some View {
        Card {
            HStack(spacing: Spacing.md) {
                StatusDot(
                    color: appState.service != nil ? theme.success : theme.error,
                    size: 12, glows: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.service != nil ? "Connected" : "Disconnected")
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    Text(appState.selectedRouter?.ipAddress ?? (appState.isReviewerMode ? "Reviewer Mode" : ""))
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
            }
        }
    }

    private var throughputCard: some View {
        Card {
            HStack(spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Download", systemImage: "arrow.down")
                        .font(.statLabel)
                        .foregroundStyle(theme.success)
                    Text(
                        ThroughputCalculator.formatRate(
                            bytesPerSecond: appState.throughput.currentRx)
                    )
                    .font(.statValue)
                    .foregroundStyle(theme.textPrimary)
                    .contentTransition(.numericText())
                }
                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                    Label("Upload", systemImage: "arrow.up")
                        .font(.statLabel)
                        .foregroundStyle(theme.info)
                    Text(
                        ThroughputCalculator.formatRate(
                            bytesPerSecond: appState.throughput.currentTx)
                    )
                    .font(.statValue)
                    .foregroundStyle(theme.textPrimary)
                    .contentTransition(.numericText())
                }
                Spacer()
            }
        }
    }

    // MARK: Wi-Fi radios

    private var radiosCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                cardHeader(
                    "Wi-Fi Radios", systemImage: "wifi",
                    busy: radiosController.isBusy)
                ForEach(radiosController.radios) { radio in
                    Toggle(isOn: radioBinding(radio)) {
                        HStack(spacing: Spacing.sm) {
                            Text(radio.ssid.isEmpty ? radio.section : radio.ssid)
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                            if !radio.bandLabel.isEmpty {
                                bandChip(radio.bandLabel)
                            }
                        }
                    }
                    .tint(theme.accent)
                    .disabled(mutationsLocked || radiosController.isBusy)
                }
            }
        }
    }

    /// Enabling applies immediately; disabling routes through the confirm alert.
    private func radioBinding(_ radio: QuickRadiosController.APRow) -> Binding<Bool> {
        Binding(
            get: {
                radiosController.radios.first { $0.section == radio.section }?
                    .enabled ?? radio.enabled
            },
            set: { newValue in
                if newValue {
                    applyRadio(radio, enabled: true)
                } else {
                    radioToDisable = radio
                }
            }
        )
    }

    private func applyRadio(_ radio: QuickRadiosController.APRow, enabled: Bool) {
        guard let service = appState.service else { return }
        Haptics.selection()
        Task {
            if let message = await radiosController.setEnabled(
                enabled, section: radio.section, service: service)
            {
                Haptics.error()
                appState.showToast(message)
            }
        }
    }

    // MARK: TravelMate

    private var travelmateCard: some View {
        let status = travelmateController.status
        return Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                cardHeader(
                    "TravelMate", systemImage: "suitcase",
                    busy: travelmateController.isBusy)
                Toggle(isOn: travelmateBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enabled")
                            .foregroundStyle(theme.textPrimary)
                        Text(
                            status.isConnected && !status.activeSsid.isEmpty
                                ? "Connected to \(status.activeSsid)"
                                : "Not connected"
                        )
                        .font(.caption)
                        .foregroundStyle(
                            status.isConnected ? theme.success : theme.textSecondary)
                    }
                }
                .tint(theme.accent)
                .disabled(mutationsLocked || travelmateController.isBusy)
            }
        }
    }

    private var travelmateBinding: Binding<Bool> {
        Binding(
            get: { travelmateController.status.enabled },
            set: { newValue in
                guard let service = appState.service else { return }
                Haptics.selection()
                Task {
                    let ok = await travelmateController.setEnabled(
                        newValue, service: service)
                    if !ok {
                        Haptics.error()
                        appState.showToast(
                            travelmateController.error
                                ?? "Could not update TravelMate")
                    }
                }
            }
        )
    }

    // MARK: Tailscale

    private var tailscaleCard: some View {
        let status = tailscaleController.status
        return Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                cardHeader(
                    "Tailscale", systemImage: "point.3.connected.trianglepath.dotted",
                    busy: tailscaleController.isBusy)
                HStack(spacing: Spacing.sm) {
                    StatusDot(
                        color: status.isRunning
                            ? theme.success
                            : (status.needsLogin ? theme.warning : theme.textSecondary),
                        size: 10, glows: status.isRunning)
                    Text(
                        status.isRunning
                            ? "Connected"
                            : (status.needsLogin ? "Needs Login" : "Disconnected")
                    )
                    .font(.subheadline)
                    .foregroundStyle(theme.textPrimary)
                    Spacer()
                }
                exitNodeMenu
            }
        }
    }

    private var exitNodeMenu: some View {
        let status = tailscaleController.status
        let current = status.currentExitNode
        return Menu {
            Button {
                selectExitNode(nil)
            } label: {
                if current == nil {
                    Label("None", systemImage: "checkmark")
                } else {
                    Text("None")
                }
            }
            ForEach(status.exitNodeCandidates) { peer in
                Button {
                    selectExitNode(peer)
                } label: {
                    if peer.isExitNode {
                        Label(exitNodeTitle(peer), systemImage: "checkmark")
                    } else {
                        Text(exitNodeTitle(peer))
                    }
                }
            }
        } label: {
            HStack(spacing: Spacing.sm) {
                Text("Exit Node")
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text(current.map(exitNodeTitle) ?? "None")
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(theme.textSecondary)
            }
            .contentShape(.rect)
        }
        .disabled(mutationsLocked || tailscaleController.isBusy)
    }

    private func exitNodeTitle(_ peer: TailscalePeer) -> String {
        peer.hostname.isEmpty ? peer.ip : peer.hostname
    }

    private func selectExitNode(_ peer: TailscalePeer?) {
        guard let service = appState.service else { return }
        Haptics.selection()
        Task {
            let ok = await tailscaleController.setExitNode(
                ip: peer?.ip, service: service)
            if !ok {
                Haptics.error()
                appState.showToast(
                    tailscaleController.error ?? "Could not set exit node")
            }
        }
    }

    // MARK: Reboot

    private var rebootButton: some View {
        Button {
            dismiss()
            requestReboot()
        } label: {
            Label("Reboot Router", systemImage: "arrow.clockwise.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(theme.warning)
        .disabled(appState.isRebooting)
    }

    // MARK: Shared bits

    private func cardHeader(_ title: String, systemImage: String, busy: Bool) -> some View {
        HStack(spacing: Spacing.sm) {
            Label(title, systemImage: systemImage)
                .font(.cardTitle)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            if busy {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func bandChip(_ label: String) -> some View {
        Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 3)
            .background(theme.separator.opacity(0.5), in: .capsule)
    }
}
