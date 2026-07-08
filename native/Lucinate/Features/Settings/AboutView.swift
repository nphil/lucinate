import SwiftUI

/// App info screen: mark, version, blurb, repository link, license.
struct AboutView: View {
    @Environment(\.theme) private var theme

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                // App mark
                Image(systemName: "wifi.router")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .frame(width: 96, height: 96)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.card)
                            .fill(theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.card)
                            .strokeBorder(theme.separator, lineWidth: 1)
                    )
                    .accessibilityHidden(true)

                VStack(spacing: Spacing.xs) {
                    Text("Lucinate")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(versionString)
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                }

                Text("Remotely manage your OpenWrt router. Monitor clients, interfaces, and status.")
                    .font(.body)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.lg)

                Link(destination: URL(string: "https://github.com/nphil/lucinate")!) {
                    Label("GitHub Repository", systemImage: "link")
                        .font(.body.weight(.medium))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)
                        .background(
                            Capsule().fill(theme.accent.opacity(0.15))
                        )
                }

                Text("MIT License")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Spacing.xxl)
            .padding(.bottom, Spacing.xl)
            .padding(.horizontal, Spacing.md)
        }
        .background(theme.background)
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
