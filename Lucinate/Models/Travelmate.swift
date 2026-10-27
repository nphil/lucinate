import Foundation

/// Models for the Travelmate module, mirroring `lib/models/travelmate.dart`.
///
/// Data sources on the router:
///   - `uci get travelmate`  -> global settings + `@uplink` (saved uplinks)
///   - `file read /var/run/travelmate/travelmate.runtime.json` -> live status
///   - `iwinfo scan {device}` -> nearby networks

/// Namespace for shared Travelmate helpers.
enum Travelmate {
    /// Maps a numeric Wi-Fi band (2/5/6) to a human-friendly label.
    static func bandLabel(for band: Int) -> String {
        switch band {
        case 2: return "2.4 GHz"
        case 5: return "5 GHz"
        case 6: return "6 GHz"
        default: return band > 0 ? "\(band) GHz" : ""
        }
    }
}

/// What travelmate's own internet check found on the active uplink.
enum UplinkConnectivity: Sendable, Equatable {
    /// `net ok`: the probe URL answered normally.
    case online
    /// `net cp '<host>'`: the probe was redirected to a sign-in page. `host`
    /// is nil when travelmate reported none.
    case captivePortal(host: String?)
    /// `net nok` / `net fail`: associated, but nothing gets through.
    case noInternet
    /// Not connected, still connecting, or a status this app doesn't know.
    case unknown
}

/// The five uplink states the UI tells apart.
enum UplinkPhase: Sendable, Equatable {
    case online
    case signInNeeded
    case noInternet
    case connecting
    case notConnected
}

struct TravelmateStatus: Sendable, Equatable {
    /// Travelmate's live status file; the fields below come from its `data`
    /// object.
    static let runtimeFilePath = "/var/run/travelmate/travelmate.runtime.json"

    /// From `travelmate.global.trm_enabled`.
    let enabled: Bool

    /// Raw `travelmate_status`: `connected, net ok/72`,
    /// `connected, net cp 'portal.example.com'/72`, `connected, net nok/40`,
    /// `processing`, `not connected` or `program error`.
    let statusText: String

    /// SSID of the currently active uplink (parsed from `station_id`).
    let activeSsid: String

    /// Radio backing the active uplink (e.g. `radio0`).
    let activeDevice: String

    /// Result of travelmate's internet check on the active uplink; `.unknown`
    /// unless the status text carries one.
    let connectivity: UplinkConnectivity

    let subnet: String

    init(
        enabled: Bool,
        statusText: String,
        activeSsid: String,
        activeDevice: String,
        connectivity: UplinkConnectivity,
        subnet: String
    ) {
        self.enabled = enabled
        self.statusText = statusText
        self.activeSsid = activeSsid
        self.activeDevice = activeDevice
        self.connectivity = connectivity
        self.subnet = subnet
    }

