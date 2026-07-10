import SwiftUI
import UIKit

@main
struct LucinateApp: App {
    @State private var appState = AppState()
    @State private var themeManager = ThemeManager()

    init() {
        // The user prefers no scroll indicators anywhere; hide them app-wide
        // (covers every ScrollView / List / Form, which are UIScrollView-backed).
        UIScrollView.appearance().showsVerticalScrollIndicator = false
        UIScrollView.appearance().showsHorizontalScrollIndicator = false
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(themeManager)
        }
    }
}
