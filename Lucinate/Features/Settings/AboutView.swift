import SwiftUI

/// App info screen: mark, version, blurb, repository link, license.
struct AboutView: View {
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState

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

                routerDetailsCard
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

    // MARK: - Router details

    /// Model/firmware info, shown only when board info is available.
    @ViewBuilder
    private var routerDetailsCard: some View {
        let board = appState.boardInfo
        let candidates: [(label: String, value: String?)] = [
            ("Model", board["model"].stringValue),
            ("Firmware", board["release"]["description"].stringValue),
            ("Kernel", board["kernel"].stringValue),
            ("Board", board["board_name"].stringValue),
        ]
        let rows: [(label: String, value: String)] = candidates.compactMap { candidate in
            guard let value = candidate.value, !value.isEmpty else { return nil }
            return (candidate.label, value)
        }

        if rows.isEmpty {
            EmptyView()
        } else {
            Card {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("ROUTER")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.textSecondary)
                    ForEach(rows, id: \.label) { row in
                        HStack {
                            Text(row.label)
                                .foregroundStyle(theme.textSecondary)
                            Spacer()
                            Text(row.value)
                                .foregroundStyle(theme.textPrimary)
                                .multilineTextAlignment(.trailing)
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
    }
}
