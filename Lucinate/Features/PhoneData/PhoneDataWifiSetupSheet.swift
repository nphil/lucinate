import SwiftUI

/// Sets the router up to join this iPhone's Personal Hotspot over Wi-Fi. The router does the
/// looking itself (it is the one that has to hear the hotspot), the owner picks their iPhone and
/// types the hotspot's password, and Connect does the rest. Built like `AddUplinkSheet`, which
/// picks any nearby network the same way: scan on appear, strongest first, rescan from the bar.
///
/// Failures show inside the sheet. The app's toasts sit behind a sheet, so they can't carry them.
struct PhoneDataWifiSetupSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 24

    let controller: PhoneDataRouterController
    /// The router already has a Wi-Fi link that no longer matches this iPhone: the same picking
    /// and password, worded as a repair.
    var isFix = false

    /// Kept as picked rather than looked up in the scan: the hotspot drops out of scans when the
    /// iPhone's screen locks, and a rescan that misses it must not lose the choice or the
    /// password already typed.
    @State private var selected: PhoneDataHotspot?
    @State private var password = ""
    @State private var showPassword = false
    @FocusState private var passwordFocused: Bool
    @FocusState private var nameFocused: Bool

    /// The hotspot is typed in rather than picked: the iPhone often can't broadcast it while it
    /// is itself on the router's Wi-Fi, which it has to be to reach the router during setup.
    @State private var isManual = false
    @State private var manualName = ""
    @State private var manualBand = ManualBand.fiveGHz

    /// The band typed-in hotspots are joined on. 5 GHz unless Maximize Compatibility is on.
    private enum ManualBand: CaseIterable, Identifiable {
        case fiveGHz
        case twoPointFourGHz

        var id: Self { self }
        var band: Int { self == .fiveGHz ? 5 : 2 }
        var label: String { Travelmate.bandLabel(for: band) }
    }

    private static let passwordRowID = "hotspot-password"
    private static let nameRowID = "hotspot-name"
    /// Where a field lands when scrolled to: in the upper part of the list, clear of the Connect
    /// bar and of the keyboard.
    private static let fieldAnchor = UnitPoint(x: 0.5, y: 0.3)

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    hintSection
                    hotspotsSection
                    if isManual {
                        manualSection
                    }
                    if let encryption = currentEncryption {
                        passwordSection(encryption: encryption)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .background(theme.background)
                .animation(.snappy, value: controller.hotspots)
                .disabled(controller.isBusy)
                .refreshable { await scan() }
                .safeAreaInset(edge: .bottom, spacing: 0) { connectBar }
                .onChange(of: selected?.rowID) { _, newID in
                    if newID != nil { revealPassword(proxy) }
                }
                .onChange(of: isManual) { _, nowManual in
                    if nowManual { revealName() }
                }
                // The keyboard takes a moment to rise; scrolling before it has would measure
                // against the full-height list and leave the field behind it.
                .onChange(of: passwordFocused) { _, focused in
                    if focused { scroll(proxy, to: Self.passwordRowID, afterKeyboard: true) }
                }
                .onChange(of: nameFocused) { _, focused in
                    if focused { scroll(proxy, to: Self.nameRowID, afterKeyboard: true) }
                }
            }
            .navigationTitle(isFix ? "Fix Wi-Fi" : "Set Up Wi-Fi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        controller.clearActionError()
                        dismiss()
                    }
                    .disabled(controller.isBusy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if controller.isScanning {
                        ProgressView()
                    } else {
                        Button {
                            Haptics.impact(.light)
                            rescan()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Rescan")
                        .disabled(controller.isBusy)
                    }
                }
            }
            // Leaving mid-setup would hide the progress of a run that keeps going.
            .interactiveDismissDisabled(controller.isBusy)
        }
        .task {
            controller.clearActionError()
            // Scan once on appear; keep prior results if a scan is already going.
            if !controller.isScanning {
                rescan()
            }
        }
        .tint(theme.accent)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - What to do on the iPhone

    private struct Step: Identifiable {
        let id: Int
        /// Markdown: the names of things to tap are bold.
        let text: String
    }

    private static let steps = [
        Step(
            id: 1,
            text: "Open **Settings › Personal Hotspot** and turn on **Allow Others to Join**."),
        Step(id: 2, text: "Stay on that screen so the router can find it."),
    ]

    private var hintSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.md) {
                ForEach(Self.steps) { step in
                    PhoneDataInstructionRow(number: step.id, text: step.text)
                }
                HStack(alignment: .top, spacing: Spacing.sm) {
                    Image(systemName: "lightbulb")
                        .font(.footnote)
                        .foregroundStyle(theme.info)
                        .accessibilityHidden(true)
                    Text(
                        LocalizedStringKey(
                            "Can't find it? Turn on **Maximize Compatibility** there, "
                                + "then scan again.")
                    )
                    .font(.footnote)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, Spacing.xs)
            .listRowBackground(theme.surface)
        } header: {
            Text("On your iPhone")
        } footer: {
            if isFix {
                Text(
                    "The router's link to this iPhone needs repair. Pick your hotspot again "
                        + "and enter its password to link them."
                )
            }
        }
    }

    // MARK: - Hotspots the router can hear

    /// The router's scan comes ordered: anything named like an iPhone first, then the strongest
    /// signal. Anyone who renamed their hotspot still finds it further down.
    private var hotspotsSection: some View {
        Section {
            if controller.isScanning {
                scanningRow
            }
            ForEach(controller.hotspots, id: \.rowID) { hotspot in
                hotspotRow(hotspot)
                    .listRowBackground(rowBackground(isSelected: selected?.rowID == hotspot.rowID))
            }
            if controller.hotspots.isEmpty, !controller.isScanning {
                EmptyStateView(
                    systemImage: "wifi.slash",
                    title: "No hotspots found",
                    message: "Turn on Allow Others to Join and keep the Personal Hotspot "
                        + "screen open, then scan again."
                )
                .listRowBackground(theme.surface)
            }
            manualEntryRow
        } header: {
            Text("Choose your iPhone")
        }
    }

    private var scanningRow: some View {
        HStack(spacing: Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text(
                controller.hotspots.isEmpty
                    ? "Looking for your iPhone…" : "Scanning… \(controller.hotspots.count) found"
            )
            .font(.subheadline)
            .foregroundStyle(theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .listRowBackground(theme.surface)
    }

    private func rowBackground(isSelected: Bool) -> some View {
        ZStack {
            theme.surface
            if isSelected {
                theme.accent.opacity(0.18)
            }
        }
    }

    /// One line like the rows of `AddUplinkSheet`; when the name and the details don't fit on
    /// one line (a long name, a large text size) the details drop under the name instead of
    /// squeezing it.
    private func hotspotRow(_ hotspot: PhoneDataHotspot) -> some View {
        let isSelected = selected?.rowID == hotspot.rowID
        return Button {
            select(hotspot)
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.sm) {
                    leadingIcon(hotspot, isSelected: isSelected)
                    Text(hotspot.ssid)
                        .font(.body)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    bandChip(hotspot)
                    Spacer(minLength: Spacing.sm)
                    signalText(hotspot)
                    selectionMark(isSelected)
                }
                HStack(alignment: .top, spacing: Spacing.sm) {
                    leadingIcon(hotspot, isSelected: isSelected)
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(hotspot.ssid)
                            .font(.body)
                            .foregroundStyle(theme.textPrimary)
                        HStack(spacing: Spacing.sm) {
                            bandChip(hotspot)
                            signalText(hotspot)
                        }
                    }
                    Spacer(minLength: 0)
                    selectionMark(isSelected)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hotspot.ssid)
        .accessibilityValue(spokenDetails(hotspot))
        .accessibilityHint("Selects this network")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func leadingIcon(_ hotspot: PhoneDataHotspot, isSelected: Bool) -> some View {
        let phone = hotspot.looksLikeIPhone
        let name: String
        if phone {
            name = "iphone"
        } else {
            name = hotspot.encryption == "none" ? "wifi" : "lock.fill"
        }
        return Image(systemName: name)
            .foregroundStyle(isSelected || phone ? theme.accent : theme.textSecondary)
            .frame(width: iconWidth)
            .accessibilityHidden(true)
    }

    /// The checkmark at the end of the chosen row. Its room is kept on the other rows, so
    /// choosing one doesn't shift the signal readings.
    private func selectionMark(_ isSelected: Bool) -> some View {
        Image(systemName: "checkmark")
            .font(.body.weight(.semibold))
            .foregroundStyle(theme.accent)
            .opacity(isSelected ? 1 : 0)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func bandChip(_ hotspot: PhoneDataHotspot) -> some View {
        if let band = hotspot.band, !band.isEmpty {
            Text(band)
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 3)
                .background(theme.separator.opacity(0.5), in: .capsule)
        }
    }

    @ViewBuilder
    private func signalText(_ hotspot: PhoneDataHotspot) -> some View {
        if let signal = hotspot.signal {
            Text("\(signal) dBm")
                .font(.caption.monospacedDigit())
                .foregroundStyle(theme.textSecondary)
        }
    }

    private func spokenDetails(_ hotspot: PhoneDataHotspot) -> String {
        var parts: [String] = []
        if hotspot.looksLikeIPhone { parts.append("Looks like your iPhone") }
        parts.append(hotspot.encryption == "none" ? "Open network" : "Password protected")
        if let band = hotspot.band, !band.isEmpty { parts.append(band) }
        if let signal = hotspot.signal { parts.append("Signal \(signal) dBm") }
        return parts.joined(separator: ", ")
    }

    // MARK: - A hotspot typed in

    /// The way in when the scan can't list the iPhone: the last row of the list, styled as
    /// chosen once the name is being typed.
    private var manualEntryRow: some View {
        Button {
            selectManual()
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "keyboard")
                    .foregroundStyle(isManual ? theme.accent : theme.textSecondary)
                    .frame(width: iconWidth)
                    .accessibilityHidden(true)
                Text("Not in the list? Enter its name")
                    .font(.subheadline)
                    .foregroundStyle(isManual ? theme.textPrimary : theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.sm)
                selectionMark(isManual)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isManual ? .isSelected : [])
        .listRowBackground(rowBackground(isSelected: isManual))
    }

    /// The hotspot's name and the band it is on, for a hotspot the scan didn't list. The band
    /// picks which of the router's radios joins it.
    private var manualSection: some View {
        Section {
            TextField("iPhone name", text: $manualName)
                .focused($nameFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .onSubmit { passwordFocused = true }
                .foregroundStyle(theme.textPrimary)
                .id(Self.nameRowID)
                .listRowBackground(theme.surface)
            Picker("Band", selection: $manualBand) {
                ForEach(ManualBand.allCases) { band in
                    Text(band.label).tag(band)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(theme.surface)
        } header: {
            Text("Hotspot name")
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Your iPhone's name, from Settings › General › About › Name")
                Text("Pick 2.4 GHz if Maximize Compatibility is on")
                if !controller.radios.isEmpty, controller.radio(forBand: manualBand.band) == nil {
                    Text("This router has no \(manualBand.label) radio.")
                        .foregroundStyle(theme.error)
                }
            }
        }
    }

    // MARK: - The hotspot's password

    private func passwordSection(encryption: String) -> some View {
        Section {
            Group {
                if encryption == "none" {
                    Text("This network is open, so there is no password to enter.")
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                } else {
                    passwordField
                }
            }
            .id(Self.passwordRowID)
            .listRowBackground(theme.surface)
        } header: {
            Text("Hotspot password")
        } footer: {
            passwordFooter(encryption: encryption)
        }
    }

    private var passwordField: some View {
        HStack(spacing: Spacing.sm) {
            Group {
                if showPassword {
                    TextField("Hotspot password", text: $password)
                } else {
                    SecureField("Hotspot password", text: $password)
                }
            }
            .focused($passwordFocused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .onSubmit(connect)
            .foregroundStyle(theme.textPrimary)

            Button {
                showPassword.toggle()
                Haptics.selection()
            } label: {
                Image(systemName: showPassword ? "eye.slash" : "eye")
                    .foregroundStyle(theme.textSecondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(showPassword ? "Hide password" : "Show password")
        }
    }

    @ViewBuilder
    private func passwordFooter(encryption: String) -> some View {
        if let problem = WifiCredentialRules.passphraseProblem(password, encryption: encryption) {
            Text(problem)
                .foregroundStyle(theme.error)
        } else if encryption != "none" {
            Text("You'll find it on your iPhone: Settings › Personal Hotspot › Wi-Fi Password.")
        }
    }

    // MARK: - Connect

    /// The one prominent button, kept at the foot of the sheet so it stays in reach above the
    /// keyboard however far down the list is. While the router works it gives way to progress.
    private var connectBar: some View {
        VStack(spacing: Spacing.sm) {
            if !controller.isBusy, let message = controller.actionError {
                PhoneDataErrorBanner(message: message)
            }
            if controller.isBusy {
                busyRow
            } else {
                connectButton
            }
            if !controller.isBusy, controller.state?.wifiPackagesInstalled == false {
                Text(
                    "The router needs a small add-on first. Lucinate installs it for you, "
                        + "so the router has to be online."
                )
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(theme.background)
    }

    private var connectButton: some View {
        Button(action: connect) {
            Text("Connect")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.xs)
        }
        .buttonStyle(.glassProminent)
        .tint(theme.accent)
        .controlSize(.large)
        .disabled(!canConnect)
    }

    private var busyRow: some View {
        VStack(spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                Text(controller.busyMessage ?? "Connecting…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.textPrimary)
            }
            Text("Keep Lucinate open until this finishes.")
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    /// What the router joins: the network picked from the scan, or the one typed in. A typed-in
    /// hotspot is joined on the radio of the band picked, and as WPA2/WPA3 mixed, which an
    /// iPhone's hotspot accepts whichever of the two it uses. Nil while the name is empty or the
    /// router has no radio on that band.
    private var target: PhoneDataHotspot? {
        guard isManual else { return selected }
        let name = manualName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let radio = controller.radio(forBand: manualBand.band) else {
            return nil
        }
        return PhoneDataHotspot(
            ssid: name, device: radio.device, encryption: Self.manualEncryption, signal: nil,
            band: manualBand.label)
    }

    private static let manualEncryption = "sae-mixed"

    /// The security to ask the password by: shown as soon as a network is chosen or manual entry
    /// starts, before the typed name is complete.
    private var currentEncryption: String? {
        isManual ? Self.manualEncryption : selected?.encryption
    }

    private var needsPassword: Bool {
        currentEncryption.map { $0 != "none" } ?? false
    }

    /// A network is picked (or typed in) and, when it has a password, one the router would
    /// accept.
    private var canConnect: Bool {
        guard let target, !controller.isBusy else { return false }
        guard target.encryption != "none" else { return true }
        return !password.isEmpty
            && WifiCredentialRules.passphraseProblem(password, encryption: target.encryption)
                == nil
    }

    // MARK: - Actions

    private func scan() async {
        guard let service = appState.service else { return }
        await controller.scanForHotspots(service: service)
    }

    private func rescan() {
        Task { await scan() }
    }

    private func select(_ hotspot: PhoneDataHotspot) {
        guard !controller.isBusy else { return }
        Haptics.selection()
        // A password typed for one network is no use for another.
        if selected?.rowID != hotspot.rowID {
            password = ""
        }
        isManual = false
        selected = hotspot
    }

    /// Switches to typing the hotspot's name. Nothing from the list stays chosen, and a password
    /// typed for a listed network is no use here.
    private func selectManual() {
        guard !controller.isBusy, !isManual else { return }
        Haptics.selection()
        password = ""
        selected = nil
        isManual = true
    }

    /// Brings the password into view and, for a secured network, puts the cursor in it; the
    /// focus change then scrolls once the keyboard is up. The row is added by the same update
    /// that picked the network, so both wait for it to lay out.
    private func revealPassword(_ proxy: ScrollViewProxy) {
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            if needsPassword, !passwordFocused {
                passwordFocused = true
            } else {
                scroll(proxy, to: Self.passwordRowID, afterKeyboard: false)
            }
        }
    }

    /// Puts the cursor in the name field once the row is there; the focus change scrolls to it.
    private func revealName() {
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            nameFocused = true
        }
    }

    /// Scrolls so the field with `id` sits in the upper part of the list, fully above the Connect
    /// bar. `afterKeyboard` waits for the keyboard to finish rising, which changes how much of
    /// the list is visible.
    private func scroll(_ proxy: ScrollViewProxy, to id: String, afterKeyboard: Bool) {
        Task {
            if afterKeyboard {
                try? await Task.sleep(for: .milliseconds(350))
            }
            withAnimation(.snappy) {
                proxy.scrollTo(id, anchor: Self.fieldAnchor)
            }
        }
    }

    private func connect() {
        guard canConnect, let hotspot = target, let service = appState.service,
            let routerID = appState.phoneDataRouterID
        else { return }
        passwordFocused = false
        nameFocused = false
        Haptics.impact(.light)
        Task {
            let phone = PhoneDataController.shared
            let ok = await controller.finishWifiSetup(
                service: service, routerID: routerID, phone: phone, hotspot: hotspot,
                password: password)
            if ok {
                phone.wake()
                Haptics.success()
                appState.showToast(isFix ? "Wi-Fi link fixed" : "Wi-Fi sharing is set up")
                dismiss()
            } else {
                // The reason is on screen above the button.
                Haptics.warning()
            }
        }
    }
}

private extension PhoneDataHotspot {
    /// One row per network on one radio, which is how the scan de-duplicates them.
    var rowID: String { "\(device)|\(ssid)" }
}
