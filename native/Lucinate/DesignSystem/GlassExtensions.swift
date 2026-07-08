import SwiftUI

/// Conveniences over the iOS 26 Liquid Glass API.
extension View {
    /// Capsule-shaped glass; pass `interactive: true` for tappable controls.
    func glassCapsule(interactive: Bool = false) -> some View {
        glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
    }

    /// Rounded-rect glass; pass `interactive: true` for tappable controls.
    func glassRect(cornerRadius: CGFloat = 20, interactive: Bool = false) -> some View {
        glassEffect(
            interactive ? .regular.interactive() : .regular,
            in: .rect(cornerRadius: cornerRadius)
        )
    }
}
