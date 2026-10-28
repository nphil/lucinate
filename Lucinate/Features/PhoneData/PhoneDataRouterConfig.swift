import Foundation

// MARK: - Router state

/// What the router says about Phone Data, read in one go by
/// `RouterService.phoneDataState()`.
struct PhoneDataRouterState: Equatable, Sendable {
    // MARK: USB cable

    /// The packages of `RouterService.phoneDataPackages` that aren't installed yet.
    var missingPackages: [String]
    /// The USB and tunnel interfaces and the phone's tunnel peer all exist, and both
    /// interfaces are in the `wan` firewall zone.
    var configured: Bool
    /// Public key (base64) of the phone the router's tunnel peer points at.
    var configuredPhonePublicKey: String?
    /// The USB network device `phone_usb` is set to use.
    var configuredDevice: String?
    /// The iPhone's USB network device right now; only set while the phone is plugged in.
    var usbDevice: String?
    /// `phone_usb` is up and has an IPv4 address.
    var usbLinkUp: Bool
    /// `phone_wg` is up.
    var tunnelUp: Bool

    // MARK: Wi-Fi

    /// TravelMate (the `travelmate` package) is on the router: its config exists. Wi-Fi sharing
    /// hands the iPhone's hotspot to it, so without it Wi-Fi can't be set up.
    var travelmateInstalled: Bool = false
    /// `phone_wifi`, its phone peer, its place in the `wan` firewall zone, and a TravelMate
    /// uplink for the iPhone's hotspot (with the Wi-Fi station behind it) all exist.
    var wifiConfigured: Bool = false
    /// Name of the iPhone's hotspot, as saved on its TravelMate uplink.
    var wifiSSID: String?
    /// Public key (base64) of the phone the Wi-Fi tunnel's peer points at.
    var wifiPhonePublicKey: String?
    /// `phone_wifi` is up. TravelMate raises it once the router has joined the hotspot.
    var wifiTunnelUp: Bool = false
    /// TravelMate is connected to the iPhone's hotspot right now.
    var wifiUplinkActive: Bool = false
    /// The packages of `RouterService.phoneDataWifiPackages` that aren't installed yet.
    var missingWifiPackages: [String] = []

    var packagesInstalled: Bool { missingPackages.isEmpty }
    var wifiPackagesInstalled: Bool { missingWifiPackages.isEmpty }

    /// Both lists, to hand back to `RouterService.phoneDataState` so a poll can skip reading the
    /// router's package list.
    var missing: PhoneDataMissingPackages {
        PhoneDataMissingPackages(usb: missingPackages, wifi: missingWifiPackages)
    }

    /// Notes that Wi-Fi sharing was just set up for the hotspot `ssid` and the phone with
    /// `phonePublicKey`, for when the router can't be read back: it may already have left the
    /// iPhone's Wi-Fi for the hotspot. What was saved is known all the same.
    mutating func recordWifiSetup(ssid: String, phonePublicKey: String) {
        travelmateInstalled = true
        wifiConfigured = true
        wifiSSID = ssid
        wifiPhonePublicKey = phonePublicKey
        missingWifiPackages = []
    }
}

/// What the router lacks of each set of software. One listing of the router's installed packages
/// answers both, so they are read and remembered together.
struct PhoneDataMissingPackages: Equatable, Sendable {
    /// Of `RouterService.phoneDataPackages`.
    var usb: [String]
    /// Of `RouterService.phoneDataWifiPackages`.
    var wifi: [String]
}

/// A Wi-Fi network the router can see, offered as the iPhone's Personal Hotspot.
struct PhoneDataHotspot: Equatable, Sendable {
    let ssid: String
    /// The radio that saw it ("radio0"): the one the router would join it with.
    let device: String
    /// The uci `encryption` value to join it with ("psk2", "sae-mixed", ...).
    let encryption: String
    /// Signal strength in dBm; nil when the router didn't say.
    let signal: Int?
    /// "2.4 GHz", "5 GHz"; nil when unknown.
    let band: String?

    /// An iPhone names its hotspot after its owner's iPhone ("Nitin's iPhone") until renamed.
    var looksLikeIPhone: Bool { ssid.localizedCaseInsensitiveContains("iphone") }
}

// MARK: - Errors

