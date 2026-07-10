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

struct TravelmateStatus: Sendable, Equatable {
    /// From `travelmate.global.trm_enabled`.
    let enabled: Bool

    /// Raw status text, e.g. `"connected, net ok/72"` or `"error"`/``.
    let statusText: String

    /// SSID of the currently active uplink (parsed from `station_id`).
    let activeSsid: String

    /// Radio backing the active uplink (e.g. `radio0`).
    let activeDevice: String

    /// A captive portal was detected on the active uplink.
    let captive: Bool

    let subnet: String

    init(
        enabled: Bool,
        statusText: String,
        activeSsid: String,
        activeDevice: String,
        captive: Bool,
        subnet: String
    ) {
        self.enabled = enabled
        self.statusText = statusText
        self.activeSsid = activeSsid
        self.activeDevice = activeDevice
        self.captive = captive
        self.subnet = subnet
    }

    var isConnected: Bool {
        statusText.lowercased().hasPrefix("connected")
    }

    /// Builds status from the raw JSON string held in `file.read`'s `data`
    /// field (the contents of travelmate.runtime.json).
    static func fromRuntime(_ rawData: String, enabled: Bool) -> TravelmateStatus {
        let fallback = TravelmateStatus(
            enabled: enabled,
            statusText: "",
            activeSsid: "",
            activeDevice: "",
            captive: false,
            subnet: ""
        )

        guard let data = rawData.data(using: .utf8),
            let outer = try? JSONValue.parse(data),
            let inner = outer["data"].objectValue
        else {
            return fallback
        }
        let d = JSONValue.object(inner)

        // station_id looks like "radio0/SSID/bssid".
        let station = d["station_id"].coercedString ?? ""
        let parts = station.components(separatedBy: "/")
        var device = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
        var ssid = parts.count > 1
            ? parts[1].trimmingCharacters(in: .whitespaces)
            : ""
        if ssid == "-" { ssid = "" }
        if device == "-" { device = "" }

        let statusText = d["travelmate_status"].coercedString ?? ""
        let lowerStatus = statusText.lowercased()
        let connected = lowerStatus.hasPrefix("connected")
        // A captive portal shows up as the connectivity check failing
        // ("net nok") or an explicit "captive" state — NOT the run_flags
        // "captive: check-mark", which only means captive DETECTION is
        // enabled. When the status reports "net ok", the internet works and
        // there is no portal.
        let captive = connected
            && (lowerStatus.contains("captive") || lowerStatus.contains("nok"))

        return TravelmateStatus(
            enabled: enabled,
            statusText: statusText,
            activeSsid: ssid,
            activeDevice: device,
            captive: captive,
            subnet: d["station_subnet"].coercedString ?? ""
        )
    }

    static let empty = TravelmateStatus(
        enabled: false,
        statusText: "",
        activeSsid: "",
        activeDevice: "",
        captive: false,
        subnet: ""
    )
}

struct TravelmateUplink: Sendable, Identifiable, Equatable {
    /// The travelmate uci section id (anonymous, e.g. `cfg0254f8`).
    let sectionId: String
    let ssid: String
    let device: String
    let enabled: Bool

    init(sectionId: String, ssid: String, device: String, enabled: Bool) {
        self.sectionId = sectionId
        self.ssid = ssid
        self.device = device
        self.enabled = enabled
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
            enabled: (section["enabled"].coercedString ?? "1") == "1"
        )
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
