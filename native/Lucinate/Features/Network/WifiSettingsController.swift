import Foundation
import Observation

/// A broadcast Wi-Fi network (uci `wifi-iface` with `mode=ap`).
struct AccessPoint: Sendable, Identifiable, Equatable {
    /// wireless uci section id (e.g. `default_radio0` or `cfg0387bc`).
    let section: String
    let ssid: String
    /// The `device` option: which wifi-device carries this AP (e.g. `radio0`).
    let radio: String
    /// Numeric band of the carrying radio: 2/5/6 (0 when unknown).
    let band: Int
    /// `disabled` != "1".
    var enabled: Bool
    /// Option `hidden` == "1" (SSID not broadcast).
    let hidden: Bool
    /// uci `encryption` value ("none", "psk2", "sae", ...).
    let encryption: String
    /// A `key` option is currently set.
    let hasKey: Bool
    /// Attached logical network (e.g. `lan`).
    let network: String
    let mode: String

    var id: String { section }

    var bandLabel: String { Travelmate.bandLabel(for: band) }
}

/// A physical radio (uci `wifi-device`).
struct Radio: Sendable, Identifiable, Equatable {
    /// wireless uci section id, which is also the radio name (e.g. `radio0`).
    let section: String
    /// Numeric band: 2/5/6 (0 when unknown).
    let band: Int
    /// "auto" or a channel number string.
    let channel: String
    /// e.g. "HT20", "VHT80", "HE160" ("" when unset).
    let htmode: String

    var id: String { section }

    var bandLabel: String { Travelmate.bandLabel(for: band) }
}

/// Loads and mutates the router's broadcast Wi-Fi configuration
/// (`uci get wireless` → wifi-device radios + mode=ap wifi-ifaces).
@MainActor
@Observable
final class WifiSettingsController {
    private(set) var accessPoints: [AccessPoint] = []
    private(set) var radios: [Radio] = []

    /// True only while loading with nothing cached (cached-first UX).
    private(set) var isLoading = false
    private(set) var error: String?
    /// A mutation (apply / enable toggle) is in flight.
    private(set) var isBusy = false

    var isEmpty: Bool { accessPoints.isEmpty }

    /// The wifi-device backing an access point, when known.
    func radio(for accessPoint: AccessPoint) -> Radio? {
        radios.first { $0.section == accessPoint.radio }
    }

    // MARK: - Loading

    func load(service: RouterService?) async {
        guard let service else {
            accessPoints = []
            radios = []
            error = nil
            return
        }

        if isEmpty { isLoading = true }
        defer { isLoading = false }

        do {
            let wireless = try await service.uciGet(config: "wireless")
            parse(wireless)
            error = nil
        } catch let ubusError as UbusError where ubusError.isUnavailableObject {
            // Wired-only router: no wireless config. Empty state, not an error.
            accessPoints = []
            radios = []
            error = nil
        } catch {
            if isEmpty {
                self.error = error.localizedDescription
            }
        }
    }

    private func parse(_ wireless: JSONValue) {
        let sections = wireless.objectValue ?? [:]

        var parsedRadios: [Radio] = []
        for (name, section) in sections
        where section[".type"].stringValue == "wifi-device" {
            parsedRadios.append(
                Radio(
                    section: name,
                    band: Self.band(fromDevice: section),
                    channel: section["channel"].coercedString ?? "auto",
                    htmode: section["htmode"].coercedString ?? ""
                ))
        }
        parsedRadios.sort { ($0.band, $0.section) < ($1.band, $1.section) }

        let bandByRadio = Dictionary(
            uniqueKeysWithValues: parsedRadios.map { ($0.section, $0.band) })

        var parsedAPs: [AccessPoint] = []
        for (name, section) in sections
        where section[".type"].stringValue == "wifi-iface" {
            // Treat a missing `mode` as OpenWrt's default of "ap".
            let mode = section["mode"].coercedString ?? "ap"
            guard mode == "ap" else { continue }
            let device = section["device"].coercedString ?? ""
            parsedAPs.append(
                AccessPoint(
                    section: name,
                    ssid: section["ssid"].coercedString ?? "",
                    radio: device,
                    band: bandByRadio[device] ?? 0,
                    enabled: (section["disabled"].coercedString ?? "0") != "1",
                    hidden: (section["hidden"].coercedString ?? "0") == "1",
                    encryption: section["encryption"].coercedString ?? "none",
                    hasKey: !(section["key"].coercedString ?? "").isEmpty,
                    network: section["network"].coercedString ?? "",
                    mode: mode
                ))
        }
        parsedAPs.sort {
            if $0.band != $1.band { return $0.band < $1.band }
            let lhs = $0.ssid.localizedCaseInsensitiveCompare($1.ssid)
            if lhs != .orderedSame { return lhs == .orderedAscending }
            return $0.section < $1.section
        }

        radios = parsedRadios
        accessPoints = parsedAPs
    }

    /// Band of a wifi-device: prefer the modern `band` option, fall back to
    /// legacy `hwmode`, then guess from the channel number.
    private static func band(fromDevice section: JSONValue) -> Int {
        switch (section["band"].coercedString ?? "").lowercased() {
        case "2g": return 2
        case "5g": return 5
        case "6g": return 6
        default: break
        }
        switch (section["hwmode"].coercedString ?? "").lowercased() {
        case "11b", "11g", "11ng": return 2
        case "11a", "11na", "11ac", "11ad": return 5
        default: break
        }
        if let channel = Int(section["channel"].coercedString ?? "") {
            return channel <= 14 ? 2 : 5
        }
        return 0
    }

    // MARK: - Mutations

    /// Applies option changes to a wireless section (iface or device),
    /// commits, reloads wifi, then refreshes the local model.
    /// Returns false (and sets `error`) on failure.
    func apply(section: String, values: [String: String], service: RouterService?) async -> Bool {
        guard let service else {
            error = "Not connected"
            return false
        }
        guard !values.isEmpty else { return true }

        isBusy = true
        defer { isBusy = false }

        do {
            try await service.updateWireless(section: section, values: values)
            error = nil
            await load(service: service)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Enables/disables an AP iface with an optimistic flip that reverts on
    /// failure.
    func setEnabled(_ enabled: Bool, section: String, service: RouterService?) async {
        guard let service else {
            error = "Not connected"
            return
        }
        guard let index = accessPoints.firstIndex(where: { $0.section == section })
        else { return }

        let previous = accessPoints[index].enabled
        accessPoints[index].enabled = enabled

        isBusy = true
        defer { isBusy = false }

        do {
            try await service.setWirelessSectionDisabled(section: section, disabled: !enabled)
            error = nil
        } catch {
            if let revertIndex = accessPoints.firstIndex(where: { $0.section == section }) {
                accessPoints[revertIndex].enabled = previous
            }
            self.error = error.localizedDescription
        }
    }
}