/// Failures with a plain-language reason of their own. Everything else keeps the wording
/// of the transport (`UbusError`).
enum PhoneDataRouterError: LocalizedError, Equatable {
    /// The firewall has no zone named `wan` to put the interfaces in.
    case noWanZone
    /// The router runs opkg (OpenWrt 24.10 or older).
    case opkgRouter
    /// This login may not change the router's settings.
    case notPermitted
    /// The router has no software manager this login may use (LuCI's luci-app-package-manager
    /// is missing, or the login isn't granted it).
    case packagesNotPermitted
    /// An install whose reply was cut off never showed up in the installed list.
    case installNotConfirmed
    /// The usbmuxd start/stop script isn't on the router.
    case usbSupportMissing
    /// The router refuses to let this app restart the iPhone connection.
    case pairingRestartNotAllowed
    /// Restarting the iPhone connection ran but failed.
    case pairingRestartFailed
    /// Wi-Fi sharing joins the iPhone's hotspot with TravelMate, and the router doesn't have it.
    case travelmateMissing

    var errorDescription: String? {
        switch self {
        case .noWanZone:
            return "This router's firewall has no internet side (a zone named wan), "
                + "so Phone Data can't be set up on it."
        case .opkgRouter:
            return "Phone Data needs a router running OpenWrt 25.12 or newer."
        case .notPermitted:
            return "The router didn't allow that. Sign in with the router's main (root) "
                + "account and try again."
        case .packagesNotPermitted:
            return "This login can't install software on the router. Sign in with the router's "
                + "main (root) account, and make sure the router has LuCI's software manager "
                + "(luci-app-package-manager)."
        case .installNotConfirmed:
            return "The router is still installing. Give it a minute, then try again."
        case .usbSupportMissing:
            return "The USB support isn't installed on the router yet."
        case .pairingRestartNotAllowed:
            return "The router doesn't let this app restart the iPhone connection. "
                + "Unplug the iPhone and plug it back in instead."
        case .pairingRestartFailed:
            return "The router couldn't restart its connection to the iPhone."
        case .travelmateMissing:
            return "Wi-Fi sharing needs TravelMate on the router, and it isn't installed. "
                + "Install the travelmate package on the router, then try again."
        }
    }
}

// MARK: - Staged uci edits

/// One staged uci change. Edits are planned as plain values so what a setup or a removal
/// does can be checked without a router.
enum PhoneDataUciEdit: Equatable, Sendable {
    /// `uci add` of a named section.
    case add(type: String, name: String, values: [String: JSONValue])
    /// `uci set` on a section that exists; list options are written as arrays and replace
    /// the whole list.
    case set(section: String, values: [String: JSONValue])
    /// Drops a whole section.
    case delete(section: String)
    /// Drops one option of a section.
    case deleteOption(section: String, option: String)
}

/// The staged edits of one setup or removal, per uci config.
struct PhoneDataConfigPlan: Equatable, Sendable {
    var network: [PhoneDataUciEdit] = []
    var firewall: [PhoneDataUciEdit] = []
    /// TravelMate's own settings (its global section). The iPhone's uplink and its Wi-Fi
    /// station are saved and removed the way TravelMate's tab does it, not planned here.
    var travelmate: [PhoneDataUciEdit] = []

    var isEmpty: Bool { network.isEmpty && firewall.isEmpty && travelmate.isEmpty }
}

// MARK: - Config logic

/// Everything Phone Data decides about the router's config, as pure functions over the JSON
/// that `uci get` and `network.interface dump` return. `RouterService` only reads, asks these,
/// and runs what they say.
enum PhoneDataRouterConfig {

    // MARK: Names and constants

    /// uci section and interface carrying the iPhone's USB link.
    static let usbInterface = "phone_usb"
    /// uci section and interface of the WireGuard tunnel to the iPhone.
    static let tunnelInterface = "phone_wg"
    /// The tunnel's single peer: the phone.
    static let peerSection = "phone_wg_peer"
    /// WireGuard peers are sections of type `wireguard_<interface>`.
    static let peerSectionType = "wireguard_phone_wg"
    static let peerDescription = "Lucinate Phone Data"
    /// The firewall zone that masquerades traffic to the internet.
    static let wanZoneName = "wan"

