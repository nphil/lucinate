import SwiftUI

/// TravelMate management. Phase 2 scaffold; full module lands in Phase 3.
struct TravelMateView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        EmptyStateView(
            systemImage: "airplane",
            title: "TravelMate",
            message: "Uplink management is on the way."
        )
        .background(theme.background)
        .navigationTitle("TravelMate")
    }
}
