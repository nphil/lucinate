import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.colorScheme) private var systemColorScheme

    private var activeTheme: Theme {
        switch themeManager.mode {
        case .system:
            return systemColorScheme == .dark ? themeManager.darkTheme : themeManager.lightTheme
        case .light:
            return themeManager.lightTheme
        case .dark:
            return themeManager.darkTheme
        }
    }

    var body: some View {
        ZStack {
            activeTheme.background.ignoresSafeArea()

            switch appState.phase {
            case .splash:
                SplashView()
                    .transition(.opacity)
            case .login:
                LoginView()
                    .transition(.opacity)
            case .main:
                MainTabView()
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.35), value: appState.phase)
        .overlay(alignment: .bottom) {
            if let toast = appState.toast {
                ToastView(message: toast)
                    .padding(.bottom, 90)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: appState.toast)
        .environment(\.theme, activeTheme)
        .tint(activeTheme.accent)
        // Propagates via environment to every ScrollView/List in the app,
        // including presented sheets (the UIKit appearance proxy does not
        // reach SwiftUI scroll views reliably).
        .scrollIndicators(.hidden)
        .preferredColorScheme(themeManager.preferredColorScheme)
        .task {
            await appState.bootstrap()
        }
    }
}

/// Floating glass toast used for connection/reboot notices.
struct ToastView: View {
    @Environment(\.theme) private var theme
    let message: AppState.ToastMessage

    var body: some View {
        HStack(spacing: Spacing.sm) {
            if message.isPersistent {
                ProgressView()
                    .controlSize(.small)
            }
            Text(message.text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm + 2)
        .glassCapsule()
        .padding(.horizontal, Spacing.lg)
    }
}

#Preview {
    RootView()
        .environment(AppState())
        .environment(ThemeManager())
}
