import SwiftUI

/// Standard content card: themed surface, continuous rounded corners.
struct Card<Content: View>: View {
    @Environment(\.theme) private var theme
    var padding: CGFloat = Spacing.md
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                theme.surface,
                in: .rect(cornerRadius: CornerRadius.card, style: .continuous)
            )
    }
}

/// Card that sits visually above its surroundings: elevated fill + soft shadow.
struct ElevatedCard<Content: View>: View {
    @Environment(\.theme) private var theme
    var padding: CGFloat = Spacing.md
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                theme.elevated,
                in: .rect(cornerRadius: CornerRadius.card, style: .continuous)
            )
            .shadow(
                color: .black.opacity(theme.isDark ? 0.3 : 0.08),
                radius: 8,
                y: 2
            )
    }
}