    private var normalizedStatus: String {
        statusText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isConnected: Bool {
        normalizedStatus.hasPrefix("connected")
    }

    /// Travelmate is trying to bring an uplink up.
    var isProcessing: Bool {
        normalizedStatus == "processing"
    }

    /// Travelmate itself failed (e.g. its interface is missing on ubus).
    var hasError: Bool {
        normalizedStatus == "program error"
    }

    /// Hostname of the sign-in page when a captive portal was detected.
    var portalHost: String? {
        if case .captivePortal(let host) = connectivity { return host }
        return nil
    }

    var phase: UplinkPhase {
        switch connectivity {
        case .online: return .online
        case .captivePortal: return .signInNeeded
        case .noInternet: return .noInternet
        case .unknown:
            // `connected, -`: associated, but the internet check hasn't
            // reported yet.
            return (isProcessing || isConnected) ? .connecting : .notConnected
        }
    }

    /// Same status with the master switch replaced (optimistic toggle).
    func withEnabled(_ enabled: Bool) -> TravelmateStatus {
        TravelmateStatus(
            enabled: enabled,
            statusText: statusText,
            activeSsid: activeSsid,
            activeDevice: activeDevice,
            connectivity: connectivity,
            subnet: subnet
        )
    }

    /// Whether both statuses describe the same connection. The signal quality
    /// inside the status text (`/72`) drifts between reads and is ignored.
    func hasSameConnection(as other: TravelmateStatus) -> Bool {
        phase == other.phase && activeSsid == other.activeSsid
            && activeDevice == other.activeDevice
    }

    /// Builds status from the raw JSON string held in `file.read`'s `data`
    /// field (the contents of travelmate.runtime.json).
    static func fromRuntime(_ rawData: String, enabled: Bool) -> TravelmateStatus {
        guard let data = rawData.data(using: .utf8),
            let outer = try? JSONValue.parse(data),
            let inner = outer["data"].objectValue
        else {
            return TravelmateStatus(
                enabled: enabled,
                statusText: "",
                activeSsid: "",
                activeDevice: "",
                connectivity: .unknown,
                subnet: ""
            )
        }
        let d = JSONValue.object(inner)

        let station = parseStationID(d["station_id"].coercedString ?? "")
        let statusText = d["travelmate_status"].coercedString ?? ""

        return TravelmateStatus(
            enabled: enabled,
            statusText: statusText,
            activeSsid: station.ssid,
            activeDevice: station.device,
            connectivity: connectivity(fromStatusText: statusText),
            subnet: d["station_subnet"].coercedString ?? ""
        )
    }

    /// Reads the internet-check result out of `travelmate_status`. The run
    /// flags in the same file (`captive: ✔`) only say that detection is
    /// switched on, so they are deliberately not consulted.
    static func connectivity(fromStatusText statusText: String) -> UplinkConnectivity {
        let text = statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix("connected"),
            let comma = text.firstIndex(of: ",")
        else { return .unknown }

        // "connected, net cp 'host'/72" -> "net cp 'host'/72"
        let check = text[text.index(after: comma)...]
            .trimmingCharacters(in: .whitespaces)
        guard check.lowercased().hasPrefix("net ") else { return .unknown }

        let detail = check.dropFirst(4)
        let kind = detail.prefix(while: { $0 != " " && $0 != "/" }).lowercased()
        switch kind {
        case "ok": return .online
        case "nok", "fail": return .noInternet
        case "cp": return .captivePortal(host: quotedHost(in: detail))
        default: return .unknown
        }
    }

    /// `'portal.example.com'/72` -> `portal.example.com`; nil when absent/empty.
    private static func quotedHost(in text: Substring) -> String? {
        guard let open = text.firstIndex(of: "'") else { return nil }
        let start = text.index(after: open)
        guard let close = text[start...].firstIndex(of: "'") else { return nil }
        let host = text[start..<close].trimmingCharacters(in: .whitespaces)
        return host.isEmpty ? nil : host
    }

    /// Splits `station_id` (`radio/ssid/bssid`, `-` for an empty part). An SSID
    /// may contain `/` itself, so the radio ends at the first slash and the
    /// BSSID starts after the last. The SSID is kept verbatim (trailing spaces
    /// are legal) so it still equals the saved uplink's.
    static func parseStationID(_ raw: String) -> (device: String, ssid: String, bssid: String) {
        func part(_ text: String, trimmed: Bool = true) -> String {
            let value = trimmed ? text.trimmingCharacters(in: .whitespaces) : text
            return value == "-" ? "" : value
        }
        guard let first = raw.firstIndex(of: "/") else { return (part(raw), "", "") }
        let device = part(String(raw[..<first]))
        let rest = raw[raw.index(after: first)...]
        guard let last = rest.lastIndex(of: "/") else {
            return (device, part(String(rest), trimmed: false), "")
        }
        return (
            device,
            part(String(rest[..<last]), trimmed: false),
            part(String(rest[rest.index(after: last)...]))
        )
    }

    /// What the file reads like right after travelmate (re)starts, before its
    /// first status write.
    static func processing(enabled: Bool) -> TravelmateStatus {
        TravelmateStatus(
            enabled: enabled,
            statusText: "processing",
            activeSsid: "",
            activeDevice: "",
            connectivity: .unknown,
            subnet: ""
        )
    }

    static let empty = TravelmateStatus(
        enabled: false,
        statusText: "",
        activeSsid: "",
        activeDevice: "",
        connectivity: .unknown,
        subnet: ""
    )
}

struct TravelmateUplink: Sendable, Identifiable, Equatable {
    /// The travelmate uci section id (anonymous, e.g. `cfg0254f8`).
    let sectionId: String
    let ssid: String
    let device: String
    /// False once travelmate gives up on the network (3 failed connection
    /// attempts) or detects a BSSID mismatch; it never retries on its own
    /// until the flag is set again.
    let enabled: Bool
    /// Optional BSSID pin. The app never sets one, but uplinks added in LuCI may.
    let bssid: String

    init(sectionId: String, ssid: String, device: String, enabled: Bool, bssid: String = "") {
        self.sectionId = sectionId
        self.ssid = ssid
        self.device = device
        self.enabled = enabled
        self.bssid = bssid
    }

    var id: String { sectionId }

    /// Whether this saved uplink is the one currently connected.
    func isActive(given status: TravelmateStatus) -> Bool {
        status.isConnected && !ssid.isEmpty && status.activeSsid == ssid
    }