    /// uci section and interface of the WireGuard tunnel carried over the iPhone's Wi-Fi hotspot.
    static let wifiInterface = "phone_wifi"
    /// The Wi-Fi tunnel's single peer: the phone.
    static let wifiPeerSection = "phone_wifi_peer"
    static let wifiPeerSectionType = "wireguard_phone_wifi"
    /// Higher than the USB tunnel's, so while both are up the cable carries the traffic.
    static let wifiMetric = 10
    /// What travelmate is told the tunnel is, and which interface it raises after joining the
    /// iPhone's hotspot (and takes down again on any other uplink).
    static let wifiVpnService = "wireguard"
    /// The options of the iPhone's travelmate uplink that hook the Wi-Fi tunnel up to it.
    static let wifiUplinkValues: [String: String] = [
        "vpn": "1", "vpnservice": wifiVpnService, "vpniface": wifiInterface,
    ]
    /// TravelMate's own settings are the one section of this type (`global`).
    static let travelmateSectionType = "travelmate"
    static let travelmateGlobalSection = "global"

    /// The iPhone's side of its USB link, and where Lucinate's WireGuard server listens.
    static let hotspotHost = "172.20.10.1"
    static let hotspotPort = 51820
    static let mtu = 1420
    static let dnsServer = "1.1.1.1"
    /// The two halves of the IPv4 space: more specific than any /0 default route, so while the
    /// tunnel is up it wins over the hotel Wi-Fi without replacing that route.
    static let allowedIPs = ["0.0.0.0/1", "128.0.0.0/1"]
    static let keepAliveSeconds = 25

    /// Directory of the kernel's `ipheth` driver; one entry per USB interface bound to it.
    static let iphethDriverPath = "/sys/bus/usb/drivers/ipheth"

    // MARK: Reading uci

