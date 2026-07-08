import SwiftUI

/// The persistent bottom accessory ("Now Playing" analog): hostname, status
/// dot, and live ↓/↑ throughput. Tapping it opens the Control Center sheet.
struct ConnectionPill: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var isConnected: Bool {
        appState.service != nil && !appState.isRebooting
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            StatusDot(
                color: appState.isRebooting
                    ? theme.warning : (isConnected ? theme.success : theme.error),
                glows: true
            )
            Text(appState.hostname)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: Spacing.sm)

            if placement != .inline {
                ThroughputBadge(
                    symbol: "arrow.down",
                    color: theme.success,
                    text: ThroughputCalculator.formatRate(
                        bytesPerSecond: appState.throughput.currentRx)
                )
            }
            ThroughputBadge(
                symbol: "arrow.up",
                color: theme.info,
                text: ThroughputCalculator.formatRate(
                    bytesPerSecond: appState.throughput.currentTx)
            )
        }
        .padding(.horizontal, Spacing.md)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection status for \(appState.hostname)")
    }
}

struct ThroughputBadge: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
            Text(text)
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(theme.textSecondary)
                .contentTransition(.numericText())
                .lineLimit(1)
        }
    }
}
