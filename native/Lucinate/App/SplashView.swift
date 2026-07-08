import SwiftUI

/// Branded app mark: the router glyph in a rounded, accent-tinted glass tile.
/// Shared by the splash screen (large) and the login header (smaller).
struct BrandMark: View {
    @Environment(\.theme) private var theme

    /// Side length of the rounded glass tile.
    var size: CGFloat = 104

    var body: some View {
        Image(systemName: "wifi.router")
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(theme.accent)
            .frame(width: size, height: size)
            .glassEffect(
                .regular.tint(theme.accent.opacity(0.18)),
                in: .rect(cornerRadius: size * 0.28, style: .continuous)
            )
    }
}

/// Shown while `AppState.bootstrap()` runs. The parent (`RootView`) drives the
/// transition away from this view; the splash only has to look good.
struct SplashView: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hasAppeared = false
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            VStack(spacing: Spacing.lg) {
                BrandMark()
                    .scaleEffect(isPulsing ? 1.05 : 1.0)

                Text("Lucinate")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(theme.textPrimary)
            }
            // Under reduce motion the entrance is a plain fade — no scaling.
            .scaleEffect(reduceMotion || hasAppeared ? 1.0 : 0.86)
            .opacity(hasAppeared ? 1.0 : 0.0)
        }
        .onAppear {
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.3)) {
                    hasAppeared = true
                }
            } else {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) {
                    hasAppeared = true
                }
                withAnimation(
                    .easeInOut(duration: 1.6).repeatForever(autoreverses: true).delay(0.6)
                ) {
                    isPulsing = true
                }
            }
        }
    }
}

#Preview {
    SplashView()
}
