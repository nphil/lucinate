import SwiftUI

/// Nearby-network picker for adding a new travelmate uplink. Scans on appear,
/// lists results strongest-first, asks for a password when needed.
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
        .alert(
            "Password for \"\(selectedNetwork?.ssid ?? "")\"",
            isPresented: $showPasswordPrompt
        ) {
            SecureField("Wi-Fi password", text: $password)
            Button("Cancel", role: .cancel) { selectedNetwork = nil }
            Button("Connect") { connectToSelection() }
        }
        .alert(
            "Join \"\(selectedNetwork?.ssid ?? "")\"?",
            isPresented: $showOpenNetworkConfirm
        ) {
            Button("Cancel", role: .cancel) { selectedNetwork = nil }
            Button("Connect") { connectToSelection() }
        } message: {
            Text("This network is open — no password needed.")
        }
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
        Button {
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
                    if !result.encrypted {
                        Text("open")
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                if !result.bandLabel.isEmpty {
                    bandChip(result.bandLabel)
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

    private func bandChip(_ label: String) -> some View {
        Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 3)
            .background(theme.separator.opacity(0.5), in: .capsule)
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
        } else {
            showOpenNetworkConfirm = true
        }
    }

    private func connectToSelection() {
        guard let network = selectedNetwork, let service = appState.service else { return }
        Task {
            let ok = await controller.addUplink(
                ssid: network.ssid,
                password: password,
                device: network.device,
                encryption: network.encryption,
                service: service
            )
            if ok {
                Haptics.success()
                appState.showToast("Connecting to \(network.ssid)…")
                dismiss()
            } else {
                Haptics.warning()
                appState.showToast(controller.error ?? "Action failed")
            }
        }
    }
}
