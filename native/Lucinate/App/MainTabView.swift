import SwiftUI

/// The 4-tab shell (Apple Music-style): Home, Network, TravelMate, Tailscale.
/// A Liquid Glass tab bar with a persistent Connection accessory, and the
/// hostname menu (router switcher + Settings) in every navigation bar.
struct MainTabView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    @State private var showSettings = false
    @State private var showControlCenter = false
    @State private var showRebootConfirm = false

    var body: some View {
        @Bindable var state = appState
        TabView(selection: $state.selectedTab) {
            Tab("Home", systemImage: "gauge", value: AppState.MainTab.home) {
                featureStack { HomeView() }
            }
            Tab("Network", systemImage: "network", value: AppState.MainTab.network) {
                featureStack { NetworkView() }
            }
            Tab("TravelMate", systemImage: "airplane", value: AppState.MainTab.travelmate) {
                featureStack { TravelMateView() }
            }
            Tab("Tailscale", systemImage: "lock.shield", value: AppState.MainTab.tailscale) {
                featureStack { TailscaleView() }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            ConnectionPill()
                .onTapGesture {
                    Haptics.impact(.light)
                    showControlCenter = true
                }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showControlCenter) {
            ControlCenterSheet()
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            "Reboot Router?", isPresented: $showRebootConfirm, titleVisibility: .visible
        ) {
            Button("Reboot", role: .destructive) {
                Haptics.warning()
                Task { await appState.reboot() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The router will restart and the connection will be interrupted for a minute or two.")
        }
        .environment(\.requestReboot, RequestRebootAction { showRebootConfirm = true })
        .environment(\.openSettings2, OpenSettingsAction { showSettings = true })
    }

    @ViewBuilder
    private func featureStack<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content()
                .background(theme.background)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        HostnameMenu(
                            openSettings: { showSettings = true },
                            requestReboot: { showRebootConfirm = true }
                        )
                    }
                }
        }
        .disabled(appState.isRebooting)
        .overlay {
            if appState.isRebooting {
                RebootLockoutOverlay()
            }
        }
    }
}

/// Environment plumbing so any feature view can request the reboot flow or
/// open Settings without threading closures through every level.
struct RequestRebootAction: Sendable {
    let run: @MainActor () -> Void
    @MainActor func callAsFunction() { run() }
}

struct OpenSettingsAction: Sendable {
    let run: @MainActor () -> Void
    @MainActor func callAsFunction() { run() }
}

private struct RequestRebootKey: EnvironmentKey {
    static let defaultValue = RequestRebootAction(run: {})
}

private struct OpenSettingsKey: EnvironmentKey {
    static let defaultValue = OpenSettingsAction(run: {})
}

extension EnvironmentValues {
    var requestReboot: RequestRebootAction {
        get { self[RequestRebootKey.self] }
        set { self[RequestRebootKey.self] = newValue }
    }
    var openSettings2: OpenSettingsAction {
        get { self[OpenSettingsKey.self] }
        set { self[OpenSettingsKey.self] = newValue }
    }
}

/// The tappable hostname in the nav bar: router switcher + Settings + Manage
/// Routers + About + Logout. Stays enabled during reboot lockout.
struct HostnameMenu: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var openSettings: () -> Void
    var requestReboot: () -> Void

    @State private var showLogoutConfirm = false

    var body: some View {
        Menu {
            if appState.routers.count > 1 || appState.isReviewerMode {
                Section("Switch Router") {
                    ForEach(appState.routers) { router in
                        Button {
                            Task { await appState.switchRouter(id: router.id) }
                        } label: {
                            if router.id == appState.selectedRouterID {
                                Label(router.displayName, systemImage: "checkmark")
                            } else {
                                Text(router.displayName)
                            }
                        }
                    }
                }
            }
            Section {
                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                Button {
                    requestReboot()
                } label: {
                    Label("Reboot Router", systemImage: "arrow.clockwise.circle")
                }
            }
            Section {
                Button(role: .destructive) {
                    showLogoutConfirm = true
                } label: {
                    Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(appState.hostname)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .confirmationDialog(
            "Log Out?", isPresented: $showLogoutConfirm, titleVisibility: .visible
        ) {
            Button("Log Out", role: .destructive) {
                appState.logout()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears saved credentials and accepted certificates.")
        }
    }
}

/// Shown over tab content while the router reboots (nav stays reachable).
struct RebootLockoutOverlay: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.background.opacity(0.6).ignoresSafeArea()
            VStack(spacing: Spacing.md) {
                ProgressView()
                    .controlSize(.large)
                Text("Rebooting…")
                    .font(.headline)
                    .foregroundStyle(theme.textPrimary)
                Text("Waiting for the router to come back online.")
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(Spacing.xl)
            .background(theme.elevated, in: .rect(cornerRadius: CornerRadius.card, style: .continuous))
        }
        .allowsHitTesting(false)
    }
}
