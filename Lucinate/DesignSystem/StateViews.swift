import SwiftUI

/// Centered "nothing here" placeholder.
struct EmptyStateView: View {
    var systemImage: String
    var title: String
    var message: String? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(theme.textSecondary)
                .padding(.bottom, Spacing.xs)
            Text(title)
                .font(.cardTitle)
                .foregroundStyle(theme.textPrimary)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(Spacing.xl)
    }
}

/// Centered error placeholder with an optional Retry action.
struct ErrorStateView: View {
    var message: String
    var retry: (() -> Void)? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(theme.warning)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
            if let retry {
                Button("Retry", action: retry)
                    .buttonStyle(.bordered)
                    .tint(theme.accent)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(Spacing.xl)
    }
}
