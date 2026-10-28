import Foundation

// MARK: - Router state

/// What the router says about Phone Data, read in one go by
/// `RouterService.phoneDataState()`.
struct PhoneDataRouterState: Equatable, Sendable {
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

    var packagesInstalled: Bool { missingPackages.isEmpty }
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

    var isEmpty: Bool { network.isEmpty && firewall.isEmpty }
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
        let names = TravelmateConfig.orderedSections(network)
            .filter { $0.section[".type"].stringValue == peerSectionType }
            .map { $0.name }
        return names.filter { $0 == peerSection } + names.filter { $0 != peerSection }
    }

    /// The packages of `required` that aren't among the `installed` names, in `required` order.
    static func missingPackages(required: [String], installed: [String]) -> [String] {
        let have = Set(installed)
        return required.filter { !have.contains($0) }
    }

    /// The router's Phone Data state from what was read off it. `missingPackages` is what the
    /// router's installed list lacks of `RouterService.phoneDataPackages`.
    static func state(
        network: JSONValue, firewall: JSONValue, interfaceDump: JSONValue,
        missingPackages: [String], usbDevice: String?
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

        return PhoneDataRouterState(
            missingPackages: missingPackages,
            configured: configured,
            configuredPhonePublicKey: nonEmpty(peer["public_key"].coercedString),
            configuredDevice: nonEmpty(usb["device"].coercedString),
            usbDevice: usbDevice,
            usbLinkUp: usbLinkUp,
            tunnelUp: tunnelUp)
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
        var doomed = peerSections(in: network)
        // The name is ours even when something else of another type sits under it.
        if network[peerSection].objectValue != nil, !doomed.contains(peerSection) {
            doomed.append(peerSection)
        }
        for name in [tunnelInterface, usbInterface] where network[name].objectValue != nil {
            doomed.append(name)
        }

        var plan = PhoneDataConfigPlan()
        plan.network = doomed.map { PhoneDataUciEdit.delete(section: $0) }

        if let zone = wanZone(in: firewall) {
            let remaining = removingMembers([usbInterface, tunnelInterface], from: zone.networks)
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
