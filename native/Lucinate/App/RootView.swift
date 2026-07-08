import SwiftUI

struct RootView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.router")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Lucinate")
                .font(.largeTitle.bold())
            Text("Native rewrite scaffold")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    RootView()
}
