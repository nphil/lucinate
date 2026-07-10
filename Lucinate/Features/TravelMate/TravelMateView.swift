import SwiftUI

/// TravelMate: master switch, live uplink status, broadcast band/channel
/// controls, and saved uplinks. Mirrors `lib/screens/travelmate_screen.dart`.
struct TravelMateView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    @State private var controller = TravelmateController()
    @State private var showAddSheet = false
    @State private var editingRadio: BroadcastRadio?
    @State private var uplinkToForget: TravelmateUplink?
    @State private var pendingBandDevices: Set<String>?

    var body: some View {
        content
            .background(theme.background)
            .navigationTitle("TravelMate")
            .task(id: appState.selectedRouterID) {
                await loadIfPossible()
            }
            .overlay(alignment: .bottomTrailing) {
                if controller.loaded {
                    addButton
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddUplinkSheet(controller: controller)
            }
            .sheet(item: $editingRadio) { radio in
                BroadcastEditorSheet(controller: controller, radio: radio)
            }
            .alert(
                "Forget Network?",
                isPresented: Binding(
                    get: { uplinkToForget != nil },
                    set: { if !$0 { uplinkToForget = nil } }
                ),
                presenting: uplinkToForget
            ) { uplink in
                Button("Cancel", role: .cancel) {}
                Button("Forget", role: .destructive) {
                    forget(uplink)
                }
            } message: { uplink in
                Text("This removes \"\(uplink.ssid)\" from saved networks.")
            }
            .alert(
                "Apply broadcast change?",
                isPresented: Binding(
                    get: { pendingBandDevices != nil },
                    set: { if !$0 { pendingBandDevices = nil } }
                ),
                presenting: pendingBandDevices
            ) { devices in
                Button("Cancel", role: .cancel) {}
                Button("Continue") {
                    applyBand(devices)
                }
            } message: { _ in
                Text("Devices will briefly disconnect. Continue?")
            }
    }

    // MARK: - Body states

    @ViewBuilder
    private var content: some View {
        if controller.loaded {
            loadedContent
        } else if let error = controller.error {
            ErrorStateView(message: error) {
                Task { await loadIfPossible() }
            }
        } else {
            // First load (or the instant before .task fires): skeletons.
            loadingSkeleton
        }
    }

    private var loadedContent: some View {
        ScrollView {
            VStack(spacing: Spacing.md) {
                masterSwitchCard
                if controller.status.captive {
                    captiveBanner
                }
                statusCard
                if !controller.broadcast.isEmpty {
                    broadcastCard
                }
                savedNetworksSection
                Spacer(minLength: 80)  // clear the floating "+" button
            }
            .padding(Spacing.md)
        }
        .refreshable {
            Haptics.impact(.medium)
            await loadIfPossible()
        }
    }

    private var loadingSkeleton: some View {
        ScrollView {
            VStack(spacing: Spacing.md) {
                Card { SkeletonBlock(height: 28) }
                Card {
                    VStack(spacing: Spacing.sm) {
                        SkeletonBlock(height: 20)
                        SkeletonBlock(height: 20)
                    }
                }
                Card { SkeletonBlock(height: 120) }
                Card {
                    VStack(spacing: Spacing.sm) {
                        SkeletonBlock(height: 20)
                        SkeletonBlock(height: 20)
                        SkeletonBlock(height: 20)
                    }
                }
            }
            .padding(Spacing.md)
        }
        .scrollDisabled(true)
    }

    // MARK: - Master switch

    private var masterSwitchCard: some View {
        Card {
            Toggle(
                isOn: Binding(
                    get: { controller.status.enabled },
                    set: { newValue in
                        Haptics.selection()
                        toggleEnabled(newValue)
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TravelMate")
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    Text("Repeat nearby Wi-Fi as this router's uplink")
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .tint(theme.accent)
            .disabled(controller.isBusy)
        }
    }

    // MARK: - Captive banner

    private var captiveBanner: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "globe")
                .foregroundStyle(theme.warning)
            Text("Captive portal detected — open the portal page to get online.")
                .font(.subheadline)
                .foregroundStyle(theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open") {
                if let url = URL(string: "http://neverssl.com") {
                    openURL(url)
                }
            }
            .buttonStyle(.bordered)
            .tint(theme.warning)
        }
        .padding(Spacing.md)
        .background(
            theme.warning.opacity(0.15),
            in: .rect(cornerRadius: CornerRadius.card, style: .continuous)
        )
    }

    // MARK: - Status

    private var statusCard: some View {
        let status = controller.status
        let connected = status.isConnected
        return Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    StatusDot(
                        color: connected ? theme.success : theme.error,
                        glows: connected
                    )
                    Text(connected ? "Connected to \(status.activeSsid)" : "Not connected")
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                }
                if connected && !status.subnet.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                        Text("Uplink subnet")
                            .font(.subheadline)
                            .foregroundStyle(theme.textSecondary)
                        Text(status.subnet)
                            .font(.monospacedBody)
                            .foregroundStyle(theme.textPrimary)
                    }
                }
            }
        }
    }

    // MARK: - Broadcast

    private var broadcastCard: some View {
        let radios = controller.broadcast
        let enabledRadios = radios.filter(\.apEnabled)
        let has24 = radios.contains { $0.band == 2 }
        let has5 = radios.contains { $0.band == 5 }
        return Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Broadcast Wi-Fi")
                    .font(.cardTitle)
                    .foregroundStyle(theme.textPrimary)
                Text("The Wi-Fi your devices join")
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)

                if has24 && has5 {
                    bandSelector
                }

                ForEach(Array(enabledRadios.enumerated()), id: \.element.id) { index, radio in
                    broadcastIdentityBlock(radio)
                    if index < enabledRadios.count - 1 {
                        Divider().overlay(theme.separator)
                    }
                }

                if !enabledRadios.isEmpty {
                    Text(
                        "Same name on both bands enables automatic band steering. "
                            + "Use different names to force a device onto 2.4 or 5 GHz."
                    )
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.top, Spacing.xs)
                }
            }
        }
    }

    /// One broadcast radio as a tappable identity card: glyph, SSID, and a
    /// band/channel/security caption. Tapping opens the full editor sheet
    /// (name + password + channel).
    private func broadcastIdentityBlock(_ radio: BroadcastRadio) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Button {
                Haptics.selection()
                editingRadio = radio
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "wifi")
                        .foregroundStyle(theme.accent)
                        .frame(width: 36, height: 36)
                        .background(theme.accent.opacity(0.15), in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(radio.ssid.isEmpty ? "Unnamed network" : radio.ssid)
                            .font(.cardTitle)
                            .foregroundStyle(
                                radio.ssid.isEmpty ? theme.textSecondary : theme.textPrimary
                            )
                            .lineLimit(1)
                        Text(identityCaption(radio))
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Spacing.sm)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.textSecondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(controller.isBusy)
            .accessibilityLabel(
                "Edit \(radio.ssid.isEmpty ? "unnamed" : radio.ssid) — \(radio.bandLabel)"
            )

            if radio.uplinkLocked {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                    Text("Channel locked to hotel uplink")
                        .font(.caption2)
                }
                .foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    /// "5 GHz · Ch 40 · WPA2" (plus " · Hidden" for a hidden SSID).
    private func identityCaption(_ radio: BroadcastRadio) -> String {
        var parts: [String] = []
        if !radio.bandLabel.isEmpty { parts.append(radio.bandLabel) }
        parts.append(radio.channel == "auto" ? "Auto" : "Ch \(radio.channel)")
        parts.append(radio.securityLabel)
        if radio.hidden { parts.append("Hidden") }
        return parts.joined(separator: " · ")
    }

    private var bandSelector: some View {
        let enabledRadios = controller.broadcast.filter(\.apEnabled)
        let on24 = enabledRadios.contains { $0.band == 2 }
        let on5 = enabledRadios.contains { $0.band == 5 }
        let selection = (on24 && on5) ? "both" : (on5 ? "5" : "2")
        return HStack(spacing: Spacing.xs) {
            bandSegment("2.4 GHz", value: "2", selection: selection)
            bandSegment("5 GHz", value: "5", selection: selection)
            bandSegment("Both", value: "both", selection: selection)
        }
        .padding(Spacing.xs)
        .background(
            theme.background,
            in: .rect(cornerRadius: CornerRadius.small, style: .continuous)
        )
    }

    private func bandSegment(_ label: String, value: String, selection: String) -> some View {
        let selected = selection == value
        return Button {
            Haptics.selection()
            requestBand(value)
        } label: {
            Text(label)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? theme.accent : theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.sm)
                .background(
                    selected ? theme.accent.opacity(0.15) : .clear,
                    in: .rect(cornerRadius: CornerRadius.small, style: .continuous)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(controller.isBusy)
    }

    private func requestBand(_ selection: String) {
        var devices: Set<String> = []
        for radio in controller.broadcast {
            let match =
                selection == "both"
                || (selection == "2" && radio.band == 2)
                || (selection == "5" && radio.band == 5)
            if match { devices.insert(radio.device) }
        }
        guard !devices.isEmpty else { return }
        pendingBandDevices = devices
    }

    private func applyBand(_ devices: Set<String>) {
        guard let service = appState.service else { return }
        Task {
            let ok = await controller.setBroadcastBand(enabledDevices: devices, service: service)
            if ok {
                Haptics.success()
                appState.showToast("Broadcast updated")
            } else {
                Haptics.warning()
                appState.showToast(controller.error ?? "Action failed")
            }
        }
    }

    // MARK: - Saved networks

    @ViewBuilder
    private var savedNetworksSection: some View {
        Text("Saved networks")
            .font(.cardTitle)
            .foregroundStyle(theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Spacing.xs)

        if controller.uplinks.isEmpty {
            EmptyStateView(
                systemImage: "wifi.slash",
                title: "No saved networks",
                message: "No saved uplinks yet. Tap \"+\" to join one."
            )
        } else {
            if !controller.duplicateUplinkIds.isEmpty {
                Text(
                    "Duplicate saved networks detected — swipe one left "
                        + "(or long-press) to forget the redundant copy."
                )
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(controller.uplinks) { uplink in
                uplinkRow(uplink)
            }
        }
    }

    private func uplinkRow(_ uplink: TravelmateUplink) -> some View {
        // Only the genuinely-connected uplink is "Active" — when several saved
        // uplinks share an SSID (every hotel AP has the same name), the
        // controller disambiguates by the connected radio so we don't badge
        // all of them.
        let active = uplink.sectionId == controller.activeUplinkId
        let isDuplicate = controller.duplicateUplinkIds.contains(uplink.sectionId)
        return Card {
            HStack(spacing: Spacing.sm) {
                Image(systemName: active ? "wifi" : "wifi.slash")
                    .foregroundStyle(active ? theme.success : theme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(uplink.ssid)
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    if !uplink.enabled {
                        Text("disabled")
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                bandChip(controller.deviceLabel(uplink.device))
                if isDuplicate {
                    badge("Duplicate", color: theme.warning)
                }
                Spacer()
                if active {
                    badge("Active", color: theme.success)
                }
            }
        }
        .contentShape(.rect)
        // Swipe left to forget (cards live in a ScrollView, so no List
        // swipeActions — a horizontal-dominant drag stands in for it).
        .highPriorityGesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    guard value.translation.width < -40,
                        abs(value.translation.height) < 30,
                        !controller.isBusy
                    else { return }
                    Haptics.warning()
                    uplinkToForget = uplink
                }
        )
        .contextMenu {
            Button(role: .destructive) {
                uplinkToForget = uplink
            } label: {
                Label("Forget Network", systemImage: "trash")
            }
        }
    }

    private func bandChip(_ label: String) -> some View {
        Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 3)
            .background(theme.separator.opacity(0.5), in: .capsule)
    }

    private func badge(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: .capsule)
    }

    // MARK: - Floating add button

    private var addButton: some View {
        Button {
            Haptics.impact(.light)
            showAddSheet = true
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .frame(width: 56, height: 56)
        }
        .buttonStyle(.glassProminent)
        .clipShape(Circle())
        .disabled(controller.isBusy)
        .padding(.trailing, Spacing.md)
        .padding(.bottom, Spacing.lg)
        .accessibilityLabel("Add network")
    }

    // MARK: - Actions

    private func loadIfPossible() async {
        guard let service = appState.service else { return }
        await controller.load(service: service)
    }

    private func toggleEnabled(_ value: Bool) {
        guard let service = appState.service else { return }
        Task {
            let ok = await controller.setEnabled(value, service: service)
            if ok {
                appState.showToast(value ? "TravelMate enabled" : "TravelMate disabled")
            } else {
                Haptics.warning()
                appState.showToast(controller.error ?? "Action failed")
            }
        }
    }

    private func forget(_ uplink: TravelmateUplink) {
        guard let service = appState.service else { return }
        Task {
            let ok = await controller.deleteUplink(uplink, service: service)
            if ok {
                Haptics.success()
                appState.showToast("Forgot \(uplink.ssid)")
            } else {
                Haptics.warning()
                appState.showToast(controller.error ?? "Action failed")
            }
        }
    }
}
