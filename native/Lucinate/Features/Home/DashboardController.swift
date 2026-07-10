import Foundation
import Observation

/// Loads and holds the Home dashboard data: system vitals, wireless networks,
/// logical interfaces, and the per-router display preferences.
///
/// Cached-first: `isLoading` is only true while the very first load is in
/// flight; later reloads keep showing the existing data.
@MainActor
@Observable
final class DashboardController {
    // MARK: - Data

    private(set) var systemInfo: JSONValue = .null
    private(set) var wireless: [WirelessNetwork] = []
    private(set) var interfaces: [NetworkInterface] = []
    private(set) var prefs: DashboardPreferences = .defaultPreferences

    private(set) var isLoading = false
    private(set) var error: String?

    var hasData: Bool {
        !systemInfo.isNull || !wireless.isEmpty || !interfaces.isEmpty
    }

    /// SSID of the active repeated uplink (the STA interface), if any.
    var uplinkSSID: String? {
        wireless.first { $0.mode == "sta" && !$0.ssid.isEmpty }?.ssid
    }

    // MARK: - Loading

    func load(service: RouterService) async {
        if !hasData { isLoading = true }
        defer { isLoading = false }

        async let systemCall = service.systemInfo()
        async let wirelessCall = service.wirelessDevices()
        async let dumpCall = service.interfaceDump()

        var failure: String?

        do {
            systemInfo = try await systemCall
        } catch {
            failure = error.localizedDescription
        }

        do {
            wireless = WirelessNetwork.fromWirelessDevices(try await wirelessCall)
        } catch let ubusError as UbusError where ubusError.isUnavailableObject {
            // Wired-only router: no wireless subsystem. Not an error.
            wireless = []
        } catch {
            failure = failure ?? error.localizedDescription
        }

        do {
            let dump = try await dumpCall
            interfaces = (dump["interface"].arrayValue ?? []).map(NetworkInterface.fromDump)
        } catch {
            failure = failure ?? error.localizedDescription
        }

        error = failure
    }

    // MARK: - System vitals (from `system info`)

    /// 1-minute load average as a rough CPU percentage (load is fixed-point
    /// with a 65536 scale, mirroring the Flutter dashboard math).
    var cpuPercent: Double? {
        guard let load = systemInfo["load"][0].doubleValue else { return nil }
        return min(100, max(0, load / 65536 * 100))
    }

    var memoryUsedPercent: Double? {
        guard let total = systemInfo["memory"]["total"].doubleValue, total > 0 else {
            return nil
        }
        return min(100, max(0, usedMemoryBytes / total * 100))
    }

    /// "used of total", e.g. "182.4 MB of 512.0 MB".
    var memoryUsedText: String? {
        guard let total = systemInfo["memory"]["total"].doubleValue, total > 0 else {
            return nil
        }
        return "\(Format.bytes(usedMemoryBytes)) of \(Format.bytes(total))"
    }

    private var usedMemoryBytes: Double {
        let total = systemInfo["memory"]["total"].doubleValue ?? 0
        let free = systemInfo["memory"]["free"].doubleValue ?? 0
        let buffered = systemInfo["memory"]["buffered"].doubleValue ?? 0
        return max(0, total - free - buffered)
    }

    var uptimeText: String? {
        guard let uptime = systemInfo["uptime"].intValue else { return nil }
        return Format.uptime(uptime)
    }

    // MARK: - Preferences

    /// The visibility id used for a wireless network in
    /// `DashboardPreferences.enabledWirelessInterfaces`, matching the Flutter
    /// app: "SSID (radio)".
    static func wirelessPreferenceID(for network: WirelessNetwork) -> String {
        "\(network.ssid) (\(network.radio))"
    }

    func loadPrefs(routerID: String?) {
        let key: String
        if let routerID {
            key = DashboardPreferences.storageKey(forRouterID: routerID)
        } else {
            key = DashboardPreferences.globalStorageKey
        }
        let loaded: DashboardPreferences
        if let data = UserDefaults.standard.data(forKey: key),
            let decoded = try? JSONDecoder().decode(DashboardPreferences.self, from: data)
        {
            loaded = decoded
        } else {
            loaded = .defaultPreferences
        }
        if loaded != prefs {
            prefs = loaded
        }
    }

    /// Wireless networks to show on the dashboard. An empty enabled set means
    /// "show all"; entries without an SSID are never shown.
    var visibleWireless: [WirelessNetwork] {
        let named = wireless.filter { !$0.ssid.isEmpty }
        guard !prefs.enabledWirelessInterfaces.isEmpty else { return named }
        return named.filter {
            prefs.enabledWirelessInterfaces.contains(Self.wirelessPreferenceID(for: $0))
        }
    }

    /// Interfaces to show on the dashboard. Loopback is always hidden; an
    /// empty enabled set means "show all".
    var visibleInterfaces: [NetworkInterface] {
        let nonLoopback = interfaces.filter {
            let lower = $0.name.lowercased()
            return lower != "loopback" && lower != "lo"
        }
        guard !prefs.enabledWiredInterfaces.isEmpty else { return nonLoopback }
        return nonLoopback.filter { prefs.enabledWiredInterfaces.contains($0.name) }
    }
}
