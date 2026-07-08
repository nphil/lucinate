import SwiftUI

/// Broadcast channel picker for one radio: "Auto" plus the band's standard
/// channels, ranked by the last congestion scan when one exists.
struct ChannelPickerSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let controller: TravelmateController
    let radio: BroadcastRadio

    @State private var pendingChannel: String?

    /// Best-first channel ranking from the last scan; empty without scan data.
    private var suggestions: [Int] {
        controller.suggestedChannels(band: radio.band)
    }

    /// Channels to offer: the ranked suggestions, or the band's standard list
    /// when no scan data exists yet.
    private var channels: [Int] {
        if !suggestions.isEmpty { return suggestions }
        return radio.band == 2 ? [1, 6, 11] : [36, 40, 44, 48, 149, 153, 157, 161]
    }

    private var suggestedSet: Set<Int> {
        Set(suggestions.prefix(3))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    autoRow
                }
                Section("Channels") {
                    ForEach(channels, id: \.self) { channel in
                        channelRow(channel)
                    }
                }
                Section {
                    scanRow
                } footer: {
                    if suggestions.isEmpty {
                        Text("Tap \"Scan for congestion\" to find the least-congested channel.")
                    } else {
                        Text("Channels are ranked least-congested first from the last scan.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle("\(radio.bandLabel) channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .alert(
            "Apply broadcast change?",
            isPresented: Binding(
                get: { pendingChannel != nil },
                set: { if !$0 { pendingChannel = nil } }
            ),
            presenting: pendingChannel
        ) { channel in
            Button("Cancel", role: .cancel) {}
            Button("Apply") { apply(channel) }
        } message: { _ in
            Text("Changing the channel briefly interrupts Wi-Fi.")
        }
    }

    // MARK: - Rows

    private var autoRow: some View {
        Button {
            Haptics.selection()
            pendingChannel = "auto"
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "sparkles")
                    .foregroundStyle(theme.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto (recommended)")
                        .foregroundStyle(theme.textPrimary)
                    Text("Router picks and adapts")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                if radio.channel == "auto" {
                    Image(systemName: "checkmark")
                        .foregroundStyle(theme.accent)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(theme.surface)
        .disabled(controller.isBusy)
    }

    private func channelRow(_ channel: Int) -> some View {
        let isCurrent = radio.channel == String(channel)
        let isBest = suggestions.first == channel
        let isSuggested = !isBest && suggestedSet.contains(channel)
        return Button {
            Haptics.selection()
            pendingChannel = String(channel)
        } label: {
            HStack(spacing: Spacing.sm) {
                Text("Channel \(channel)")
                    .foregroundStyle(theme.textPrimary)
                if isBest {
                    badge("Best", color: theme.success)
                } else if isSuggested {
                    badge("Suggested", color: theme.accent)
                }
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(theme.accent)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(theme.surface)
        .disabled(controller.isBusy)
    }

    private var scanRow: some View {
        Button {
            Haptics.impact(.light)
            scan()
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(theme.accent)
                    .frame(width: 24)
                Text("Scan for congestion")
                    .foregroundStyle(theme.accent)
                Spacer()
                if controller.isScanning {
                    ProgressView()
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(theme.surface)
        .disabled(controller.isScanning || controller.isBusy)
    }

    private func badge(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: .capsule)
    }

    // MARK: - Actions

    private func scan() {
        guard let service = appState.service else { return }
        Task { await controller.scan(service: service) }
    }

    private func apply(_ channel: String) {
        guard let service = appState.service else { return }
        Task {
            let ok = await controller.setChannel(
                device: radio.device, channel: channel, service: service)
            if ok {
                Haptics.success()
                appState.showToast("Channel set to \(channel == "auto" ? "Auto" : channel)")
                dismiss()
            } else {
                Haptics.warning()
                appState.showToast(controller.error ?? "Action failed")
            }
        }
    }
}
