import Foundation

/// A wireless interface (SSID broadcast or STA uplink) as reported by
/// luci-rpc `getWirelessDevices`.
struct WirelessNetwork: Sendable, Identifiable, Equatable {
    /// ifname when available, else the uci section name.
    let id: String
    let ssid: String
    /// Kernel interface name, e.g. "phy0-ap0".
    let device: String
    /// The owning radio, e.g. "radio0".
    let radio: String
    /// "ap", "sta", "mesh", ...
    let mode: String
    let channel: Int?
    /// Signal in dBm (STA/iwinfo).
    let signal: Int?
    /// "2g" / "5g" / "6g".
    let band: String?
    let disabled: Bool
    /// uci wifi-iface section name.
    let section: String?
    /// The attached network (e.g. "lan").
    let network: String?
    let encryption: String?

    init(
        id: String,
        ssid: String,
        device: String,
        radio: String,
        mode: String,
        channel: Int? = nil,
        signal: Int? = nil,
        band: String? = nil,
        disabled: Bool = false,
        section: String? = nil,
        network: String? = nil,
        encryption: String? = nil
    ) {
        self.id = id
        self.ssid = ssid
        self.device = device
        self.radio = radio
        self.mode = mode
        self.channel = channel
        self.signal = signal
        self.band = band
        self.disabled = disabled
        self.section = section
        self.network = network
        self.encryption = encryption
    }

    /// "2.4 GHz" / "5 GHz" / "6 GHz" / "" — from `band`, else a channel heuristic.
    var bandLabel: String {
        switch band {
        case "2g": return "2.4 GHz"
        case "5g": return "5 GHz"
        case "6g": return "6 GHz"
        default:
            if let channel { return channel > 14 ? "5 GHz" : "2.4 GHz" }
            return ""
        }
    }

    /// A STA interface repeats an upstream network; an AP is one the router broadcasts.
    var isUplink: Bool { mode == "sta" }

    /// "Broadcast" (AP the router transmits) or "Uplink" (STA it repeats).
    var roleLabel: String { isUplink ? "Uplink" : "Broadcast" }

    /// Parses the full luci-rpc `getWirelessDevices` payload: an object keyed
    /// by radio name ("radio0", ...), each with a `config` object and an
    /// `interfaces[]` array (entries carrying `ifname`, `section`, `config`
    /// {ssid, mode, disabled, network, encryption} and `iwinfo`
    /// {ssid, channel, signal}).
    static func fromWirelessDevices(_ json: JSONValue) -> [WirelessNetwork] {
        guard let radios = json.objectValue else { return [] }
        var networks: [WirelessNetwork] = []

        for (radioName, radioData) in radios {
            let radioConfig = radioData["config"]
            let radioBand = radioConfig["band"].coercedString?.lowercased()
            let radioChannel = radioConfig["channel"].intValue
            let radioDisabled = radioConfig["disabled"].boolValue ?? false

            guard let interfaces = radioData["interfaces"].arrayValue else { continue }
            for iface in interfaces {
                let config = iface["config"]
                let iwinfo = iface["iwinfo"]

                let ifname = iface["ifname"].coercedString
                let section = iface["section"].coercedString

                let ssid = iwinfo["ssid"].coercedString
                    ?? config["ssid"].coercedString
                    ?? ""
                let mode = (config["mode"].coercedString
                    ?? iwinfo["mode"].coercedString
                    ?? "").lowercased()
                let channel = iwinfo["channel"].intValue ?? radioChannel
                let signal = iwinfo["signal"].intValue
                let disabled = (config["disabled"].boolValue ?? false) || radioDisabled

                // `network` may be a string or a list of network names.
                var network = config["network"].coercedString
                if network == nil, let list = config["network"].arrayValue {
                    network = list.compactMap { $0.coercedString }.first
                }

                var band = radioBand
                if band == nil || band?.isEmpty == true {
                    if let channel {
                        band = channel > 14 ? "5g" : "2g"
                    } else {
                        band = nil
                    }
                }

                guard let identifier = ifname ?? section else { continue }
                networks.append(
                    WirelessNetwork(
                        id: identifier,
                        ssid: ssid,
                        device: ifname ?? "",
                        radio: radioName,
                        mode: mode,
                        channel: channel,
                        signal: signal,
                        band: band,
                        disabled: disabled,
                        section: section,
                        network: network,
                        encryption: config["encryption"].coercedString
                    )
                )
            }
        }

        // Stable ordering: by radio, then id (dictionaries are unordered).
        networks.sort {
            if $0.radio != $1.radio { return $0.radio < $1.radio }
            return $0.id < $1.id
        }
        return networks
    }
}
