import SwiftUI

/// Small status indicator circle; `glows` adds a soft halo of the same color.
struct StatusDot: View {
    var color: Color
    var size: CGFloat = 10
    var glows: Bool = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(
                color: glows ? color.opacity(0.6) : .clear,
                radius: glows ? size * 0.5 : 0
            )
            .accessibilityHidden(true)
    }
}
