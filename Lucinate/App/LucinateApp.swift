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
        // Phone Data: watches for Personal Hotspot and shares this iPhone's data with a travel router
        // that was set up for it. Does nothing until one has been.
        PhoneDataController.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(themeManager)
        }
    }
}
