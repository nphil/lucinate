import SwiftUI

/// Tailscale management. Phase 2 scaffold; full module lands in Phase 3.
struct TailscaleView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        EmptyStateView(
            systemImage: "lock.shield",
            title: "Tailscale",
            message: "Status, exit nodes, and peers are on the way."
        )
        .background(theme.background)
        .navigationTitle("Tailscale")
    }
}
