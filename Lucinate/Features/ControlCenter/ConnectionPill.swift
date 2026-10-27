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

    /// Connected, but the router has stopped answering (Wi-Fi roaming, web
    /// server restarting). Stale rates would mislead, so say so instead.
    private var isReconnecting: Bool {
        isConnected && !appState.linkHealthy
    }

    private var dotColor: Color {
        if appState.isRebooting || isReconnecting { return theme.warning }
        return isConnected ? theme.success : theme.error
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            StatusDot(color: dotColor, glows: true)
            Text(appState.hostname)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: Spacing.sm)

            if isReconnecting {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Reconnecting…")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
            } else {
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
        }
        .padding(.horizontal, Spacing.md)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection status for \(appState.hostname)")
        .accessibilityValue(isReconnecting ? "Reconnecting" : "")
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
