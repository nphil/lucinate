import SwiftUI

extension AppState {
    /// Whose Phone Data keys the screens show and set up. Reviewer mode has no saved router, so
    /// its demo router gets a fixed id there.
    var phoneDataRouterID: String? {
        selectedRouterID ?? (isReviewerMode ? "reviewer-demo" : nil)
    }
}

/// Phone Data: use this iPhone's mobile data for the router, over a USB cable or over Wi-Fi.
/// Pushed from the card at the top of the TravelMate tab.
///
/// The status hero is built from the iPhone itself, so it still reads correctly when the router
/// can't be reached. Everything under it is the router's side: the USB cable (the three setup
/// steps until they are done, then one compact card), the Wi-Fi card, how it works and the
/// one-tap shortcut.
struct PhoneDataView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    @State private var controller = PhoneDataRouterController()
    @State private var lastRouterID: String?
    /// This iPhone's own public key, read once per visit; the router's copy is compared with it.
    @State private var phoneKey: String?
    @State private var showShortcutSheet = false
    @State private var showRemoveConfirm = false
    @State private var showKeyResetConfirm = false
    /// Polls in a row where the router saw the iPhone on its USB port but the link wasn't up.
    @State private var unlinkedPolls = 0
    /// Polls in a row where the connect step still hadn't found an iPhone.
    @State private var unseenPolls = 0
    @State private var isRestartingPairing = false
    /// Why the last "Try Again" didn't work, in the router's plain words.
    @State private var pairingError: String?
    /// The Wi-Fi setup sheet: setting up for the first time, or linking again after the router
    /// fell out of step with this iPhone.
    @State private var wifiSheet: WifiSheet?
    @State private var showWifiRemoveConfirm = false
    /// The link being removed right now, so its card shows the progress.
    @State private var removingLink: PhoneDataLink?

    /// The router is asked every 3 s while this screen is up, so plugging in shows live.
    private let pollInterval: Duration = .seconds(3)
    /// Four polls (about 12 s) before "Try Again" is offered.
    private let pairingHelpAfterPolls = 4
    /// Six polls (about 18 s) before the cable hint is shown.
    private let cableHintAfterPolls = 6

    /// A different router, or a return from the background with a re-validated session, both
    /// mean everything shown may be stale.
    private struct LoadTrigger: Equatable, Sendable {
        let routerID: String?
        let resumeCount: Int
    }

    private enum WifiSheet: String, Identifiable {
        case setUp
        case fix

        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.md) {
                if controller.loaded, controller.loadError != nil {
                    refreshNotice
                }
                PhoneDataStatusHero(
                    routerID: appState.phoneDataRouterID, routerState: controller.state)
                if needsKeyReset {
                    keyResetBanner
                } else {
                    routerSection
                }
            }
            .padding(Spacing.md)
            .animation(.smooth, value: controller.loaded)
            .animation(.smooth, value: controller.step)
            .animation(.smooth, value: controller.state?.wifiConfigured)
        }
        // A short screen would not overscroll otherwise, and pull-to-refresh needs the bounce.
        .scrollBounceBehavior(.always, axes: .vertical)
        .background(theme.background)
        .navigationTitle("Phone Data")
        .navigationBarTitleDisplayMode(.inline)
        // Leaving mid-install would hide the progress of a run that keeps going.
        .navigationBarBackButtonHidden(controller.isBusy)
        .refreshable {
            Haptics.impact(.medium)
            PhoneDataController.shared.wake()
            await reload()
        }
        .task(
            id: LoadTrigger(
                routerID: appState.phoneDataRouterID, resumeCount: appState.resumeCount)
        ) {
            if lastRouterID != appState.phoneDataRouterID {
                lastRouterID = appState.phoneDataRouterID
                controller.reset()
                unlinkedPolls = 0
                unseenPolls = 0
                pairingError = nil
            }
            phoneKey = PhoneDataController.shared.publicKey()
            PhoneDataController.shared.wake()
            await reload()
        }
        // Live status only while the screen is up: SwiftUI cancels this when it goes away.
        .task {
            await pollWhileVisible()
        }
        .sheet(isPresented: $showShortcutSheet) {
            PhoneDataShortcutSheet()
        }
        .sheet(item: $wifiSheet, onDismiss: { controller.clearActionError() }) { mode in
            PhoneDataWifiSetupSheet(controller: controller, isFix: mode == .fix)
        }
        .alert("Remove USB setup?", isPresented: $showRemoveConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                remove()
            }
        } message: {
            Text(
                "The router will stop using this iPhone over the USB cable. "
                    + "You can set it up again any time."
            )
        }
        .alert("Remove Wi-Fi setup?", isPresented: $showWifiRemoveConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                removeWifi()
            }
        } message: {
            Text(
                "The router will stop joining this iPhone's hotspot and forget it. "
                    + "You can set it up again any time."
            )
        }
        .alert("Start over with new keys?", isPresented: $showKeyResetConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Start Over", role: .destructive) {
                startOver()
            }
        } message: {
            Text(
                "This iPhone gets new keys, so every router you set up before stops using it "
                    + "until you set it up again."
            )
        }
    }

    // MARK: - Router section

    /// Everything under the hero. Only a definitive answer picks a state: a failed call is an
    /// error (or a notice over the last data), never "not set up".
    @ViewBuilder
    private var routerSection: some View {
        if appState.service == nil {
            EmptyStateView(
                systemImage: "wifi.slash",
                title: "Not connected",
                message: "Connect to a router to set up Phone Data."
            )
        } else if !controller.loaded {
            if let error = controller.loadError {
                unreachableSection(error)
            } else {
                loadingSkeleton
            }
        } else {
            loadedSection
        }
    }

    /// The router didn't answer. While it is using this iPhone's hotspot that is expected (the
    /// iPhone isn't on the router's Wi-Fi then), so it isn't shown as a fault.
    @ViewBuilder
    private func unreachableSection(_ error: String) -> some View {
        if routerIsOnHotspot {
            EmptyStateView(
                systemImage: "iphone.radiowaves.left.and.right",
                title: "Router is on your hotspot",
                message: "While the router uses your iPhone's hotspot, this iPhone can't open "
                    + "its settings. Phone Data keeps working."
            )
        } else {
            ErrorStateView(message: error) {
                Task { await reload() }
            }
        }
    }

    @ViewBuilder
    private var loadedSection: some View {
        if let message = controller.actionError {
            PhoneDataErrorBanner(message: message)
        }
        if needsFix {
            repairBanner
        } else if showsPairingBanner {
            pairingBanner
        }
        usbSection
        if let state = controller.state {
            wifiCard(state)
        }
        if usbIsSetUp || wifiIsSetUp {
            howItWorksCard
            shortcutRow
        }
        if usbIsSetUp {
            tipRow
        }
    }

    /// The USB cable: the three-step checklist until it is done, then one compact card.
    @ViewBuilder
    private var usbSection: some View {
        if usbIsSetUp {
            PhoneDataUSBCard(
                routerID: appState.phoneDataRouterID, routerState: controller.state,
                needsRepair: needsFix, isBusy: controller.isBusy,
                removalMessage: removalMessage(for: .usb)
            ) {
                showRemoveConfirm = true
            }
        } else {
            setupCard
        }
    }

    private func wifiCard(_ state: PhoneDataRouterState) -> some View {
        PhoneDataWifiCard(
            routerState: state, needsRepair: needsWifiRepair,
            isBusy: controller.isBusy, removalMessage: removalMessage(for: .wifi),
            onSetUp: { openWifiSheet(.setUp) },
            onFix: { openWifiSheet(.fix) },
            onRemove: { showWifiRemoveConfirm = true })
    }

    /// What the router is doing, on the card of the link being removed; nil for the other one.
    private func removalMessage(for link: PhoneDataLink) -> String? {
        removingLink == link ? (controller.busyMessage ?? "Removing…") : nil
    }

    private var loadingSkeleton: some View {
        VStack(spacing: Spacing.md) {
            SkeletonBlock(height: 200, cornerRadius: CornerRadius.card)
            SkeletonBlock(height: 120, cornerRadius: CornerRadius.card)
        }
    }

    /// Shown while the last refresh failed; the next poll is already retrying.
    private var refreshNotice: some View {
        HStack(spacing: Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text(
                routerIsOnHotspot
                    ? "The router is on your hotspot, so its settings can't be reached"
                    : "Couldn't reach the router — retrying"
            )
            .font(.footnote)
            .foregroundStyle(theme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(
            theme.warning.opacity(0.12),
            in: .rect(cornerRadius: CornerRadius.small, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Derived state

    /// The iPhone's saved keys can't be read by this version, so nothing works until it starts
    /// over. Reading `status` keeps this in step with the phone: the keys only go bad together
    /// with a problem status.
    private var needsKeyReset: Bool {
        guard case .problem = PhoneDataController.shared.status else { return false }
        return PhoneDataController.shared.needsKeyReset
    }

    /// The USB link is set up, but the router holds one for a different iPhone (or this iPhone
    /// lost its half), so setup has to run again. The router's own step can't tell: it only sees
    /// the router. Before the checklist is done its own button covers this. The Wi-Fi card has
    /// its own Fix.
    private var needsFix: Bool {
        guard controller.loaded, controller.step == .done,
            controller.state?.configured == true,
            let routerID = appState.phoneDataRouterID
        else { return false }
        if !PhoneDataController.shared.hasPeer(for: routerID, link: .usb) { return true }
        guard let phoneKey else { return false }
        return controller.needsRepair(phonePublicKey: phoneKey)
    }

    /// Set up, the router sees the iPhone on USB, yet there has been no link for a while.
    private var showsPairingBanner: Bool {
        guard controller.loaded, controller.step == .done, let state = controller.state else {
            return false
        }
        return state.configured && state.usbDevice != nil && !state.usbLinkUp
            && unlinkedPolls >= pairingHelpAfterPolls
    }

    /// The router holds a Wi-Fi link for a different iPhone (or this iPhone lost its half).
    private var needsWifiRepair: Bool {
        guard controller.loaded, controller.state?.wifiConfigured == true,
            let routerID = appState.phoneDataRouterID
        else { return false }
        if !PhoneDataController.shared.hasPeer(for: routerID, link: .wifi) { return true }
        guard let phoneKey else { return false }
        return controller.needsWifiRepair(phonePublicKey: phoneKey)
    }

    /// The USB cable is complete, so it shows as one compact card.
    private var usbIsSetUp: Bool { controller.step == .done }

    private var wifiIsSetUp: Bool { controller.state?.wifiConfigured == true }

    /// Something to remove: the router has the USB setup. A key the iPhone keeps from an earlier
    /// setup is no reason to offer Remove; setting up again replaces it.
    private var canRemoveUSB: Bool { controller.state?.configured == true }

    /// The router reaches this iPhone over Wi-Fi, so it is on the iPhone's hotspot: it isn't on
    /// a network this iPhone can open its settings from.
    private var routerIsOnHotspot: Bool {
        guard let routerID = appState.phoneDataRouterID else { return false }
        return PhoneDataController.shared.connectedLinks(for: routerID).contains(.wifi)
    }

    /// Which step of the checklist is current: 1...3, or 4 once everything is done.
    private var currentStepNumber: Int {
        switch controller.step {
        case .install: 1
        case .connectPhone: 2
        case .finish: 3
        case .done: 4
        }
    }

    private func mark(forStep number: Int) -> PhoneDataStepMarker.Mark {
        let current = currentStepNumber
        if number < current { return .done }
        return number == current ? .current : .upcoming
    }

    // MARK: - Setup checklist

    private var setupCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm + 2) {
                    PhoneDataIconBadge(systemImage: "cable.connector")
                    Text("USB cable")
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    Spacer(minLength: Spacing.sm)
                    Text("Step \(min(currentStepNumber, 3)) of 3")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(theme.textSecondary)
                }
                installStep
                Divider().overlay(theme.separator)
                connectStep
                Divider().overlay(theme.separator)
                finishStep
                if canRemoveUSB {
                    PhoneDataRemoveRow(
                        title: "Remove USB Setup", workingText: removalMessage(for: .usb),
                        isDisabled: controller.isBusy
                    ) {
                        showRemoveConfirm = true
                    }
                }
            }
        }
    }

    private var installStep: some View {
        let stepMark = mark(forStep: 1)
        return PhoneDataSetupRow(number: 1, title: "Add USB support to the router", mark: stepMark) {
            switch stepMark {
            case .done:
                stepText("Installed")
            case .current:
                stepText(
                    "Lucinate installs a few small add-ons so the router can talk to your iPhone. "
                        + "The router needs to be online.")
                primaryAction("Install", busyFallback: "Installing USB support…") {
                    install()
                }
            case .upcoming:
                EmptyView()
            }
        }
    }

    private var connectStep: some View {
        let stepMark = mark(forStep: 2)
        return PhoneDataSetupRow(number: 2, title: "Connect your iPhone", mark: stepMark) {
            switch stepMark {
            case .done:
                stepText("Found your iPhone. If it asks, tap Trust and enter your passcode.")
                // Setup is not finished yet, so no link is expected; this only covers an
                // iPhone that never showed its Trust prompt.
                if controller.state?.configured != true, unlinkedPolls >= pairingHelpAfterPolls {
                    pairingHelp(message: "No Trust prompt on your iPhone? Unlock it, then try again.")
                }
            case .current:
                // This step is current exactly while the router sees no iPhone on its USB port.
                stepText(
                    "Plug your iPhone into the router's USB port and turn on Personal Hotspot. "
                        + "If it asks, tap Trust and enter your passcode.")
                HStack(spacing: Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Looking for your iPhone…")
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                }
                if unseenPolls >= cableHintAfterPolls {
                    Text("Still nothing? Try another USB port or cable. Some cables only charge.")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
            case .upcoming:
                EmptyView()
            }
        }
    }

    private var finishStep: some View {
        let stepMark = mark(forStep: 3)
        return PhoneDataSetupRow(number: 3, title: "Finish setup", mark: stepMark) {
            switch stepMark {
            case .done:
                stepText("Done")
            case .current:
                stepText("This pairs the router with your iPhone. It only takes a few seconds.")
                primaryAction("Finish", busyFallback: "Setting up the router…") {
                    finishSetup(isFix: false)
                }
            case .upcoming:
                EmptyView()
            }
        }
    }

    private func stepText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The step's one prominent button, or its progress while the router is working.
    @ViewBuilder
    private func primaryAction(
        _ title: String, busyFallback: String, action: @escaping () -> Void
    ) -> some View {
        if controller.isBusy {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text(controller.busyMessage ?? busyFallback)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.textPrimary)
                }
                Text("Keep Lucinate open until this finishes.")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            .accessibilityElement(children: .combine)
        } else {
            Button(action: action) {
                Text(title)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.xs)
            }
            .buttonStyle(.glassProminent)
            .tint(theme.accent)
        }
    }

    /// Help for an iPhone that is plugged in but not connecting, with its one retry.
    private func pairingHelp(message: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
            if let pairingError {
                Text(pairingError)
                    .font(.caption)
                    .foregroundStyle(theme.error)
            }
            tryAgainButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tryAgainButton: some View {
        Button {
            restartPairing()
        } label: {
            if isRestartingPairing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(theme.accent)
        .disabled(isRestartingPairing || controller.isBusy)
    }

    // MARK: - Banners

    private var repairBanner: some View {
        // Fixing re-detects the iPhone on the router's USB port, so it has to be plugged in.
        let plugged = controller.state?.usbDevice != nil
        let advice = plugged ? "Tap Fix to link them again." : "Plug in this iPhone, then tap Fix."
        return attentionBanner(
            title: "USB link needs repair",
            message: "The router was set up with a different iPhone, or the link was lost. "
                + advice,
            footnote: nil,
            button: Label("Fix", systemImage: "arrow.triangle.2.circlepath"),
            isWorking: controller.isBusy,
            workingText: controller.busyMessage ?? "Fixing the link…"
        ) {
            finishSetup(isFix: true)
        }
    }

    private var pairingBanner: some View {
        attentionBanner(
            title: "iPhone not connected yet",
            message: "It's plugged in but hasn't connected. Unlock it and tap Trust if it asks.",
            footnote: pairingError,
            button: Label("Try Again", systemImage: "arrow.clockwise"),
            isWorking: isRestartingPairing,
            workingText: "Restarting the connection…"
        ) {
            restartPairing()
        }
    }

    private var keyResetBanner: some View {
        attentionBanner(
            title: "Start over with new keys",
            message: "You'll set up each router again afterwards.",
            footnote: nil,
            button: Label("Start Over", systemImage: "arrow.counterclockwise"),
            isWorking: false,
            workingText: ""
        ) {
            Haptics.warning()
            showKeyResetConfirm = true
        }
    }

    /// Amber card for things that need the owner: a title, one sentence and one action.
    private func attentionBanner(
        title: String,
        message: String,
        footnote: String?,
        button: Label<Text, Image>,
        isWorking: Bool,
        workingText: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(theme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                    if let footnote {
                        Text(footnote)
                            .font(.caption)
                            .foregroundStyle(theme.error)
                    }
                }
                if isWorking {
                    HStack(spacing: Spacing.sm) {
                        ProgressView()
                            .controlSize(.small)
                        Text(workingText)
                            .font(.subheadline)
                            .foregroundStyle(theme.textSecondary)
                    }
                } else {
                    Button(action: action) {
                        button
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(theme.warning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.md)
        .background(
            theme.warning.opacity(0.15),
            in: .rect(cornerRadius: CornerRadius.card, style: .continuous)
        )
    }

    // MARK: - After setup

    private var howItWorksCard: some View {
        let facts = howItWorksFacts
        return Card {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("How it works")
                    .font(.cardTitle)
                    .foregroundStyle(theme.textPrimary)
                PhoneDataFactRow(systemImage: facts.onSymbol, text: facts.on)
                PhoneDataFactRow(systemImage: "wifi", text: facts.off)
                PhoneDataFactRow(
                    systemImage: "iphone",
                    text: "Keep Lucinate installed; it runs quietly in the background while sharing."
                )
            }
        }
    }

    private struct HowItWorks {
        let onSymbol: String
        let on: String
        let off: String
    }

    /// What switches the router over to the iPhone depends on how it was set up.
    private var howItWorksFacts: HowItWorks {
        switch (usbIsSetUp, wifiIsSetUp) {
        case (true, true):
            HowItWorks(
                onSymbol: "iphone.radiowaves.left.and.right",
                on: "Plugged in or Hotspot on: the router uses this iPhone's data.",
                off: "Unplugged and Hotspot off: it goes back to hotel Wi-Fi.")
        case (false, true):
            HowItWorks(
                onSymbol: "iphone.radiowaves.left.and.right",
                on: "Hotspot on: the router joins it and uses this iPhone's data.",
                off: "Hotspot off: it goes back to hotel Wi-Fi.")
        default:
            HowItWorks(
                onSymbol: "cable.connector",
                on: "Plugged in, Hotspot on: the router uses this iPhone's data.",
                off: "Unplugged: it goes back to hotel Wi-Fi.")
        }
    }

    private var shortcutRow: some View {
        Button {
            Haptics.selection()
            showShortcutSheet = true
        } label: {
            Card {
                HStack(spacing: Spacing.sm + 2) {
                    PhoneDataIconBadge(systemImage: "bolt.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Make it one tap")
                            .font(.cardTitle)
                            .foregroundStyle(theme.textPrimary)
                        Text("Turn on Personal Hotspot and Phone Data with one shortcut.")
                            .font(.subheadline)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows how to make a shortcut")
    }

    private var tipRow: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "lightbulb")
                .font(.footnote)
                .foregroundStyle(theme.info)
                .accessibilityHidden(true)
            Text(
                "Unlock your iPhone when you plug it in. It stays connected after it locks. "
                    + "If it won't connect, check Settings › Privacy & Security › Wired Accessories."
            )
            .font(.footnote)
            .foregroundStyle(theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.md)
        .background(
            theme.info.opacity(0.12),
            in: .rect(cornerRadius: CornerRadius.card, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    private func reload() async {
        guard let service = appState.service else { return }
        await controller.load(service: service)
        phoneKey = PhoneDataController.shared.publicKey()
        // A load that was skipped because an action is running says nothing new.
        if !controller.isBusy { trackLink() }
    }

    /// Counts consecutive polls with the same trouble, so help only shows when it lasts.
    private func trackLink() {
        guard controller.loaded, let state = controller.state else { return }
        unlinkedPolls = (state.usbDevice != nil && !state.usbLinkUp) ? unlinkedPolls + 1 : 0
        unseenPolls = controller.step == .connectPhone ? unseenPolls + 1 : 0
    }

    private func pollWhileVisible() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: pollInterval)
            // The Wi-Fi sheet makes the router scan; nothing behind it is in view anyway.
            guard !Task.isCancelled, appState.isAppActive, !controller.isBusy,
                appState.service != nil, wifiSheet == nil
            else { continue }
            await reload()
        }
    }

    private func install() {
        guard let service = appState.service else { return }
        Haptics.impact(.light)
        Task {
            let ok = await controller.installPackages(service: service)
            if ok {
                Haptics.success()
                appState.showToast("USB support installed")
            } else {
                Haptics.warning()
                appState.showToast("Couldn't install USB support")
            }
            trackLink()
        }
    }

    /// Finish setup, and also the fix for a link that points at another iPhone: the router
    /// side re-detects the iPhone and writes the link again either way.
    private func finishSetup(isFix: Bool) {
        guard let service = appState.service, let routerID = appState.phoneDataRouterID else {
            return
        }
        Haptics.impact(.light)
        Task {
            let phone = PhoneDataController.shared
            let ok = await controller.finishSetup(
                service: service, routerID: routerID, phone: phone)
            if ok {
                phone.wake()
                unlinkedPolls = 0
                pairingError = nil
                Haptics.success()
                appState.showToast(
                    isFix ? "Fixed. The router uses this iPhone again." : "USB sharing is set up")
            } else {
                Haptics.warning()
                appState.showToast(isFix ? "Couldn't fix the link" : "Couldn't finish setup")
            }
            trackLink()
        }
    }

    private func remove() {
        guard let service = appState.service, let routerID = appState.phoneDataRouterID else {
            return
        }
        removingLink = .usb
        Task {
            defer { removingLink = nil }
            let ok = await controller.remove(
                service: service, routerID: routerID, phone: PhoneDataController.shared)
            if ok {
                unlinkedPolls = 0
                unseenPolls = 0
                pairingError = nil
                Haptics.success()
                appState.showToast("USB setup removed")
            } else {
                Haptics.warning()
                appState.showToast("Couldn't remove USB setup")
            }
        }
    }

    private func removeWifi() {
        guard let service = appState.service, let routerID = appState.phoneDataRouterID else {
            return
        }
        removingLink = .wifi
        Task {
            defer { removingLink = nil }
            let ok = await controller.removeWifi(
                service: service, routerID: routerID, phone: PhoneDataController.shared)
            if ok {
                Haptics.success()
                appState.showToast("Wi-Fi setup removed")
            } else {
                Haptics.warning()
                appState.showToast("Couldn't remove Wi-Fi setup")
            }
        }
    }

    /// Opens the Wi-Fi sheet with a clean slate: an error left by an earlier action isn't about
    /// what the sheet is about to do.
    private func openWifiSheet(_ mode: WifiSheet) {
        controller.clearActionError()
        wifiSheet = mode
    }

    /// Gives up on the iPhone's unreadable keys for new ones. The routers set up before have to
    /// be set up again, which the router side notices as a link that needs repair.
    private func startOver() {
        let phone = PhoneDataController.shared
        phone.resetKeys()
        phoneKey = phone.publicKey()
        if phone.needsKeyReset {
            Haptics.warning()
            appState.showToast("Couldn't start over. Try again.")
        } else {
            Haptics.success()
            appState.showToast("Started over with new keys")
        }
    }

    /// Restarts the router's pairing service, which makes the iPhone ask for trust again.
    private func restartPairing() {
        guard let service = appState.service, !isRestartingPairing else { return }
        Haptics.impact(.light)
        isRestartingPairing = true
        pairingError = nil
        Task {
            defer { isRestartingPairing = false }
            do {
                try await service.restartIPhonePairing()
                unlinkedPolls = 0
                PhoneDataController.shared.wake()
                appState.showToast("Trying again. Check your iPhone.")
            } catch {
                Haptics.warning()
                pairingError = error.localizedDescription
            }
        }
    }
}

// MARK: - Status hero

/// The big status card. It reads the iPhone's live numbers itself, isolated here so the
/// one-second tick only re-renders this card and not the whole screen.
private struct PhoneDataStatusHero: View {
    let routerID: String?
    /// Nil until the router has answered; the card works without it.
    let routerState: PhoneDataRouterState?

    @Environment(\.theme) private var theme

    var body: some View {
        let phone = PhoneDataController.shared
        let presentation = PhoneDataPresentation.current(phone: phone, routerID: routerID)
        ElevatedCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                header(presentation)
                if presentation.isSharing {
                    speeds(phone)
                }
                details(presentation, phone: phone)
            }
        }
        .animation(.smooth, value: presentation)
    }

    // MARK: Header

    private func header(_ presentation: PhoneDataPresentation) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                if presentation == .waitingForRouter {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    StatusDot(
                        color: presentation.color(in: theme), size: 12,
                        glows: presentation.isSharing)
                }
                Text(presentation.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(theme.textPrimary)
            }
            Text(presentation.detail(routerSeesPhone: routerState?.usbDevice != nil))
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Live speeds

    /// Side by side, or stacked when the text size leaves no room.
    private func speeds(_ phone: PhoneDataController) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Spacing.lg) {
                stat(
                    label: "Download", systemImage: "arrow.down",
                    bits: phone.downBitsPerSecond, color: theme.success)
                stat(
                    label: "Upload", systemImage: "arrow.up",
                    bits: phone.upBitsPerSecond, color: theme.info)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: Spacing.md) {
                stat(
                    label: "Download", systemImage: "arrow.down",
                    bits: phone.downBitsPerSecond, color: theme.success)
                stat(
                    label: "Upload", systemImage: "arrow.up",
                    bits: phone.upBitsPerSecond, color: theme.info)
            }
        }
    }

    private func stat(label: String, systemImage: String, bits: Double, color: Color)
        -> some View
    {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: systemImage)
                .font(.statLabel)
                .foregroundStyle(color)
            Text(PhoneDataFormat.rate(bitsPerSecond: bits))
                .font(.statValue)
                .foregroundStyle(theme.textPrimary)
                .contentTransition(.numericText())
                .animation(.default, value: bits)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) speed")
        .accessibilityValue(PhoneDataFormat.spokenRate(bitsPerSecond: bits))
    }

    // MARK: Source and data used

    private struct Source {
        let text: String
        let color: Color
    }

    /// Which uplink the router is on. Unknown (nil) until the router has answered, rather than
    /// a guess; "Wi-Fi" is its own TravelMate uplink, the fallback whenever the iPhone isn't in.
    private func routerSource(_ presentation: PhoneDataPresentation) -> Source? {
        switch presentation {
        case .notSetUp:
            return nil
        case .sharing:
            return Source(text: "iPhone data", color: theme.success)
        case .waitingForPhone, .waitingForRouter, .problem:
            guard let routerState else { return nil }
            // Whichever tunnel is up or on its way, the router is reaching for the iPhone; the
            // hotel Wi-Fi is what it falls back to.
            let reachingIPhone =
                routerState.tunnelUp || routerState.wifiTunnelUp || routerState.wifiUplinkActive
            return Source(
                text: reachingIPhone ? "Connecting to iPhone…" : "Wi-Fi",
                color: theme.textPrimary)
        }
    }

    @ViewBuilder
    private func details(_ presentation: PhoneDataPresentation, phone: PhoneDataController)
        -> some View
    {
        let source = routerSource(presentation)
        let used = Double(phone.traffic.bytesDown) + Double(phone.traffic.bytesUp)
        if source != nil || used > 0 {
            Divider().overlay(theme.separator)
            VStack(spacing: Spacing.sm) {
                if let source {
                    infoRow("Router is using", value: source.text, color: source.color)
                }
                if used > 0 {
                    infoRow(
                        "Data used", value: Format.bytes(used), color: theme.textPrimary,
                        caption: "Since Lucinate opened")
                }
            }
        }
    }

    private func infoRow(_ label: String, value: String, color: Color, caption: String? = nil)
        -> some View
    {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                if let caption {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            Spacer(minLength: Spacing.sm)
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rows

/// One step of the setup checklist: a marker and the step's name, then, for the current or a
/// finished step, whatever it has to say (text, progress, its one button).
private struct PhoneDataSetupRow<Content: View>: View {
    let number: Int
    let title: String
    let mark: PhoneDataStepMarker.Mark
    @ViewBuilder var content: Content

    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .subheadline) private var markerSize: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                PhoneDataStepMarker(number: number, mark: mark, size: markerSize)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(mark == .upcoming ? theme.textSecondary : theme.textPrimary)
                    .frame(minHeight: markerSize, alignment: .leading)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(number): \(title)")
            .accessibilityValue(mark.spokenValue)

            if mark != .upcoming {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    content
                }
                .padding(.leading, markerSize + Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// An icon and one sentence, for the short "how it works" list.
private struct PhoneDataFactRow: View {
    let systemImage: String
    let text: String

    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth: CGFloat = 24

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(theme.accent)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
