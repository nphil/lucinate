import SwiftUI

/// Nearby-network picker for adding a new travelmate uplink. Scans on appear,
/// lists results strongest-first, asks for a password when needed. A network
/// that is already saved is badged and reconnects instead of being added again.
struct AddUplinkSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let controller: TravelmateController

    @State private var selectedNetwork: WifiScanResult?
    @State private var password = ""
    @State private var showPasswordPrompt = false
    @State private var showOpenNetworkConfirm = false

    var body: some View {
        NavigationStack {
            content
                .background(theme.background)
                .navigationTitle("Nearby networks")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if controller.isScanning {
                            ProgressView()
                        } else {
                            Button {
                                Haptics.impact(.light)
                                rescan()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .accessibilityLabel("Rescan")
                        }
                    }
                }
        }
        .task {
            // Scan once on appear; keep prior results if a scan is already going.
            if !controller.isScanning {
                rescan()
            }
        }
        .alert(passwordPromptTitle, isPresented: $showPasswordPrompt) {
            SecureField(passwordFieldPlaceholder, text: $password)
            Button("Cancel", role: .cancel) { selectedNetwork = nil }
            Button(passwordConfirmTitle) { connectToSelection() }
        } message: {
            if let note = passwordPromptMessage {
                Text(note)
            }
        }
        .alert(
            "Join \"\(selectedNetwork?.ssid ?? "")\"?",
            isPresented: $showOpenNetworkConfirm
        ) {
            Button("Cancel", role: .cancel) { selectedNetwork = nil }
            Button("Connect") { connectToSelection() }
        } message: {
            Text(openNetworkMessage)
        }
    }

    // MARK: - Selection state

    private var selectedMatch: SavedNetworkMatch {
        selectedNetwork.map { controller.savedMatch(for: $0) } ?? .notSaved
    }

    private var selectedIsSaved: Bool {
        if case .saved = selectedMatch { return true }
        return false
    }

    // A saved network needs no password to reconnect, so its prompt only
    // offers to replace the stored one.
    private var passwordPromptTitle: String {
        let name = selectedNetwork?.ssid ?? ""
        return selectedIsSaved ? "\"\(name)\" is saved" : "Password for \"\(name)\""
    }

    private var passwordFieldPlaceholder: String {
        selectedIsSaved ? "New password (optional)" : "Wi-Fi password"
    }

    private var passwordConfirmTitle: String {
        selectedIsSaved ? "Reconnect" : "Connect"
    }

    private var passwordPromptMessage: String? {
        switch selectedMatch {
        case .saved:
            return "Reconnects with the saved password. Enter a new one only if it has changed."
        case .savedOnOtherRadio(let devices):
            return otherRadioNote(devices)
        case .notSaved:
            return nil
        }
    }

    private var openNetworkMessage: String {
        let base = "This network is open — no password needed."
        if case .savedOnOtherRadio(let devices) = selectedMatch {
            return base + " " + otherRadioNote(devices)
        }
        return base
    }

    /// The same name on the other band is a separate saved network; say so
    /// rather than let it pass for an accidental duplicate.
    private func otherRadioNote(_ devices: [String]) -> String {
        let others = devices.map { controller.deviceLabel($0) }.joined(separator: " and ")
        let here = selectedNetwork?.bandLabel ?? ""
        let entry = here.isEmpty ? "a separate entry" : "a separate \(here) entry"
        return "Also saved for \(others). This adds \(entry)."
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            // Live scan progress: a running count + an indeterminate bar, so
            // the user sees activity and networks appear as they're found
            // (per radio) rather than all at once after an opaque spinner.
            if controller.isScanning {
                VStack(spacing: Spacing.xs) {
                    HStack(spacing: Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text("Scanning… \(controller.scanResults.count) found")
                            .font(.subheadline)
                            .foregroundStyle(theme.textSecondary)
                        Spacer()
                    }
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(theme.accent)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
            }

            if controller.scanResults.isEmpty {
                if controller.isScanning {
                    Spacer()
                    Text("Looking for nearby networks…")
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                } else {
                    EmptyStateView(
                        systemImage: "wifi.slash",
                        title: "No networks found",
                        message: "Tap rescan to scan again."
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List(controller.scanResults) { result in
                    networkRow(result)
                        .listRowBackground(theme.surface)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .animation(.snappy, value: controller.scanResults)
            }
        }
    }

    private func networkRow(_ result: WifiScanResult) -> some View {
        let match = controller.savedMatch(for: result)
        return Button {
            Haptics.selection()
            select(result)
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: result.encrypted ? "lock.fill" : "wifi")
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.ssid)
                        .font(.body)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    if let caption = caption(for: result, match: match) {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                if !result.bandLabel.isEmpty {
                    bandChip(result.bandLabel)
                }
                if case .saved = match {
                    savedBadge
                }
                Spacer()
                Text("\(result.signal) dBm")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.textSecondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(controller.isBusy)
    }

    private func caption(for result: WifiScanResult, match: SavedNetworkMatch) -> String? {
        var parts: [String] = []
        if !result.encrypted { parts.append("open") }
        switch match {
        case .saved(let uplink):
            if !uplink.enabled { parts.append("paused — tap to reconnect") }
        case .savedOnOtherRadio(let devices):
            let others = devices.map { controller.deviceLabel($0) }.joined(separator: ", ")
            parts.append("saved on \(others)")
        case .notSaved:
            break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func bandChip(_ label: String) -> some View {
        Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 3)
            .background(theme.separator.opacity(0.5), in: .capsule)
    }

    private var savedBadge: some View {
        Text("Saved")
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.accent)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 3)
            .background(theme.accent.opacity(0.15), in: .capsule)
    }

    // MARK: - Actions

    private func rescan() {
        guard let service = appState.service else { return }
        Task { await controller.scan(service: service) }
    }

    private func select(_ result: WifiScanResult) {
        selectedNetwork = result
        password = ""
        if result.requiresPassword {
            showPasswordPrompt = true
        } else if case .saved = controller.savedMatch(for: result) {
            // Nothing to ask: reconnect with what is saved.
            connectToSelection()
        } else {
            showOpenNetworkConfirm = true
        }
    }

    private func connectToSelection() {
        guard let network = selectedNetwork, let service = appState.service else { return }
        let saved = selectedIsSaved
        if network.requiresPassword && !saved && password.isEmpty {
            Haptics.warning()
            appState.showToast("Enter the Wi-Fi password.")
            return
        }
        Task {
            // Saving a network that is already saved re-enables it (and
            // replaces the stored password when one was entered).
            let ok = await controller.addUplink(
                ssid: network.ssid,
                password: password,
                device: network.device,
                encryption: network.encryption,
                service: service
            )
            if ok {
                Haptics.success()
                appState.showToast(
                    saved ? "Reconnecting to \(network.ssid)…" : "Connecting to \(network.ssid)…")
                dismiss()
            } else {
                Haptics.warning()
                appState.showToast(controller.error ?? "Action failed")
            }
        }
    }
}
