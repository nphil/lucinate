import SwiftUI

/// Diagnostics hub: entry points to the log viewers and the ping tool, plus
/// a one-tap internet reachability check (2 pings to 1.1.1.1).
struct DiagnosticsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    private enum CheckState: Equatable {
        case idle
        case checking
        case reachable(avgMs: Double?)
        case unreachable
    }

    @State private var checkState: CheckState = .idle

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.sm) {
                NavigationLink {
                    LogViewerView(kind: .system)
                } label: {
                    hubRow(
                        icon: "doc.text",
                        title: "System Log",
                        caption: "Recent logread messages"
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    LogViewerView(kind: .kernel)
                } label: {
                    hubRow(
                        icon: "terminal",
                        title: "Kernel Log",
                        caption: "dmesg ring buffer"
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    PingView()
                } label: {
                    hubRow(
                        icon: "dot.radiowaves.left.and.right",
                        title: "Ping",
                        caption: "Reach a host from the router"
                    )
                }
                .buttonStyle(.plain)

                internetCheckCard
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.sm)
            .padding(.bottom, Spacing.lg)
        }
        .background(theme.background)
        .navigationTitle("Diagnostics")
    }

    // MARK: Rows

    private func hubRow(icon: String, title: String, caption: String) -> some View {
        Card {
            HStack(spacing: Spacing.md) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(theme.accent)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer(minLength: Spacing.sm)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.textSecondary)
            }
            .contentShape(.rect)
        }
    }

    // MARK: Internet check

    private var internetCheckCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.md) {
                    Image(systemName: "globe")
                        .font(.title3)
                        .foregroundStyle(theme.accent)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Internet check")
                            .font(.cardTitle)
                            .foregroundStyle(theme.textPrimary)
                        Text("Pings 1.1.1.1 from the router")
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: Spacing.sm)
                }

                checkResultRow

                Button {
                    Haptics.impact(.light)
                    Task { await runInternetCheck() }
                } label: {
                    if checkState == .checking {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.xs)
                    } else {
                        Text("Check connectivity")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.xs)
                    }
                }
                .buttonStyle(.glassProminent)
                .tint(theme.accent)
                .disabled(checkState == .checking)
            }
        }
    }

    @ViewBuilder
    private var checkResultRow: some View {
        switch checkState {
        case .idle, .checking:
            EmptyView()
        case .reachable(let avgMs):
            HStack(spacing: Spacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.success)
                Text("Internet reachable")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.success)
                if let avgMs {
                    Text(String(format: "· avg %.1f ms", avgMs))
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                }
            }
        case .unreachable:
            HStack(spacing: Spacing.xs) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(theme.error)
                Text("No internet")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.error)
            }
        }
    }

    private func runInternetCheck() async {
        guard let service = appState.service else {
            appState.showToast("Not connected to a router")
            return
        }
        checkState = .checking
        do {
            let result = try await service.fileExec(
                command: "/bin/ping",
                params: ["-c", "2", "-W", "2", "1.1.1.1"]
            )
            let code = result["code"].intValue ?? 1
            if code == 0 {
                let stdout = result["stdout"].stringValue ?? ""
                checkState = .reachable(avgMs: PingOutputParser.averageMs(from: stdout))
                Haptics.success()
            } else {
                checkState = .unreachable
                Haptics.error()
            }
        } catch {
            checkState = .unreachable
            Haptics.error()
        }
    }
}
