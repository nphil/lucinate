import SwiftUI

/// Warning card shown wherever a tab wants to tell the owner that the hotel Wi-Fi is waiting for a
/// sign-in. Renders nothing otherwise, so it can be dropped in unconditionally.
struct CaptivePortalBanner: View {
    @Environment(CaptivePortalMonitor.self) private var monitor
    @Environment(\.theme) private var theme

    var body: some View {
        if monitor.needsSignIn {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(theme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hotel Wi-Fi needs sign-in")
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    if let host = monitor.portalHost, !host.isEmpty {
                        Text(host)
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Sign in") {
                    Haptics.impact(.light)
                    monitor.presentSignIn()
                }
                .buttonStyle(.bordered)
                .tint(theme.warning)
                .accessibilityLabel("Sign in to the hotel Wi-Fi")
            }
            .padding(Spacing.md)
            .background(
                theme.warning.opacity(0.15),
                in: .rect(cornerRadius: CornerRadius.card, style: .continuous)
            )
        }
    }
}