    /// Parses a travelmate `@uplink` uci section.
    static func fromUci(sectionId: String, _ section: JSONValue) -> TravelmateUplink {
        TravelmateUplink(
            sectionId: sectionId,
            ssid: section["ssid"].coercedString ?? "",
            device: section["device"].coercedString ?? "",
            // Travelmate reads a missing `enabled` as off (`f_getval "enabled" "0"`).
            enabled: section["enabled"].coercedString == "1",
            bssid: section["bssid"].coercedString ?? ""
        )
    }
}

/// How a scanned network relates to the networks already saved.
enum SavedNetworkMatch: Sendable, Equatable {
    case notSaved
    /// Same SSID on the same radio. Travelmate treats these as one network.
    case saved(TravelmateUplink)
    /// Same SSID, but only for another radio (the 2.4 and 5 GHz copies of a
    /// network are separate uplinks), so saving it here is a separate entry.
    case savedOnOtherRadio(devices: [String])
}

extension WifiScanResult {
    func savedMatch(in uplinks: [TravelmateUplink]) -> SavedNetworkMatch {
        let sameSsid = uplinks.filter { $0.ssid == ssid }
        let here = sameSsid.filter { $0.device == device }
        if let uplink = here.first(where: { $0.enabled }) ?? here.first {
            return .saved(uplink)
        }
        let others = Set(sameSsid.map { $0.device }).sorted()
        return others.isEmpty ? .notSaved : .savedOnOtherRadio(devices: others)
    }
}

/// Pure lookups over raw `uci get` results. Travelmate links a saved uplink to
/// its `wifi-iface` by radio + SSID + optional BSSID (`f_getcfg`), so adding,
/// reconnecting and forgetting a network must pick sections the same way.
enum TravelmateConfig {
    /// Name prefix of the STA ifaces travelmate and this app create.
    static let staPrefix = "trm_uplink"

    /// Sections of one uci config in file order (`.index`), by name when the
    /// router doesn't report an index.
    static func orderedSections(_ config: JSONValue) -> [(name: String, section: JSONValue)] {
        (config.objectValue ?? [:])
            .map { (name: $0.key, section: $0.value) }
            .sorted { lhs, rhs in
                let l = lhs.section[".index"].intValue ?? Int.max
                let r = rhs.section[".index"].intValue ?? Int.max
                return l == r ? lhs.name < rhs.name : l < r
            }
    }

    static func normalizedBSSID(_ bssid: String) -> String {
        bssid.trimmingCharacters(in: .whitespaces).uppercased()
    }

    private static func isMatch(
        _ section: JSONValue, type: String, mode: String? = nil, ssid: String, device: String
    ) -> Bool {
        guard section[".type"].stringValue == type else { return false }
        if let mode, section["mode"].coercedString != mode { return false }
        guard section["ssid"].coercedString == ssid else { return false }
        return section["device"].coercedString == device
    }

    /// `mode=sta` wifi-iface sections of one saved network, best candidate
    /// first: the one whose BSSID pin equals the uplink's (what travelmate
    /// links), then sections travelmate named itself, then file order.
    static func staSections(
        in wireless: JSONValue, ssid: String, device: String, bssid: String = ""
    ) -> [String] {
        let pin = normalizedBSSID(bssid)
        let candidates = orderedSections(wireless).filter { entry in
            isMatch(entry.section, type: "wifi-iface", mode: "sta", ssid: ssid, device: device)
        }
        return candidates.enumerated()
            .map { offset, entry -> (rank: Int, offset: Int, name: String) in
                let samePin =
                    normalizedBSSID(entry.section["bssid"].coercedString ?? "") == pin
                let rank = (samePin ? 0 : 2) + (entry.name.hasPrefix(staPrefix) ? 0 : 1)
                return (rank, offset, entry.name)
            }
            .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
            .map { $0.name }
    }

    /// The travelmate `uplink` section for a network. With several matching,
    /// the first in file order is the one travelmate applies.
    static func uplinkSection(in travelmate: JSONValue, ssid: String, device: String) -> String? {
        orderedSections(travelmate).first(where: { entry in
            isMatch(entry.section, type: "uplink", ssid: ssid, device: device)
        })?.name
    }

    /// First unused `trm_uplinkN` section name.
    static func nextStaSectionName(in wireless: JSONValue) -> String {
        var maxIndex = 0
        for name in (wireless.objectValue ?? [:]).keys where name.hasPrefix(staPrefix) {
            if let n = Int(name.dropFirst(staPrefix.count)) { maxIndex = max(maxIndex, n) }
        }
        return "\(staPrefix)\(maxIndex + 1)"
    }
}

struct WifiScanResult: Sendable, Identifiable, Equatable {
    let ssid: String
    let bssid: String

