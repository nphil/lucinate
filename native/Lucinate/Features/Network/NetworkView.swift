import SwiftUI

/// Network hub: Clients | Interfaces. Phase 2 scaffold; the full lists land
/// in Phase 3.
struct NetworkView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        EmptyStateView(
            systemImage: "network",
            title: "Network",
            message: "Clients and interfaces are on the way."
        )
        .background(theme.background)
        .navigationTitle("Network")
    }
}
