import SwiftUI

/// Wi-Fi access-point management: per-AP enable/disable and an editor sheet
/// for SSID/password/visibility plus the carrying radio's channel settings.
/// Pushed from the Network tab.
struct WifiSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    @State private var controller = WifiSettingsController()
    @State private var editorTarget: AccessPoint?
    @State private var pendingDisable: AccessPoint?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.sm) {
                if controller.isLoading {
                    skeletonRows
                } else if let error = controller.error, controller.isEmpty {
                    ErrorStateView(message: error) {
                        Task { await reload() }
                    }
                } else if controller.isEmpty {
                    EmptyStateView(
                        systemImage: "wifi.slash",
                        title: "No access points",
                        message: "This router has no configured Wi-Fi networks."
                    )
                } else {
                    ForEach(bands, id: \.self) { band in
                        sectionHeader(bandTitle(band))
                        ForEach(accessPoints(inBand: band)) { accessPoint in
                            accessPointCard(accessPoint)
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.sm)
            .padding(.bottom, Spacing.xxl)
        }
        .background(theme.background)
        .navigationTitle("Wi-Fi")
        .refreshable {
            Haptics.impact(.medium)
            await reload()
        }
        .task(id: appState.selectedRouterID) {
            await reload()
        }
        .sheet(item: $editorTarget) { accessPoint in
            WifiEditorSheet(
                accessPoint: accessPoint,
                radio: controller.radio(for: accessPoint),
                controller: controller
            )
        }
        .confirmationDialog(
            "Turn Off Network?",
            isPresented: disableConfirmBinding,
            titleVisibility: .visible,
            presenting: pendingDisable
        ) { accessPoint in
            Button("Turn Off", role: .destructive) {
                Haptics.warning()
                Task {
                    await controller.setEnabled(
                        false, section: accessPoint.section, service: appState.service)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Turn off this network? Devices on it will disconnect.")
        }
    }

    private func reload() async {
        await controller.load(service: appState.service)
    }

    // MARK: - Grouping

    /// Distinct bands in display order (access points are pre-sorted by band).
    private var bands: [Int] {
        var seen: [Int] = []
        for accessPoint in controller.accessPoints where !seen.contains(accessPoint.band) {
            seen.append(accessPoint.band)
        }
        return seen
    }

    private func accessPoints(inBand band: Int) -> [AccessPoint] {
        controller.accessPoints.filter { $0.band == band }
    }

    private func bandTitle(_ band: Int) -> String {
        let label = Travelmate.bandLabel(for: band)
        return label.isEmpty ? "Other" : label
    }

    // MARK: - Rows

    private func accessPointCard(_ accessPoint: AccessPoint) -> some View {
        Card {
            HStack(spacing: Spacing.md) {
                Button {
                    Haptics.selection()
                    editorTarget = accessPoint
                } label: {
                    HStack(spacing: Spacing.md) {
                        StatusDot(
                            color: accessPoint.enabled ? theme.success : theme.error,
                            glows: accessPoint.enabled
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Spacing.xs) {
                                Text(displayName(for: accessPoint))
                                    .font(.body.weight(.medium))
                                    .italic(accessPoint.ssid.isEmpty)
                                    .foregroundStyle(
                                        accessPoint.ssid.isEmpty
                                            ? theme.textSecondary : theme.textPrimary
                                    )
                                    .lineLimit(1)
                                if accessPoint.hidden {
                                    Image(systemName: "eye.slash")
                                        .font(.caption)
                                        .foregroundStyle(theme.textSecondary)
                                        .accessibilityLabel("Hidden network")
                                }
                            }
                            Text(subtitle(for: accessPoint))
                                .font(.caption)
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: Spacing.sm)
                        if accessPoint.band > 0 {
                            bandChip(accessPoint.bandLabel)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Edit \(displayName(for: accessPoint))")

                Toggle("", isOn: enabledBinding(for: accessPoint))
                    .labelsHidden()
                    .tint(theme.accent)
                    .disabled(controller.isBusy)
                    .accessibilityLabel("Enable \(displayName(for: accessPoint))")
            }
        }
    }

    private func displayName(for accessPoint: AccessPoint) -> String {
        accessPoint.ssid.isEmpty ? "(hidden SSID)" : accessPoint.ssid
    }

    private func subtitle(for accessPoint: AccessPoint) -> String {
        var parts: [String] = []
        parts.append(
            accessPoint.encryption == "none" ? "Open" : accessPoint.encryption.uppercased())
        if !accessPoint.radio.isEmpty { parts.append(accessPoint.radio) }
        if !accessPoint.network.isEmpty { parts.append(accessPoint.network) }
        return parts.joined(separator: " · ")
    }

    private func bandChip(_ label: String) -> some View {
        Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(theme.accent)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(Capsule().fill(theme.accent.opacity(0.15)))
    }

    private func enabledBinding(for accessPoint: AccessPoint) -> Binding<Bool> {
        Binding(
            get: {
                controller.accessPoints
                    .first { $0.section == accessPoint.section }?
                    .enabled ?? accessPoint.enabled
            },
            set: { newValue in
                if newValue {
                    Haptics.impact(.light)
                    Task {
                        await controller.setEnabled(
                            true, section: accessPoint.section, service: appState.service)
                    }
                } else {
                    // Confirm before cutting devices off.
                    pendingDisable = accessPoint
                }
            }
        )
    }

    // MARK: - Loading / dialog plumbing

    private var skeletonRows: some View {
        ForEach(0..<4, id: \.self) { _ in
            SkeletonBlock(height: 72, cornerRadius: CornerRadius.card)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(theme.textSecondary)
            .padding(.top, Spacing.sm)
            .padding(.horizontal, Spacing.xs)
    }

    private var disableConfirmBinding: Binding<Bool> {
        Binding(
            get: { pendingDisable != nil },
            set: { if !$0 { pendingDisable = nil } }
        )
    }
}

// MARK: - Editor sheet

/// Per-AP editor: SSID, password (only sent when typed), hidden flag, and the
/// carrying radio's channel + channel width.
private struct WifiEditorSheet: View {
    let accessPoint: AccessPoint
    let radio: Radio?
    var controller: WifiSettingsController

    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var ssid: String
    @State private var password = ""
    @State private var showPassword = false
    @State private var hidden: Bool
    @State private var channel: String
    @State private var htmode: String
    @State private var showApplyConfirm = false
    @State private var isSaving = false

    init(accessPoint: AccessPoint, radio: Radio?, controller: WifiSettingsController) {
        self.accessPoint = accessPoint
        self.radio = radio
        self.controller = controller
        _ssid = State(initialValue: accessPoint.ssid)
        _hidden = State(initialValue: accessPoint.hidden)
        let rawChannel = radio?.channel ?? "auto"
        _channel = State(initialValue: rawChannel.isEmpty ? "auto" : rawChannel)
        _htmode = State(initialValue: radio?.htmode ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Network") {
                    TextField("Network Name (SSID)", text: $ssid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .listRowBackground(theme.surface)
                    Toggle("Hidden network", isOn: $hidden)
                        .tint(theme.accent)
                        .listRowBackground(theme.surface)
                        .onChange(of: hidden) { _, _ in
                            Haptics.selection()
                        }
                }

                passwordSection

                if radio != nil {
                    radioSection
                }

                Section {
                    Button {
                        showApplyConfirm = true
                    } label: {
                        Group {
                            if isSaving {
                                ProgressView()
                            } else {
                                Text("Save")
                                    .font(.body.weight(.semibold))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.xs)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(theme.accent)
                    .disabled(!canSave)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .foregroundStyle(theme.textPrimary)
            .navigationTitle(accessPoint.ssid.isEmpty ? "Edit Wi-Fi" : accessPoint.ssid)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .interactiveDismissDisabled(isSaving)
            .alert("Apply Wi-Fi changes?", isPresented: $showApplyConfirm) {
                Button("Apply") {
                    Task { await save() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Devices will briefly disconnect.")
            }
        }
        .tint(theme.accent)
    }

    // MARK: - Sections

    @ViewBuilder
    private var passwordSection: some View {
        if accessPoint.encryption == "none" {
            Section("Password") {
                Text("Open network — no password")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .listRowBackground(theme.surface)
            }
        } else {
            Section {
                HStack(spacing: Spacing.sm) {
                    Group {
                        if showPassword {
                            TextField("Unchanged", text: $password)
                        } else {
                            SecureField("Unchanged", text: $password)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundStyle(theme.textSecondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                }
                .listRowBackground(theme.surface)
            } header: {
                Text("Password")
            } footer: {
                Text("Leave empty to keep the current password.")
            }
        }
    }

    private var radioSection: some View {
        Section("Radio (\(radioTitle))") {
            Picker("Channel", selection: $channel) {
                ForEach(channelOptions, id: \.self) { option in
                    Text(channelLabel(option)).tag(option)
                }
            }
            .listRowBackground(theme.surface)
            Picker("Channel Width", selection: $htmode) {
                ForEach(htmodeOptions, id: \.self) { option in
                    Text(htmodeLabel(option)).tag(option)
                }
            }
            .listRowBackground(theme.surface)
        }
    }

    private var radioTitle: String {
        guard let radio else { return "" }
        let label = radio.bandLabel
        return label.isEmpty ? radio.section : "\(radio.section) · \(label)"
    }

    // MARK: - Options

    private var channelOptions: [String] {
        var options = ["auto"]
        switch radio?.band {
        case 2:
            options += (1...13).map(String.init)
        case 5:
            options += [36, 40, 44, 48, 149, 153, 157, 161].map(String.init)
        default:
            break
        }
        if !options.contains(channel) {
            // Preserve a nonstandard current value so the picker stays valid.
            options.append(channel)
        }
        return options
    }

    private func channelLabel(_ option: String) -> String {
        option == "auto" ? "Auto" : option
    }

    private var htmodeOptions: [String] {
        var options: [String]
        switch radio?.band {
        case 2:
            options = ["HT20", "HT40"]
        default:
            options = ["VHT20", "VHT40", "VHT80", "HE80", "HE160"]
        }
        if !options.contains(htmode) {
            // Include the current value (or "" for unset) so the selection
            // always has a matching tag.
            options.insert(htmode, at: 0)
        }
        return options
    }

    private func htmodeLabel(_ option: String) -> String {
        option.isEmpty ? "Not set" : option
    }

    // MARK: - Change tracking

    private var trimmedSSID: String {
        ssid.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var ifaceChanges: [String: String] {
        var values: [String: String] = [:]
        if !trimmedSSID.isEmpty, trimmedSSID != accessPoint.ssid {
            values["ssid"] = trimmedSSID
        }
        if hidden != accessPoint.hidden {
            values["hidden"] = hidden ? "1" : "0"
        }
        if !password.isEmpty, accessPoint.encryption != "none" {
            values["key"] = password
        }
        return values
    }

    private var radioChanges: [String: String] {
        guard let radio else { return [:] }
        var values: [String: String] = [:]
        let initialChannel = radio.channel.isEmpty ? "auto" : radio.channel
        if channel != initialChannel {
            values["channel"] = channel
        }
        if !htmode.isEmpty, htmode != radio.htmode {
            values["htmode"] = htmode
        }
        return values
    }

    private var hasChanges: Bool {
        !ifaceChanges.isEmpty || !radioChanges.isEmpty
    }

    private var canSave: Bool {
        !trimmedSSID.isEmpty && hasChanges && !isSaving
    }

    // MARK: - Save

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        var ok = true
        let ifaceValues = ifaceChanges
        if !ifaceValues.isEmpty {
            ok = await controller.apply(
                section: accessPoint.section, values: ifaceValues, service: appState.service)
        }
        let radioValues = radioChanges
        if ok, !radioValues.isEmpty, let radio {
            ok = await controller.apply(
                section: radio.section, values: radioValues, service: appState.service)
        }

        if ok {
            Haptics.success()
            appState.showToast("Wi-Fi settings applied")
            dismiss()
        } else {
            Haptics.error()
            appState.showToast(controller.error ?? "Could not apply Wi-Fi settings")
        }
    }
}
