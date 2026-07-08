import SwiftUI

/// Per-router dashboard customization (pushed from Settings): which wireless
/// SSIDs and wired interfaces appear on Home, and which interface feeds the
/// throughput hero. Edits auto-save (debounced ~500ms) to UserDefaults under
/// the active router's storage key.
struct DashboardPrefsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    @State private var controller = DashboardController()
    @State private var prefs = DashboardPreferences.defaultPreferences
    @State private var hasLoaded = false
    @State private var isDirty = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        Group {
            if appState.service == nil {
                EmptyStateView(
                    systemImage: "wifi.router",
                    title: "Not Connected",
                    message: "Connect to a router to customize its dashboard."
                )
            } else if controller.isLoading && !controller.hasData {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = controller.error, !controller.hasData {
                ErrorStateView(message: error) {
                    Haptics.impact(.light)
                    Task { await loadData() }
                }
            } else {
                form
            }
        }
        .background(theme.background)
        .navigationTitle("Customize Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .task { await initialLoad() }
        .onDisappear {
            // Flush a pending debounced save so the last edit isn't lost.
            saveTask?.cancel()
            if isDirty { save() }
        }
    }

    // MARK: - Form

    private var form: some View {
        List {
            throughputSection
            if !wirelessOptions.isEmpty {
                wirelessSection
            }
            if !wiredOptions.isEmpty {
                wiredSection
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .foregroundStyle(theme.textPrimary)
        .tint(theme.accent)
    }

    private var throughputSection: some View {
        Section {
            Picker("Source", selection: throughputSelection) {
                Text("All interfaces").tag("")
                ForEach(throughputOptions, id: \.tag) { option in
                    Text(option.label).tag(option.tag)
                }
            }
            .listRowBackground(theme.surface)
        } header: {
            Text("Throughput")
        } footer: {
            Text("Which traffic feeds the dashboard chart. Changes take effect the next time monitoring restarts.")
        }
    }

    private var wirelessSection: some View {
        Section {
            ForEach(wirelessOptions, id: \.id) { option in
                Toggle(isOn: wirelessBinding(id: option.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.network.ssid)
                            .foregroundStyle(theme.textPrimary)
                        Text(option.network.radio)
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .listRowBackground(theme.surface)
            }
        } header: {
            Text("Wireless Networks")
        } footer: {
            Text("When none are selected, all wireless networks are shown.")
        }
    }

    private var wiredSection: some View {
        Section {
            ForEach(wiredOptions, id: \.name) { iface in
                Toggle(isOn: wiredBinding(name: iface.name)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(iface.name)
                            .foregroundStyle(theme.textPrimary)
                        Text(iface.device)
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .listRowBackground(theme.surface)
            }
        } header: {
            Text("Interfaces")
        } footer: {
            Text("When none are selected, all interfaces are shown.")
        }
    }

    // MARK: - Options

    private var wirelessOptions: [(id: String, network: WirelessNetwork)] {
        var seen = Set<String>()
        var options: [(id: String, network: WirelessNetwork)] = []
        for network in controller.wireless where !network.ssid.isEmpty {
            let id = DashboardController.wirelessPreferenceID(for: network)
            if seen.insert(id).inserted {
                options.append((id: id, network: network))
            }
        }
        return options
    }

    private var wiredOptions: [NetworkInterface] {
        var seen = Set<String>()
        var options: [NetworkInterface] = []
        for iface in controller.interfaces {
            let lower = iface.name.lowercased()
            guard lower != "loopback", lower != "lo", !iface.name.isEmpty else { continue }
            if seen.insert(iface.name).inserted {
                options.append(iface)
            }
        }
        return options
    }

    /// Picker options for the throughput source. Wireless entries are
    /// "SSID (kernel device)" so `ThroughputCalculator.device(fromPreference:)`
    /// can extract the device; wired entries store the plain device name.
    private var throughputOptions: [(label: String, tag: String)] {
        var seen = Set<String>()
        var options: [(label: String, tag: String)] = []
        for network in controller.wireless
        where !network.ssid.isEmpty && !network.device.isEmpty {
            let tag = "\(network.ssid) (\(network.device))"
            if seen.insert(tag).inserted {
                options.append((label: tag, tag: tag))
            }
        }
        for iface in wiredOptions {
            let device = iface.device
            guard !device.isEmpty, device != "N/A", seen.insert(device).inserted else {
                continue
            }
            options.append((label: "\(iface.name) (\(device))", tag: device))
        }
        // Keep a stale saved selection representable so the Picker stays
        // consistent when its interface no longer exists.
        if !prefs.showAllThroughput,
            let current = prefs.primaryThroughputInterface,
            !current.isEmpty, !seen.contains(current)
        {
            options.append((label: current, tag: current))
        }
        return options
    }

    // MARK: - Bindings

    private var throughputSelection: Binding<String> {
        Binding(
            get: {
                prefs.showAllThroughput ? "" : (prefs.primaryThroughputInterface ?? "")
            },
            set: { value in
                if value.isEmpty {
                    prefs = prefs.copyWith(
                        primaryThroughputInterface: .some(nil),
                        showAllThroughput: true
                    )
                } else {
                    prefs = prefs.copyWith(
                        primaryThroughputInterface: .some(value),
                        showAllThroughput: false
                    )
                }
                Haptics.selection()
                scheduleSave()
            }
        )
    }

    private func wirelessBinding(id: String) -> Binding<Bool> {
        Binding(
            get: {
                prefs.enabledWirelessInterfaces.isEmpty
                    || prefs.enabledWirelessInterfaces.contains(id)
            },
            set: { isOn in
                let allIDs = Set(wirelessOptions.map(\.id))
                var enabled = prefs.enabledWirelessInterfaces
                if enabled.isEmpty { enabled = allIDs }
                if isOn { enabled.insert(id) } else { enabled.remove(id) }
                // Everything on collapses back to the "show all" default so
                // newly appearing networks stay visible.
                if enabled == allIDs { enabled = [] }
                prefs = prefs.copyWith(enabledWirelessInterfaces: enabled)
                Haptics.selection()
                scheduleSave()
            }
        )
    }

    private func wiredBinding(name: String) -> Binding<Bool> {
        Binding(
            get: {
                prefs.enabledWiredInterfaces.isEmpty
                    || prefs.enabledWiredInterfaces.contains(name)
            },
            set: { isOn in
                let allNames = Set(wiredOptions.map(\.name))
                var enabled = prefs.enabledWiredInterfaces
                if enabled.isEmpty { enabled = allNames }
                if isOn { enabled.insert(name) } else { enabled.remove(name) }
                if enabled == allNames { enabled = [] }
                prefs = prefs.copyWith(enabledWiredInterfaces: enabled)
                Haptics.selection()
                scheduleSave()
            }
        )
    }

    // MARK: - Load / save

    private func initialLoad() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        controller.loadPrefs(routerID: appState.selectedRouterID)
        prefs = controller.prefs
        await loadData()
    }

    private func loadData() async {
        guard let service = appState.service else { return }
        await controller.load(service: service)
    }

    private func scheduleSave() {
        isDirty = true
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(prefs) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        isDirty = false
    }

    private var storageKey: String {
        if let id = appState.selectedRouterID {
            return DashboardPreferences.storageKey(forRouterID: id)
        }
        return DashboardPreferences.globalStorageKey
    }
}
