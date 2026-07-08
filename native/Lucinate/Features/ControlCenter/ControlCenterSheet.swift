import SwiftUI

/// Expanded quick-controls sheet opened from the Connection accessory.
/// Phase 2: connection summary + reboot. Quick toggles for radios,
/// TravelMate, and Tailscale land with the feature controllers (Tier A).
struct ControlCenterSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReboot) private var requestReboot

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.md) {
                    connectionCard
                    throughputCard
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
        }
    }

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
}
