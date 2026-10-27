import Foundation
import Observation

/// Networks weaker than this are too flaky to repeat, so we hide them.
private let minSignalDbm = -80

/// A restart empties travelmate's status file until its first status write a
/// few seconds later; within this window an empty file reads as "connecting"
/// instead of flashing "Not connected".
private let restartGrace: Duration = .seconds(20)

// MARK: - Fetch helpers (free functions so `async let` runs them
// concurrently off the main actor).

/// nil means the read failed. A missing file is a legitimately empty status:
/// travelmate hasn't run yet, or was stopped.
private func readRuntime(_ service: RouterService) async -> String? {
    do {
        return try await service.fileRead(path: TravelmateStatus.runtimeFilePath)
    } catch let error as UbusError where error.isNotFound {
        return ""
    } catch {
        return nil
    }
}

private func readWireless(_ service: RouterService) async -> JSONValue? {
    try? await service.uciGet(config: "wireless")
}

private func tolerantScan(_ service: RouterService, radio: String) async -> [JSONValue] {
    guard let result = try? await service.wifiScan(radio: radio) else { return [] }
    return result["results"].arrayValue ?? []
}

/// Owns the Travelmate module's state. Mirrors
/// `lib/state/travelmate_controller.dart`; the authenticated `RouterService`
/// is passed into each method by the view.
@MainActor
@Observable
final class TravelmateController {
    private(set) var status: TravelmateStatus = .empty
    private(set) var uplinks: [TravelmateUplink] = []
    private(set) var broadcast: [BroadcastRadio] = []
    private(set) var scanResults: [WifiScanResult] = []
    /// radio0 -> 2, radio1 -> 5, ...
    private(set) var radioBands: [String: Int] = [:]
    private(set) var loaded = false
    private(set) var isLoading = false
    private(set) var isBusy = false
    private(set) var isScanning = false
    private(set) var error: String?

    /// `/etc/config/travelmate` doesn't exist: the package isn't installed.
    private(set) var notInstalled = false

    /// The latest attempt to read live data failed. The last good data stays on
    /// screen and the next poll retries in full.
    private(set) var refreshFailed = false

    /// When this controller last restarted travelmate.
    @ObservationIgnored private var restartedAt: ContinuousClock.Instant?

    /// Forget everything (used when the selected router changes).
    func reset() {
        status = .empty
        uplinks = []
        broadcast = []
        scanResults = []
        radioBands = [:]
        loaded = false
        error = nil
        notInstalled = false
        refreshFailed = false
        restartedAt = nil
    }

    /// Friendly band label for a wifi device (`radio0` -> `2.4 GHz`), falling
    /// back to the raw device name when the band can't be determined.
    func deviceLabel(_ device: String) -> String {
        let label = Travelmate.bandLabel(for: radioBands[device] ?? 0)
        return label.isEmpty ? device : label
    }

    /// The single saved uplink that is actually connected right now. When
    /// several saved uplinks share the active SSID (common in hotels where
    /// every AP has the same name), this disambiguates by the connected radio
    /// so only one row is flagged "Active" — never all of them.
    var activeUplinkId: String? {
        guard status.isConnected, !status.activeSsid.isEmpty else { return nil }
        let matches = uplinks.filter { $0.ssid == status.activeSsid }
        guard !matches.isEmpty else { return nil }
        if !status.activeDevice.isEmpty,
            let exact = matches.first(where: { $0.device == status.activeDevice })
        {
            return exact.sectionId
        }
        return matches.first?.sectionId
    }

    /// Saved uplinks that duplicate another (same SSID + same band). The
    /// connected one (or, if none, the first) is treated as canonical; the
    /// rest are flagged so the user can forget the redundant copies.
    var duplicateUplinkIds: Set<String> {
        let canonicalActive = activeUplinkId
        var groups: [String: [TravelmateUplink]] = [:]
        for uplink in uplinks {
            let band = radioBands[uplink.device] ?? 0
            groups["\(uplink.ssid.lowercased())|\(band)", default: []].append(uplink)
        }
        var duplicates: Set<String> = []
        for (_, group) in groups where group.count > 1 {
            let canonical =
                group.first { $0.sectionId == canonicalActive } ?? group.first
            for uplink in group where uplink.sectionId != canonical?.sectionId {
                duplicates.insert(uplink.sectionId)
            }
        }
        return duplicates
    }

    // MARK: - Load

    func load(service: RouterService) async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        async let travelmateValues = service.uciGet(config: "travelmate")
        async let runtimeRaw = readRuntime(service)
        async let wirelessValues = readWireless(service)