    /// Values of a uci list option. `uci get` reports `list` entries as an array and a plain
    /// `option` as a string, which may hold several space-separated names (the old way of
    /// writing a zone's networks). Missing or empty is `[]`.
    static func listValues(_ option: JSONValue) -> [String] {
        if let items = option.arrayValue {
            return items
                .compactMap { $0.coercedString?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        guard let text = option.coercedString else { return [] }
        return text.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
    }

    /// A firewall zone and the interfaces it holds.
    struct Zone: Equatable, Sendable {
        let section: String
        let networks: [String]
    }

    /// The zone named `wan`, from a `uci get firewall` result.
    static func wanZone(in firewall: JSONValue) -> Zone? {
        for entry in TravelmateConfig.orderedSections(firewall) {
            guard entry.section[".type"].stringValue == "zone",
                entry.section["name"].coercedString == wanZoneName
            else { continue }
            return Zone(section: entry.name, networks: listValues(entry.section["network"]))
        }
        return nil
    }

    /// Sections of the phone's peer type in a `uci get network` result, the one named
    /// `phone_wg_peer` first.
    static func peerSections(in network: JSONValue) -> [String] {
        peerSections(in: network, type: peerSectionType, preferredName: peerSection)
    }

    /// Sections of the Wi-Fi tunnel's peer type, the one named `phone_wifi_peer` first.
    static func wifiPeerSections(in network: JSONValue) -> [String] {
        peerSections(in: network, type: wifiPeerSectionType, preferredName: wifiPeerSection)
    }

    private static func peerSections(
        in network: JSONValue, type: String, preferredName: String
    ) -> [String] {
        let names = TravelmateConfig.orderedSections(network)
            .filter { $0.section[".type"].stringValue == type }
            .map { $0.name }
        return names.filter { $0 == preferredName } + names.filter { $0 != preferredName }
    }

    /// TravelMate's own settings in a `uci get travelmate` result (the section is named `global`).
    static func travelmateGlobal(in travelmate: JSONValue) -> (name: String, section: JSONValue)? {
        TravelmateConfig.orderedSections(travelmate).first {
            $0.section[".type"].stringValue == travelmateSectionType
        }
    }

    /// A saved TravelMate network that carries the Wi-Fi tunnel: the iPhone's hotspot.
    struct WifiUplink: Equatable, Sendable {
        /// The travelmate section (anonymous, `cfg0254f8`).
        let section: String
        let ssid: String
        /// The radio it is joined with.
        let device: String
        let bssid: String
    }

    /// The saved networks whose tunnel is `phone_wifi`, in file order.
    static func wifiUplinks(in travelmate: JSONValue) -> [WifiUplink] {
        TravelmateConfig.orderedSections(travelmate).compactMap { entry -> WifiUplink? in
            guard entry.section[".type"].stringValue == "uplink",
                entry.section["vpniface"].coercedString == wifiInterface
            else { return nil }
            return WifiUplink(
                section: entry.name,
                ssid: entry.section["ssid"].coercedString ?? "",
                device: entry.section["device"].coercedString ?? "",
                bssid: entry.section["bssid"].coercedString ?? "")
        }
    }

    /// The packages of `required` that aren't among the `installed` names, in `required` order.
    static func missingPackages(required: [String], installed: [String]) -> [String] {
        let have = Set(installed)
        return required.filter { !have.contains($0) }
    }

    /// The router's Phone Data state from what was read off it. `missingPackages` is what the
    /// router's installed list lacks of `RouterService.phoneDataPackages`, `missingWifiPackages`
    /// of `RouterService.phoneDataWifiPackages`.
    ///
    /// The Wi-Fi half reads TravelMate's saved networks (`travelmate`, nil when the router has no
    /// such config: the package isn't installed), the Wi-Fi stations behind them (`wireless`) and
    /// TravelMate's status file (`travelmateStatusFile`, empty when there is none). What isn't
    /// given reads as "nothing of Wi-Fi is there".
    static func state(
        network: JSONValue, firewall: JSONValue, interfaceDump: JSONValue,
        travelmate: JSONValue? = nil, wireless: JSONValue = .null,
        travelmateStatusFile: String = "",
        missingPackages: [String], missingWifiPackages: [String] = [], usbDevice: String?
    ) -> PhoneDataRouterState {
        let usb = network[usbInterface]
        let tunnel = network[tunnelInterface]
        let peer = peerSections(in: network).first.map { network[$0] } ?? JSONValue.null

        let inWanZone =
            wanZone(in: firewall).map {
                Set($0.networks).isSuperset(of: [usbInterface, tunnelInterface])
            } ?? false
        let configured =
            usb[".type"].stringValue == "interface"
            && tunnel[".type"].stringValue == "interface"
            && !peer.isNull
            && inWanZone

        let usbEntry = dumpEntry(usbInterface, in: interfaceDump)
        let usbLinkUp = usbEntry.map { $0["up"].boolValue == true && hasIPv4($0) } ?? false
        let tunnelUp = dumpEntry(tunnelInterface, in: interfaceDump)?["up"].boolValue == true

        // Wi-Fi: the iPhone's hotspot is a TravelMate network that carries a tunnel of its own.
        let wifiTunnel = network[wifiInterface]
        let wifiPeer = wifiPeerSections(in: network).first.map { network[$0] } ?? JSONValue.null
        let wifiInWanZone = wanZone(in: firewall).map { $0.networks.contains(wifiInterface) } ?? false
        let uplinks = travelmate.map { wifiUplinks(in: $0) } ?? []
        // A saved network without its wifi-iface can't connect: half of one was saved.
        let joinable = uplinks.filter {
            !TravelmateConfig.staSections(
                in: wireless, ssid: $0.ssid, device: $0.device, bssid: $0.bssid
            ).isEmpty
        }
        let wifiConfigured =
            wifiTunnel[".type"].stringValue == "interface"
            && !wifiPeer.isNull
            && wifiInWanZone
            && !joinable.isEmpty

        let status = TravelmateStatus.fromRuntime(travelmateStatusFile, enabled: true)
        let wifiUplinkActive =
            status.isConnected
            && uplinks.contains {
                !$0.ssid.isEmpty && $0.ssid == status.activeSsid
                    && ($0.device.isEmpty || status.activeDevice.isEmpty
                        || $0.device == status.activeDevice)
            }

        return PhoneDataRouterState(
            missingPackages: missingPackages,
            configured: configured,
            configuredPhonePublicKey: nonEmpty(peer["public_key"].coercedString),
            configuredDevice: nonEmpty(usb["device"].coercedString),
            usbDevice: usbDevice,
            usbLinkUp: usbLinkUp,
            tunnelUp: tunnelUp,
            travelmateInstalled: travelmate != nil,
            wifiConfigured: wifiConfigured,
            wifiSSID: nonEmpty((joinable.first ?? uplinks.first)?.ssid),
            wifiPhonePublicKey: nonEmpty(wifiPeer["public_key"].coercedString),
            wifiTunnelUp: dumpEntry(wifiInterface, in: interfaceDump)?["up"].boolValue == true,
            wifiUplinkActive: wifiUplinkActive,
            missingWifiPackages: missingWifiPackages)
    }

    /// One entry of `network.interface dump`'s `interface[]`.
    private static func dumpEntry(_ name: String, in dump: JSONValue) -> JSONValue? {
        (dump["interface"].arrayValue ?? []).first { $0["interface"].stringValue == name }
    }

    private static func hasIPv4(_ interface: JSONValue) -> Bool {
        (interface["ipv4-address"].arrayValue ?? []).contains {
            !($0["address"].coercedString ?? "").isEmpty
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    // MARK: Finding the iPhone

    /// The USB interfaces the `ipheth` driver is bound to, from the `file list` of its driver
    /// directory. The directory holds those (`1-1:4.2`: bus-port:configuration.interface) next
    /// to the driver's own control files (`bind`, `unbind`, `new_id`, `remove_id`, `uevent`,
    /// `module`), which are not phones.
    static func usbInterfaceNames(inDriverListing listing: JSONValue) -> [String] {
        entryNames(in: listing).filter { isUSBInterfaceName($0) }.sorted()
    }

    static func isUSBInterfaceName(_ name: String) -> Bool {
        name.wholeMatch(of: #/[0-9]+-[0-9]+(?:\.[0-9]+)*:[0-9]+\.[0-9]+/#) != nil
    }

    /// The network device of a USB interface, from the `file list` of its `net` directory,
    /// which holds one entry per device (`eth2`).
    static func netdevName(inNetListing listing: JSONValue) -> String? {
        entryNames(in: listing).sorted().first
    }

    private static func entryNames(in listing: JSONValue) -> [String] {
        (listing["entries"].arrayValue ?? [])
            .compactMap { $0["name"].stringValue }
            .filter { !$0.isEmpty }
    }

    // MARK: Finding the iPhone's hotspot

    /// The scanned networks as hotspot choices: hidden ones left out, one entry per name on
    /// each radio (its strongest), the likely iPhones first and then the strongest signal first.
    static func hotspots(from scans: [WifiScanResult]) -> [PhoneDataHotspot] {
        // A signal of 0 is how a scan says "unknown": weaker than any real one.
        func strength(_ scan: WifiScanResult) -> Int { scan.signal == 0 ? Int.min : scan.signal }

        var strongest: [String: WifiScanResult] = [:]
        for scan in scans where !scan.ssid.isEmpty {
            let key = "\(scan.device)|\(scan.ssid)"
            if let seen = strongest[key], strength(seen) >= strength(scan) { continue }
            strongest[key] = scan
        }
        return strongest.values
            .map { scan in
                PhoneDataHotspot(
                    ssid: scan.ssid, device: scan.device, encryption: scan.encryption,
                    signal: scan.signal == 0 ? nil : scan.signal,
                    band: scan.bandLabel.isEmpty ? nil : scan.bandLabel)
            }
            .sorted { lhs, rhs in
                if lhs.looksLikeIPhone != rhs.looksLikeIPhone { return lhs.looksLikeIPhone }
                let lhsSignal = lhs.signal ?? Int.min
                let rhsSignal = rhs.signal ?? Int.min
                if lhsSignal != rhsSignal { return lhsSignal > rhsSignal }
                if lhs.ssid != rhs.ssid { return lhs.ssid < rhs.ssid }
                return lhs.device < rhs.device
            }
    }

    // MARK: Values to write

    static func usbInterfaceValues(device: String) -> [String: JSONValue] {
        [
            "proto": .string("dhcp"),
            "device": .string(device),
            // The phone's own address and DNS must not become the router's route and resolver:
            // internet traffic goes through the tunnel.
            "defaultroute": .string("0"),
            "peerdns": .string("0"),
        ]
    }

    /// `address` is the router's tunnel address without a mask ("10.7.0.2").
    static func tunnelInterfaceValues(privateKey: String, address: String) -> [String: JSONValue] {
        [
            "proto": .string("wireguard"),
            "private_key": .string(privateKey),
            "addresses": stringList(["\(address)/32"]),
            "mtu": .string(String(mtu)),
            // Ties the tunnel to the USB link: it only comes up while that link is up.
            "tunlink": .string(usbInterface),
            "dns": stringList([dnsServer]),
        ]
    }

    /// The Wi-Fi tunnel. `address` is the router's tunnel address for it, without a mask.
    /// It is not tied to a link and not started at boot (`auto 0`): TravelMate brings it up
    /// once the router has joined the iPhone's hotspot, and down on any other network.
    static func wifiInterfaceValues(privateKey: String, address: String) -> [String: JSONValue] {
        [
            "proto": .string("wireguard"),
            "auto": .string("0"),
            "private_key": .string(privateKey),
            "addresses": stringList(["\(address)/32"]),
            "mtu": .string(String(mtu)),
            "dns": stringList([dnsServer]),
            "metric": .string(String(wifiMetric)),
        ]
    }

    /// The phone, for either tunnel.
    static func peerValues(phonePublicKey: String) -> [String: JSONValue] {
        [
            "description": .string(peerDescription),
            "public_key": .string(phonePublicKey),
            "endpoint_host": .string(hotspotHost),
            "endpoint_port": .string(String(hotspotPort)),
            "allowed_ips": stringList(allowedIPs),
            "route_allowed_ips": .string("1"),
            "persistent_keepalive": .string(String(keepAliveSeconds)),
        ]
    }

    private static func stringList(_ items: [String]) -> JSONValue {
        .array(items.map { JSONValue.string($0) })
    }

    // MARK: Plans

    /// The edits that set Phone Data up, or bring an existing setup up to date: the two
    /// interfaces and the phone's peer, and both interfaces in the `wan` zone (existing members
    /// kept, no duplicates). Sections that are already there are updated, so running it again
    /// is safe, and so is running it with new keys.
    /// - Throws: `PhoneDataRouterError.noWanZone` when the firewall has no `wan` zone.
    static func setupPlan(
        network: JSONValue, firewall: JSONValue,
        usbDevice: String, privateKey: String, address: String, phonePublicKey: String
    ) throws -> PhoneDataConfigPlan {
        guard let zone = wanZone(in: firewall) else { throw PhoneDataRouterError.noWanZone }

        var plan = PhoneDataConfigPlan()
        plan.network += upsert(
            usbInterface, type: "interface",
            values: usbInterfaceValues(device: usbDevice), in: network)
        plan.network += upsert(
            tunnelInterface, type: "interface",
            values: tunnelInterfaceValues(privateKey: privateKey, address: address), in: network)
        plan.network += upsert(
            peerSection, type: peerSectionType,
            values: peerValues(phonePublicKey: phonePublicKey), in: network)
        // The tunnel has one peer. Any other one of its type would fight over the same routes.
        for stray in peerSections(in: network) where stray != peerSection {
            plan.network.append(.delete(section: stray))
        }

        let members = addingMembers([usbInterface, tunnelInterface], to: zone.networks)
        if members != zone.networks {
            plan.firewall.append(
                .set(section: zone.section, values: ["network": stringList(members)]))
        }
        return plan
    }

    /// The edits that take Phone Data off the router: its three sections, and its two names
    /// out of the `wan` zone. Everything the router doesn't have is left out, so a router
    /// without Phone Data gets an empty plan.
    static func removalPlan(network: JSONValue, firewall: JSONValue) -> PhoneDataConfigPlan {
        removalEdits(
            peers: peerSections(in: network), peerName: peerSection,
            interfaces: [tunnelInterface, usbInterface], network: network, firewall: firewall)
    }

    /// The edits behind Wi-Fi sharing, apart from the iPhone's own saved network (the
    /// `wifi-iface` and the TravelMate uplink, which `RouterService` saves the way TravelMate's
    /// tab does, with `wifiUplinkValues` on the uplink):
    /// - `phone_wifi` and its phone peer, in the `network` config. Sections that are there are
    ///   updated, so running it again, also with new keys, is safe.
    /// - `phone_wifi` in the `wan` zone, existing members kept.
    /// - TravelMate's own settings: VPN handling on, and proactive mode on so TravelMate moves
    ///   to the iPhone while on hotel Wi-Fi. Its `trm_vpnifacelist` filter says which tunnels
    ///   TravelMate may touch; without one it takes down every WireGuard tunnel it knows, USB's
    ///   included. An empty list with VPN handling already on means "all", so it is seeded with
    ///   the router's own WireGuard interfaces to keep them handled; an empty list with VPN
    ///   handling off touches nothing yet and gets only the Wi-Fi tunnel. An existing list is
    ///   kept and added to, and the USB tunnel is taken out of it if somebody put it there.
    /// - Throws: `PhoneDataRouterError.noWanZone` when the firewall has no `wan` zone.
    static func wifiSetupPlan(
        network: JSONValue, firewall: JSONValue, travelmate: JSONValue,
        privateKey: String, address: String, phonePublicKey: String
    ) throws -> PhoneDataConfigPlan {
        guard let zone = wanZone(in: firewall) else { throw PhoneDataRouterError.noWanZone }

        var plan = PhoneDataConfigPlan()
        plan.network += upsert(
            wifiInterface, type: "interface",
            values: wifiInterfaceValues(privateKey: privateKey, address: address), in: network)
        plan.network += upsert(
            wifiPeerSection, type: wifiPeerSectionType,
            values: peerValues(phonePublicKey: phonePublicKey), in: network)
        // The tunnel has one peer. Any other one of its type would fight over the same routes.
        for stray in wifiPeerSections(in: network) where stray != wifiPeerSection {
            plan.network.append(.delete(section: stray))
        }

        let members = addingMembers([wifiInterface], to: zone.networks)
        if members != zone.networks {
            plan.firewall.append(
                .set(section: zone.section, values: ["network": stringList(members)]))
        }

        plan.travelmate = wifiTravelmateEdits(travelmate: travelmate, network: network)
        return plan
    }

    /// TravelMate's side of `wifiSetupPlan`.
    private static func wifiTravelmateEdits(
        travelmate: JSONValue, network: JSONValue
    ) -> [PhoneDataUciEdit] {
        let existing = travelmateGlobal(in: travelmate)
        let global = existing?.section ?? JSONValue.null

        var tunnels = listValues(global["trm_vpnifacelist"])
        if tunnels.isEmpty, global["trm_vpn"].coercedString == "1" {
            tunnels = otherWireGuardInterfaces(in: network)
        }
        // TravelMate takes down the tunnels it handles when it isn't on their uplink. The USB
        // tunnel has its own link and must never be one of them.
        tunnels.removeAll { $0 == tunnelInterface }
        if !tunnels.contains(wifiInterface) { tunnels.append(wifiInterface) }

        let values: [String: JSONValue] = [
            "trm_vpn": .string("1"),
            "trm_proactive": .string("1"),
            "trm_vpnifacelist": stringList(tunnels),
        ]
        guard let existing else {
            return [.add(type: travelmateSectionType, name: travelmateGlobalSection, values: values)]
        }
        return [.set(section: existing.name, values: values)]
    }

    /// WireGuard interfaces of the router that are neither of Phone Data's, in file order.
    private static func otherWireGuardInterfaces(in network: JSONValue) -> [String] {
        TravelmateConfig.orderedSections(network).compactMap { entry -> String? in
            guard entry.section[".type"].stringValue == "interface",
                entry.section["proto"].coercedString == "wireguard",
                entry.name != tunnelInterface, entry.name != wifiInterface
            else { return nil }
            return entry.name
        }
    }

    /// The edits that take Wi-Fi sharing off the router, apart from the iPhone's saved network
    /// (`wifiUplinks`, which `RouterService` removes the way TravelMate's tab does):
    /// `phone_wifi` and its peer, `phone_wifi` out of the `wan` zone, and out of TravelMate's
    /// `trm_vpnifacelist`. When that list is left empty the option goes (`uci set` refuses an
    /// empty list) and VPN handling is switched off again, unless a saved network other than the
    /// iPhone's still wants a tunnel. Everything the router doesn't have is left out, so a router
    /// without Wi-Fi sharing gets an empty plan.
    static func wifiRemovalPlan(
        network: JSONValue, firewall: JSONValue, travelmate: JSONValue
    ) -> PhoneDataConfigPlan {
        var plan = removalEdits(
            peers: wifiPeerSections(in: network), peerName: wifiPeerSection,
            interfaces: [wifiInterface], network: network, firewall: firewall)
        plan.travelmate = wifiTravelmateRemovalEdits(travelmate: travelmate)
        return plan
    }

    private static func wifiTravelmateRemovalEdits(travelmate: JSONValue) -> [PhoneDataUciEdit] {
        guard let global = travelmateGlobal(in: travelmate) else { return [] }
        let tunnels = listValues(global.section["trm_vpnifacelist"])
        guard tunnels.contains(wifiInterface) else { return [] }

        let remaining = tunnels.filter { $0 != wifiInterface }
        if !remaining.isEmpty {
            return [.set(section: global.name, values: ["trm_vpnifacelist": stringList(remaining)])]
        }

        var edits: [PhoneDataUciEdit] = [
            .deleteOption(section: global.name, option: "trm_vpnifacelist")
        ]
        let otherUplinkWantsTunnel = TravelmateConfig.orderedSections(travelmate).contains {
            $0.section[".type"].stringValue == "uplink"
                && $0.section["vpniface"].coercedString != wifiInterface
                && $0.section["vpn"].coercedString == "1"
        }
        if !otherUplinkWantsTunnel, global.section["trm_vpn"].coercedString == "1" {
            edits.append(.set(section: global.name, values: ["trm_vpn": .string("0")]))
        }
        return edits
    }

    /// The order `uci order` has to give the `wireless` config so TravelMate prefers the
    /// iPhone: it tries saved networks in the order of their `mode sta` wifi-ifaces, so the
    /// iPhone's goes before every other one. The answer lists every section of the config
    /// (`uci order` moves each section it is given to its place in the list), with the iPhone's
    /// moved to where the first other station was and nothing else moved. Nil when nothing needs
    /// to move: it is first already, no other station exists, or the section isn't there. Also
    /// nil when the router doesn't say where every section stands, since an order guessed from
    /// section names would scramble the file.
    static func wirelessOrder(wireless: JSONValue, phoneSection: String) -> [String]? {
        let entries = TravelmateConfig.orderedSections(wireless)
        guard entries.allSatisfy({ $0.section[".index"].intValue != nil }) else { return nil }
        let names = entries.map { $0.name }
        guard let phoneAt = names.firstIndex(of: phoneSection) else { return nil }
        let firstOtherStation = entries.firstIndex {
            $0.name != phoneSection
                && $0.section[".type"].stringValue == "wifi-iface"
                && $0.section["mode"].coercedString == "sta"
        }
        guard let firstOtherStation, firstOtherStation < phoneAt else { return nil }

        var order = names
        order.remove(at: phoneAt)
        order.insert(phoneSection, at: firstOtherStation)
        return order
    }

    /// Deletes the peer sections and interfaces that are there, and takes the interfaces out of
    /// the `wan` zone.
    private static func removalEdits(
        peers: [String], peerName: String, interfaces: [String],
        network: JSONValue, firewall: JSONValue
    ) -> PhoneDataConfigPlan {
        var doomed = peers
        // The name is ours even when something else of another type sits under it.
        if network[peerName].objectValue != nil, !doomed.contains(peerName) {
            doomed.append(peerName)
        }
        for name in interfaces where network[name].objectValue != nil {
            doomed.append(name)
        }

        var plan = PhoneDataConfigPlan()
        plan.network = doomed.map { PhoneDataUciEdit.delete(section: $0) }

        if let zone = wanZone(in: firewall) {
            let remaining = removingMembers(interfaces, from: zone.networks)
            if remaining != zone.networks {
                // `uci set` refuses an empty list: an emptied option is deleted instead.
                plan.firewall.append(
                    remaining.isEmpty
                        ? .deleteOption(section: zone.section, option: "network")
                        : .set(section: zone.section, values: ["network": stringList(remaining)]))
            }
        }
        return plan
    }

    /// `uci set` when the section is there (the router only sets sections that exist),
    /// `uci add` when it isn't.
    private static func upsert(
        _ name: String, type: String, values: [String: JSONValue], in config: JSONValue
    ) -> [PhoneDataUciEdit] {
        let existing = config[name]
        if existing[".type"].stringValue == type {
            return [.set(section: name, values: values)]
        }
        let add = PhoneDataUciEdit.add(type: type, name: name, values: values)
        // The name is ours: a section of another type under it is swapped out, not reused.
        return existing.objectValue == nil ? [add] : [.delete(section: name), add]
    }

    private static func addingMembers(_ names: [String], to members: [String]) -> [String] {
        var result = members
        for name in names where !result.contains(name) {
            result.append(name)
        }
        return result
    }

    private static func removingMembers(_ names: [String], from members: [String]) -> [String] {
        members.filter { !names.contains($0) }
    }
}
