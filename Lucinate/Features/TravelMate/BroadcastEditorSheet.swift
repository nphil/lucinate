import SwiftUI

/// One editor for a broadcast radio's identity: network name, password, and
/// channel in a single sheet. Opened from the Broadcast Wi-Fi card's per-band
/// identity blocks. Password is write-only ("Unchanged" until typed); channel
/// selection is disabled when the radio is locked to the hotel uplink.
struct BroadcastEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let controller: TravelmateController
    let radio: BroadcastRadio

    @State private var name: String
    @State private var password = ""
    @State private var showPassword = false
    @State private var channel: String
    @State private var showApplyConfirm = false

    init(controller: TravelmateController, radio: BroadcastRadio) {
        self.controller = controller
        self.radio = radio
        _name = State(initialValue: radio.ssid)
        _channel = State(initialValue: radio.channel.isEmpty ? "auto" : radio.channel)
    }

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                securitySection
                channelSection
            }
            .disabled(controller.isBusy)
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .foregroundStyle(theme.textPrimary)
            .navigationTitle("\(radio.bandLabel) Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(controller.isBusy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if controller.isBusy {
                        ProgressView()
                    } else {
                        Button("Save") { showApplyConfirm = true }
                            .disabled(!canSave)
                    }
                }
            }
            .interactiveDismissDisabled(controller.isBusy)
            .alert("Apply Wi-Fi changes?", isPresented: $showApplyConfirm) {
                Button("Apply") {
                    Task { await save() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Devices on this network will briefly disconnect.")
            }
        }
        .tint(theme.accent)
    }

    // MARK: - Sections

    private var nameSection: some View {
        Section {
            TextField("Network name", text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .listRowBackground(theme.surface)
        } header: {
            Text("Network")
        } footer: {
            Text(
                "Using the same name on both bands lets devices switch bands "
                    + "automatically (band steering)."
            )
        }
    }

    /// True when the AP currently has no password set.
    private var isOpenNetwork: Bool { radio.encryption == "none" }

    private var securitySection: some View {
        Section {
            HStack(spacing: Spacing.sm) {
                Group {
                    if showPassword {
                        TextField(isOpenNetwork ? "Set a password" : "Unchanged", text: $password)
                    } else {
                        SecureField(isOpenNetwork ? "Set a password" : "Unchanged", text: $password)
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
            Text("Security")
        } footer: {
            Text(
                isOpenNetwork
                    ? "This network is currently open. Setting a password secures it with WPA2/WPA3. Minimum 8 characters."
                    : "Leave blank to keep the current password. Minimum 8 characters."
            )
        }
    }

    @ViewBuilder
    private var channelSection: some View {
        if radio.uplinkLocked {
            Section {
                LabeledContent("Channel") {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                        Text(radio.channel == "auto" ? "Auto" : radio.channel)
                    }
                    .foregroundStyle(theme.textSecondary)
                }
                .listRowBackground(theme.surface)
            } header: {
                Text("Channel")
            } footer: {
                Text(
                    "This radio is repeating the hotel network, "
                        + "so its channel follows the uplink."
                )
            }
        } else {
            Section("Channel") {
                Picker("Channel", selection: $channel) {
                    ForEach(channelOptions, id: \.self) { option in
                        Text(option == "auto" ? "Auto" : option).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .listRowBackground(theme.surface)
            }
        }
    }

    // MARK: - Options

    private var channelOptions: [String] {
        var options = ["auto"]
        switch radio.band {
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

    // MARK: - Change tracking

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameChanged: Bool {
        trimmedName != radio.ssid
    }

    private var passwordChanged: Bool {
        !password.isEmpty
    }

    private var channelChanged: Bool {
        !radio.uplinkLocked && channel != (radio.channel.isEmpty ? "auto" : radio.channel)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty
            && (nameChanged || passwordChanged || channelChanged)
            && !controller.isBusy
    }

    // MARK: - Save

    private func save() async {
        guard let service = appState.service else { return }

        var ok = true
        if nameChanged || passwordChanged {
            ok = await controller.updateBroadcast(
                section: radio.apSection,
                ssid: trimmedName,
                password: password.isEmpty ? nil : password,
                hidden: nil,
                // Securing a previously-open network: WPA2/WPA3 mixed for
                // broad device compatibility.
                encryption: (isOpenNetwork && !password.isEmpty) ? "sae-mixed" : nil,
                service: service
            )
        }
        if ok, channelChanged {
            ok = await controller.setChannel(
                device: radio.device, channel: channel, service: service)
        }

        if ok {
            Haptics.success()
            appState.showToast("\(radio.bandLabel) Wi-Fi updated")
            dismiss()
        } else {
            Haptics.error()
            appState.showToast(controller.error ?? "Couldn't update Wi-Fi")
        }
    }
}