    /// The radio we scanned on (`radio0`/`radio1`).
    let device: String
    /// Signal in dBm.
    let signal: Int
    let quality: Int
    let qualityMax: Int
    let encrypted: Bool

    /// uci `encryption` value to use when adding this as an uplink.
    let encryption: String
    /// Numeric band (2/5/6); 0 when unknown.
    let band: Int
    /// Radio channel the AP is on (for congestion analysis).
    let channel: Int

    init(
        ssid: String,
        bssid: String,
        device: String,
        signal: Int,
        quality: Int,
        qualityMax: Int,
        encrypted: Bool,
        encryption: String,
        band: Int,
        channel: Int
    ) {
        self.ssid = ssid
        self.bssid = bssid
        self.device = device
        self.signal = signal
        self.quality = quality
        self.qualityMax = qualityMax
        self.encrypted = encrypted
        self.encryption = encryption
        self.band = band
        self.channel = channel
    }

    var id: String { "\(bssid)-\(device)" }

    var qualityPercent: Int {
        qualityMax > 0
            ? Int((Double(quality) * 100 / Double(qualityMax)).rounded())
            : 0
    }

    /// Human-friendly band, e.g. "2.4 GHz" / "5 GHz".
    var bandLabel: String { Travelmate.bandLabel(for: band) }

    /// Whether joining this network requires a password.
    var requiresPassword: Bool { encryption != "none" }

    /// Parses one entry of an `iwinfo scan` result for the given radio.
    static func fromIwinfo(_ json: JSONValue, device: String) -> WifiScanResult {
        let enc = json["encryption"]
        return WifiScanResult(
            ssid: json["ssid"].coercedString ?? "",
            bssid: json["bssid"].coercedString ?? "",
            device: device,
            signal: json["signal"].intValue ?? 0,
            quality: json["quality"].intValue ?? 0,
            qualityMax: json["quality_max"].intValue ?? 70,
            encrypted: enc["enabled"].boolValue ?? false,
            encryption: mapEncryption(enc),
            band: json["band"].intValue ?? 0,
            channel: json["channel"].intValue ?? 0
        )
    }

    /// Maps an iwinfo `encryption` object to a uci `encryption` option value.
    static func mapEncryption(_ enc: JSONValue) -> String {
        guard enc.objectValue != nil, enc["enabled"].boolValue == true else {
            return "none"
        }
        let auth = (enc["authentication"].arrayValue ?? [])
            .compactMap { $0.stringValue }
        let hasSae = auth.contains("sae")
        let hasPsk = auth.contains("psk")
        if hasSae && hasPsk { return "sae-mixed" }
        if hasSae { return "sae" }
        if hasPsk { return "psk2" }
        let wpa = (enc["wpa"].arrayValue ?? []).compactMap { $0.intValue }
        if wpa.contains(1) { return "psk" }
        return "psk2"
    }
}

/// A radio as it relates to the router's own broadcast Wi-Fi (the AP your
/// devices join). Backed by a `wifi-device` + its primary `mode=ap` iface.
struct BroadcastRadio: Sendable, Identifiable, Equatable {
    /// radio0/radio1.
    let device: String
    /// Numeric band: 2/5/6.
    let band: Int
    /// wifi-iface uci section id for the main AP.
    let apSection: String
    let ssid: String
    /// AP iface not `disabled`.
    let apEnabled: Bool
    /// "auto" or a channel number.
    let channel: String
    /// This radio is the active hotel uplink (STA).
    let uplinkLocked: Bool
    /// uci `encryption` of the AP iface (e.g. "psk2"/"sae"/"sae-mixed"/"none").
    let encryption: String
    /// uci `hidden` == "1" — SSID isn't broadcast.
    let hidden: Bool

    init(
        device: String,
        band: Int,
        apSection: String,
        ssid: String,
        apEnabled: Bool,
        channel: String,
        uplinkLocked: Bool,
        encryption: String = "none",
        hidden: Bool = false
    ) {
        self.device = device
        self.band = band
        self.apSection = apSection
        self.ssid = ssid
        self.apEnabled = apEnabled
        self.channel = channel
        self.uplinkLocked = uplinkLocked
        self.encryption = encryption
        self.hidden = hidden
    }

    var id: String { device }

    var bandLabel: String { Travelmate.bandLabel(for: band) }

    /// Human-friendly security name derived from the uci `encryption` value.
    var securityLabel: String {
        if encryption == "none" { return "Open" }
        if encryption.contains("sae") {
            return encryption.contains("mixed") ? "WPA2/3" : "WPA3"
        }
        if encryption.contains("psk2") { return "WPA2" }
        if encryption.contains("psk") { return "WPA" }
        return encryption.uppercased()
    }
}
