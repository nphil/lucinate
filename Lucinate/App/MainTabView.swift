import SwiftUI

/// The 4-tab shell (Apple Music-style): Home, Network, TravelMate, Tailscale.
/// Tab roots run without a navigation bar so content sits flush against the
/// top safe area; the router switcher, Settings, and Reboot all live in the
/// Control Center sheet (opened from the persistent Connection accessory).
struct MainTabView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    @State private var showControlCenter = false
    @State private var showRebootConfirm = false
    /// Watches the router for a hotel sign-in page. Injected below so every tab, and every sheet
    /// presented from here, can show the banner.
    @State private var captivePortal = CaptivePortalMonitor()
    @State private var showCaptiveSheet = false
    /// A sign-in request that came from inside Control Center; it opens once that sheet is gone.
    @State private var captiveSheetPending = false

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
        .sheet(isPresented: $showControlCenter, onDismiss: controlCenterDidDismiss) {
            ControlCenterSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showCaptiveSheet) {
            CaptivePortalSheet()
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
        .environment(captivePortal)
        .onChange(of: captivePortal.signInRequestCount) { openCaptiveSheet() }
        .onChange(of: showControlCenter) {
            if showControlCenter { captivePortal.setAutoPresentationBlocked(true) }
        }
        .task(id: captivePollKey) {
            await captivePortal.run(appState: appState)
        }
    }

    // MARK: - Hotel sign-in

    /// What the monitor's polling depends on. The task restarts whenever any of it changes, which
    /// is also how polling pauses in the background and picks up again on return.
    private struct CaptivePollKey: Hashable, Sendable {
        let routerID: String?
        let isActive: Bool
        let isLive: Bool
    }

    private var captivePollKey: CaptivePollKey {
        CaptivePollKey(
            routerID: appState.selectedRouterID,
            isActive: appState.isAppActive,
            isLive: appState.phase == .main && !appState.isReviewerMode && appState.service != nil)
    }

    /// Two sheets cannot be up together, so a request made from inside Control Center closes it
    /// first and opens the sign-in sheet once it is gone.
    private func openCaptiveSheet() {
        guard !showCaptiveSheet else { return }
        if showControlCenter {
            captiveSheetPending = true
            showControlCenter = false
        } else {
            showCaptiveSheet = true
        }
    }

    private func controlCenterDidDismiss() {
        captivePortal.setAutoPresentationBlocked(false)
        if captiveSheetPending {
            captiveSheetPending = false
            showCaptiveSheet = true
        }
    }

    @ViewBuilder
    private func featureStack<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content()
                .background(theme.background)
                // No nav bar on the tab root: titles are removed and content
                // begins at the top safe area. Pushed screens (Wi-Fi, Leases,
                // …) still get their own bar + back button.
                .toolbar(.hidden, for: .navigationBar)
        }
        .disabled(appState.isRebooting)
        .overlay {
            if appState.isRebooting {
                RebootLockoutOverlay()
            }
        }
    }
}

/// Environment plumbing so the Control Center can request the reboot flow
/// (handled by MainTabView's confirmation dialog).
struct RequestRebootAction: Sendable {
    let run: @MainActor () -> Void
    @MainActor func callAsFunction() { run() }
}

private struct RequestRebootKey: EnvironmentKey {
    static let defaultValue = RequestRebootAction(run: {})
}

extension EnvironmentValues {
    var requestReboot: RequestRebootAction {
        get { self[RequestRebootKey.self] }
        set { self[RequestRebootKey.self] = newValue }
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
