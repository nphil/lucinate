import SwiftUI

/// Shimmering placeholder block shown while content loads.
/// Pulses opacity 0.35 -> 0.7; static when Reduce Motion is on.
struct SkeletonBlock: View {
    var height: CGFloat
    var cornerRadius: CGFloat = 8

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(theme.separator)
            .frame(height: height)
            .opacity(pulsing ? 0.7 : 0.35)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
            .accessibilityHidden(true)
    }
}
