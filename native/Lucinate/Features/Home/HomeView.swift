import SwiftUI

/// Home dashboard. Phase 2 scaffold: board info + live throughput readout.
/// Phase 3 adds vitals, the hero chart, and wireless/interface cards.
struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.md) {
                Card {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(appState.boardInfo["model"].stringValue ?? "OpenWrt Router")
                            .font(.cardTitle)
                            .foregroundStyle(theme.textPrimary)
                        Text(
                            appState.boardInfo["release"]["description"].stringValue
                                ?? "Loading…"
                        )
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                    }
                }
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
            .padding(Spacing.md)
        }
        .background(theme.background)
        .navigationTitle("Home")
        .refreshable {
            Haptics.impact(.medium)
            await appState.refreshBoardInfo()
        }
        .task {
            await appState.refreshBoardInfo()
        }
    }
}
