import SwiftUI

@main
struct LucinateApp: App {
    @State private var appState = AppState()
    @State private var themeManager = ThemeManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(themeManager)
        }
    }
}