        do {
            let travelmate = try await travelmateValues
            let runtime = await runtimeRaw
            let wireless = await wirelessValues

            // --- travelmate config: global + uplinks ---
            var enabled = false
            var parsedUplinks: [TravelmateUplink] = []
            for (name, section) in travelmate.objectValue ?? [:] {
                switch section[".type"].stringValue {
                case "travelmate":
                    enabled = (section["trm_enabled"].coercedString ?? "0") == "1"
                case "uplink":
                    parsedUplinks.append(TravelmateUplink.fromUci(sectionId: name, section))
                default:
                    break
                }
            }
            // Stable order across loads (Swift dictionaries don't preserve order).
            uplinks = parsedUplinks.sorted {
                $0.ssid == $1.ssid ? $0.sectionId < $1.sectionId : $0.ssid < $1.ssid
            }

            // --- live status from runtime.json; a failed read keeps the last status ---
            status =
                runtime.map { parseStatus($0, enabled: enabled) }
                ?? status.withEnabled(enabled)

            // --- radio -> band map (so we can show 2.4/5 GHz, not radio0/radio1)
            // and the router's own broadcast Wi-Fi; a failed read keeps the last ones ---
            if let wireless {
                var bands: [String: Int] = [:]
                for (name, section) in wireless.objectValue ?? [:] {
                    if section[".type"].stringValue == "wifi-device" {
                        bands[name] = Self.bandOf(section)
                    }
                }
                radioBands = bands
                broadcast = Self.parseBroadcast(
                    wireless: wireless, bands: bands, activeDevice: status.activeDevice)
            }

            loaded = true
            notInstalled = false
            refreshFailed = runtime == nil || wireless == nil
        } catch {
            // The view went away (tab switch, router change) mid-load.
            if Task.isCancelled || error is CancellationError { return }

            if loaded {
                // Keep what's on screen; the poll retries. A "not found" here
                // can be rpcd restarting, so it doesn't prove an uninstall.
                refreshFailed = true
            } else if let ubusError = error as? UbusError, ubusError.isNotFound {
                // Nothing was ever loaded and `uci get travelmate` reports
                // "not found": there is no /etc/config/travelmate.
                notInstalled = true
            } else {
                notInstalled = false
                self.error = error.localizedDescription
            }
        }
    }

    /// One tick of the live poll: re-reads only travelmate's status file, so
    /// connecting / sign-in / online transitions show up as they happen. A
    /// change of connection also reloads the saved list, which is where a
    /// network travelmate just gave up on turns up as paused. After a failed
    /// read the next tick reloads everything instead.
    func refreshStatus(service: RouterService) async {
        guard loaded, !isLoading, !isBusy, !isScanning else { return }
        if refreshFailed {
            await load(service: service)
            return
        }
        let raw = await readRuntime(service)
        // The tab may have gone away, or a load or change may have started,
        // while the read was in flight.
        guard !Task.isCancelled, !isLoading, !isBusy else { return }
        guard let raw else {
            refreshFailed = true
            return
        }
        let previous = status
        let fresh = parseStatus(raw, enabled: previous.enabled)
        if fresh != previous { status = fresh }
        if !fresh.hasSameConnection(as: previous) {
            await load(service: service)
        }
    }

    private func parseStatus(_ raw: String, enabled: Bool) -> TravelmateStatus {
        let parsed = TravelmateStatus.fromRuntime(raw, enabled: enabled)
        if enabled, parsed.statusText.isEmpty, let restartedAt,
            ContinuousClock.now - restartedAt < restartGrace
        {
            return .processing(enabled: true)
        }
        return parsed
    }

    private func noteRestart() {
        restartedAt = ContinuousClock.now
    }

    /// Best-effort band (2/5/6) for a `wifi-device` uci section.
    private static func bandOf(_ dev: JSONValue) -> Int {
        switch dev["band"].coercedString ?? "" {
        case "2g": return 2
        case "5g": return 5
        case "6g": return 6
        default: break
        }
        let hw = dev["hwmode"].coercedString ?? ""  // legacy 11a/11g/11b/11n
        if hw.contains("a") { return 5 }
        if hw.contains("g") || hw.contains("b") { return 2 }
        if let ch = Int(dev["channel"].coercedString ?? ""), ch > 0 {
            return ch <= 14 ? 2 : 5
        }
        return 0
    }

    /// Build the broadcast-radio view from wireless config. The primary AP per
    /// radio is the `mode=ap` iface (preferring `network=lan`).
    private static func parseBroadcast(
        wireless: JSONValue, bands: [String: Int], activeDevice: String
    ) -> [BroadcastRadio] {
        guard let sections = wireless.objectValue else { return [] }
        var channels: [String: String] = [:]
        var apByDevice: [String: JSONValue] = [:]
        var apSectionByDevice: [String: String] = [:]
        var apIsLan: [String: Bool] = [:]
        // Deterministic "first AP seen" — Swift dictionary order is unstable.
        for name in sections.keys.sorted() {
            let section = sections[name] ?? .null
            switch section[".type"].stringValue {
            case "wifi-device":
                channels[name] = section["channel"].coercedString ?? "auto"
            case "wifi-iface":
                guard section["mode"].coercedString == "ap" else { continue }
                let dev = section["device"].coercedString ?? ""
                guard !dev.isEmpty else { continue }
                let isLan = (section["network"].coercedString ?? "") == "lan"
                // Prefer the LAN AP; otherwise keep the first AP seen on this radio.
                if apByDevice[dev] == nil || (isLan && apIsLan[dev] != true) {
                    apByDevice[dev] = section
                    apSectionByDevice[dev] = name
                    apIsLan[dev] = isLan
                }
            default:
                break
            }
        }
        let devices = bands.keys.sorted {
            (bands[$0] ?? 0, $0) < (bands[$1] ?? 0, $1)
        }
        var radios: [BroadcastRadio] = []
        for dev in devices {
            // A radio without an AP isn't a broadcast radio.
            guard let ap = apByDevice[dev] else { continue }
            radios.append(
                BroadcastRadio(
                    device: dev,
                    band: bands[dev] ?? 0,
                    apSection: apSectionByDevice[dev] ?? "",
                    ssid: ap["ssid"].coercedString ?? "",
                    apEnabled: (ap["disabled"].coercedString ?? "0") != "1",
                    channel: channels[dev] ?? "auto",
                    uplinkLocked: !activeDevice.isEmpty && dev == activeDevice,
                    // Some firmwares omit `encryption` on the AP section even
                    // when a key is set — a present key means "not open".
                    encryption: {
                        let enc = ap["encryption"].coercedString ?? ""
                        if !enc.isEmpty && enc != "none" { return enc }
                        let key = ap["key"].coercedString ?? ""
                        return key.isEmpty ? "none" : "psk2"
                    }(),
                    hidden: (ap["hidden"].coercedString ?? "0") == "1"
                ))
        }
        return radios
    }

    // MARK: - Master switch

    /// Optimistically flips the switch; reverts on failure.
    @discardableResult
    func setEnabled(_ value: Bool, service: RouterService) async -> Bool {
        let previous = status
        status = previous.withEnabled(value)
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            try await service.setTravelmateEnabled(value)
            noteRestart()
            await load(service: service)
            return true
        } catch {
            status = previous
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - Scan

    /// Scan both radios for nearby networks, keeping the strongest signal per
    /// SSID+band (2.4 and 5 GHz of the same network stay distinct — the band
    /// choice matters for a travel uplink).
    ///
    /// Both radios are scanned in parallel (halves the wait), but each radio's
    /// results are published to `scanResults` the moment that radio finishes —
    /// so the list grows live instead of appearing all at once after an
    /// opaque spinner. One radio failing (e.g. busy) doesn't abort the scan.
    func scan(service: RouterService) async {
        isScanning = true
        error = nil
        scanResults = []
        defer { isScanning = false }

        var byNameBand: [String: WifiScanResult] = [:]

        await withTaskGroup(of: (String, [JSONValue]).self) { group in
            for radio in ["radio0", "radio1"] {
                group.addTask { (radio, await tolerantScan(service, radio: radio)) }
            }
            for await (radio, entries) in group {
                for entry in entries {
                    let scan = WifiScanResult.fromIwinfo(entry, device: radio)
                    if scan.ssid.isEmpty { continue }  // skip hidden networks
                    // Skip networks too weak to repeat reliably (0 == unknown).
                    if scan.signal != 0 && scan.signal < minSignalDbm { continue }
                    let key = "\(scan.ssid) \(scan.band)"
                    if let existing = byNameBand[key], existing.signal >= scan.signal {
                        continue
                    }
                    byNameBand[key] = scan
                }
                // Publish after each radio completes → live-growing list,
                // strongest networks first.
                scanResults = byNameBand.values.sorted { $0.signal > $1.signal }
            }
        }
    }

    // MARK: - Uplinks

    /// How a scanned network relates to the saved ones.
    func savedMatch(for scan: WifiScanResult) -> SavedNetworkMatch {
        scan.savedMatch(in: uplinks)
    }

    /// Forget a saved uplink. Optimistically drops the row so it doesn't
    /// linger; a reload reconciles either way.
    @discardableResult
    func deleteUplink(_ uplink: TravelmateUplink, service: RouterService) async -> Bool {
        uplinks.removeAll { $0.sectionId == uplink.sectionId }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            try await service.removeTravelmateUplink(
                ssid: uplink.ssid, device: uplink.device, uplinkSection: uplink.sectionId)
            noteRestart()
            await load(service: service)
            return true
        } catch {
            await load(service: service)  // restore the true list on failure
            self.error = error.localizedDescription
            return false
        }
    }

    /// Save a network (STA iface + travelmate uplink), then reload. A network
    /// that is already saved is re-enabled instead of duplicated; a non-empty
    /// `password` replaces its stored key.
    @discardableResult
    func addUplink(
        ssid: String, password: String, device: String, encryption: String,
        service: RouterService
    ) async -> Bool {
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            try await service.addTravelmateUplink(
                ssid: ssid, password: password, device: device, encryption: encryption)
            noteRestart()
            await load(service: service)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Resume an uplink travelmate paused after repeated failed connects and
    /// let it retry right away.
    @discardableResult
    func reconnect(_ uplink: TravelmateUplink, service: RouterService) async -> Bool {
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            try await service.reconnectTravelmateUplink(section: uplink.sectionId)
            noteRestart()
            await load(service: service)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - Broadcast

    /// Enable exactly the broadcast radios in `enabledDevices` (by device id).
    /// Refuses to disable every radio, so the user can't lock themselves out.
    @discardableResult
    func setBroadcastBand(enabledDevices: Set<String>, service: RouterService) async -> Bool {
        guard !enabledDevices.isEmpty else {
            error = "At least one band must stay on."
            return false
        }
        isBusy = true
        error = nil
        defer { isBusy = false }
        let changes: [(section: String, values: [String: String])] = broadcast
            .filter { !$0.apSection.isEmpty }
            .map { radio in
                (
                    section: radio.apSection,
                    values: ["disabled": enabledDevices.contains(radio.device) ? "0" : "1"]
                )
            }
        do {
            try await service.updateWireless(changes: changes)
            await load(service: service)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Update a broadcast radio's AP identity (the network your devices
    /// join): SSID, optionally the password (nil/empty = keep current), and
    /// optionally the hidden flag (nil = unchanged). `radio` (a wifi-device
    /// such as `radio1`) with `channel` ("auto" or a number) sets the channel
    /// in the same change. Everything lands in one commit and one wifi
    /// reload; a second request after the reload would fail or lose its reply
    /// because the reload restarts the phone's own Wi-Fi.
    /// Using the same name on both bands lets clients band-steer
    /// automatically; different names pin a device to 2.4 or 5 GHz.
    @discardableResult
    func updateBroadcast(
        section: String, ssid: String, password: String?, hidden: Bool?,
        encryption: String? = nil,
        radio: String? = nil, channel: String? = nil,
        service: RouterService
    ) async -> Bool {
        let trimmed = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !section.isEmpty else {
            error = "Network name can't be empty."
            return false
        }
        var values: [String: String] = ["ssid": trimmed]
        if let password, !password.isEmpty {
            guard password.count >= 8 else {
                error = "Wi-Fi password must be at least 8 characters."
                return false
            }
            values["key"] = password
            // Securing a previously-open network needs an encryption mode too.
            if let encryption, !encryption.isEmpty {
                values["encryption"] = encryption
            }
        }
        if let hidden {
            values["hidden"] = hidden ? "1" : "0"
        }
        var changes: [(section: String, values: [String: String])] = [
            (section: section, values: values)
        ]
        if let radio, let channel, !radio.isEmpty, !channel.isEmpty {
            changes.append((section: radio, values: ["channel": channel]))
        }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            try await service.updateWireless(changes: changes)
            await load(service: service)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Set a radio's broadcast channel (`"auto"` or a number). No effect on a
    /// radio locked to the hotel uplink — the UI blocks that case.
    @discardableResult
    func setChannel(device: String, channel: String, service: RouterService) async -> Bool {
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            try await service.setRadioChannel(radio: device, channel: channel)
            await load(service: service)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Least-congested channels for a band, ranked best-first, from the last
    /// scan. 2.4 GHz favors non-overlapping 1/6/11; 5 GHz favors empty
    /// channels. Returns an empty list when there's no scan data.
    func suggestedChannels(band: Int) -> [Int] {
        var counts: [Int: Int] = [:]
        for result in scanResults where result.band == band && result.channel > 0 {
            counts[result.channel, default: 0] += 1
        }
        if counts.isEmpty { return [] }
        if band == 2 {
            func overlap(_ channel: Int) -> Int {
                // 2.4 GHz channels overlap their neighbors within ±2.
                counts.reduce(0) { $0 + (abs($1.key - channel) <= 2 ? $1.value : 0) }
            }
            return [1, 6, 11].sorted { overlap($0) < overlap($1) }
        }
        return [36, 40, 44, 48, 149, 153, 157, 161].sorted {
            (counts[$0] ?? 0) < (counts[$1] ?? 0)
        }
    }
}
