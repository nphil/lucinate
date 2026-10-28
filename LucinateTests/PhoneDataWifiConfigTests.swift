import XCTest

@testable import Lucinate

/// Phone Data over Wi-Fi: what the router's config has to say, what setup and removal write, and
/// how the iPhone's hotspot is found and put first.
final class PhoneDataWifiConfigTests: XCTestCase {

    private typealias Config = PhoneDataRouterConfig
    private typealias Entry = (name: String, value: JSONValue)

    // MARK: - Fixtures

    private func s(_ text: String) -> JSONValue { .string(text) }

    private func strings(_ items: [String]) -> JSONValue {
        .array(items.map { JSONValue.string($0) })
    }

    /// One section of a `uci get` result: its options, and the `.type`, `.name` and `.index`
    /// the router adds.
    private func section(
        _ name: String, _ type: String, index: Int, _ options: [String: JSONValue] = [:]
    ) -> Entry {
        var values = options
        values[".type"] = s(type)
        values[".name"] = s(name)
        values[".index"] = .number(Double(index))
        return (name, .object(values))
    }

    private func config(_ sections: [Entry]) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: sections.map { ($0.name, $0.value) }))
    }

    // network

    private func lan() -> Entry {
        section("lan", "interface", index: 0, ["proto": s("static"), "device": s("br-lan")])
    }

    private func wireGuard(_ name: String, index: Int) -> Entry {
        section(name, "interface", index: index, ["proto": s("wireguard")])
    }

    private func usbTunnel() -> Entry {
        section(
            "phone_wg", "interface", index: 3,
            ["proto": s("wireguard"), "tunlink": s("phone_usb")])
    }

    private func wifiTunnel() -> Entry {
        section("phone_wifi", "interface", index: 5, ["proto": s("wireguard"), "auto": s("0")])
    }

    private func wifiPeer(name: String = "phone_wifi_peer", key: String = "PHONEPUB=") -> Entry {
        section(name, "wireguard_phone_wifi", index: 6, ["public_key": s(key)])
    }

    /// A router that is set up for Wi-Fi.
    private func wifiNetwork() -> JSONValue {
        config([lan(), wifiTunnel(), wifiPeer()])
    }

    // firewall

    private func firewall(wan: [String] = ["wan", "wan6"]) -> JSONValue {
        config([
            section("cfg01e63d", "defaults", index: 0, ["input": s("REJECT")]),
            section("cfg02dc81", "zone", index: 1, ["name": s("lan"), "network": strings(["lan"])]),
            section(
                "cfg03dc81", "zone", index: 2,
                ["name": s("wan"), "masq": s("1"), "network": strings(wan)]),
        ])
    }

    // travelmate

    /// `uci get travelmate`. `list` is the global `trm_vpnifacelist`, as an array or a plain string.
    private func travelmate(
        vpn: String? = nil, list: JSONValue? = nil, uplinks: [Entry] = []
    ) -> JSONValue {
        var options: [String: JSONValue] = ["trm_enabled": s("1"), "trm_proactive": s("0")]
        if let vpn { options["trm_vpn"] = s(vpn) }
        if let list { options["trm_vpnifacelist"] = list }
        return config([section("global", "travelmate", index: 0, options)] + uplinks)
    }

    private func uplink(
        _ name: String, index: Int, ssid: String, device: String,
        vpniface: String? = nil, vpn: String? = nil
    ) -> Entry {
        var options: [String: JSONValue] = ["enabled": s("1"), "device": s(device), "ssid": s(ssid)]
        if let vpniface {
            options["vpniface"] = s(vpniface)
            options["vpnservice"] = s("wireguard")
        }
        if let vpn { options["vpn"] = s(vpn) }
        return section(name, "uplink", index: index, options)
    }

    private let hotspotName = "Nitin's iPhone"

    private func phoneUplink(index: Int = 2) -> Entry {
        uplink(
            "cfg0b", index: index, ssid: hotspotName, device: "radio1", vpniface: "phone_wifi",
            vpn: "1")
    }

    /// Travelmate as Wi-Fi setup leaves it.
    private func wifiTravelmate() -> JSONValue {
        travelmate(
            vpn: "1", list: strings(["phone_wifi"]),
            uplinks: [uplink("cfg0a", index: 1, ssid: "Hotel", device: "radio0"), phoneUplink()])
    }

    // wireless

    private func radio(_ name: String, index: Int) -> Entry {
        section(name, "wifi-device", index: index)
    }

    private func accessPoint(_ name: String, index: Int, device: String) -> Entry {
        section(
            name, "wifi-iface", index: index,
            ["device": s(device), "mode": s("ap"), "ssid": s("Home")])
    }

    private func station(_ name: String, index: Int, device: String, ssid: String) -> Entry {
        section(
            name, "wifi-iface", index: index,
            ["device": s(device), "mode": s("sta"), "ssid": s(ssid)])
    }

    /// The router's Wi-Fi with its own two networks and the iPhone's station.
    private func wifiWireless(phoneDevice: String = "radio1") -> JSONValue {
        config([
            radio("radio0", index: 0), radio("radio1", index: 1),
            accessPoint("default_radio0", index: 2, device: "radio0"),
            station("trm_uplink1", index: 4, device: "radio0", ssid: "Hotel"),
            station("trm_uplink3", index: 5, device: phoneDevice, ssid: hotspotName),
        ])
    }

    // runtime

    private func dump(wifiUp: Bool?) -> JSONValue {
        var entries: [JSONValue] = [.object(["interface": s("lan"), "up": .bool(true)])]
        if let wifiUp {
            entries.append(
                .object(["interface": s("phone_wifi"), "up": .bool(wifiUp), "proto": s("wireguard")]))
        }
        return .object(["interface": .array(entries)])
    }

    /// TravelMate's status file.
    private func statusFile(_ status: String, station: String) -> String {
        #"{"data": {"travelmate_status": "\#(status)", "station_id": "\#(station)", "station_subnet": "172.20.10.0/28 (lan: 192.168.1.0/24)"}}"#
    }

    private let phoneStation = "radio1/Nitin's iPhone/FE:4D:3A:91:2C:07"

    private func wifiState(
        network: JSONValue? = nil, wan: [String] = ["wan", "phone_wifi"],
        wifiUp: Bool? = nil, travelmate: JSONValue? = nil, withoutTravelmate: Bool = false,
        wireless: JSONValue? = nil, statusFile: String = "", missingWifi: [String] = []
    ) -> PhoneDataRouterState {
        Config.state(
            network: network ?? wifiNetwork(), firewall: firewall(wan: wan),
            interfaceDump: dump(wifiUp: wifiUp),
            travelmate: withoutTravelmate ? nil : (travelmate ?? wifiTravelmate()),
            wireless: wireless ?? wifiWireless(),
            travelmateStatusFile: statusFile,
            missingPackages: [], missingWifiPackages: missingWifi, usbDevice: nil)
    }

    private func setupPlan(
        network: JSONValue? = nil, wan: [String] = ["wan", "wan6"], travelmate: JSONValue? = nil
    ) throws -> PhoneDataConfigPlan {
        try Config.wifiSetupPlan(
            network: network ?? config([lan()]), firewall: firewall(wan: wan),
            travelmate: travelmate ?? self.travelmate(),
            privateKey: "ROUTERPRIV=", address: "10.7.0.3", phonePublicKey: "PHONEPUB=")
    }

    /// The `trm_vpnifacelist` a setup writes.
    private func writtenList(_ plan: PhoneDataConfigPlan) throws -> [String] {
        guard case .set(_, let values)? = plan.travelmate.first else {
            XCTFail("travelmate's settings are not set")
            return []
        }
        return Config.listValues(values["trm_vpnifacelist"] ?? .null)
    }

    // MARK: - What setup writes

    func testWiFiSetupOnAFreshRouterAddsTheTunnelItsPeerAndAZoneMember() throws {
        let plan = try setupPlan()

        // No `tunlink`: nothing ties the tunnel to a link. Not started at boot, and USB's
        // routes (metric 0) win while both are up.
        let tunnel: [String: JSONValue] = [
            "proto": s("wireguard"),
            "auto": s("0"),
            "private_key": s("ROUTERPRIV="),
            "addresses": strings(["10.7.0.3/32"]),
            "mtu": s("1420"),
            "dns": strings(["1.1.1.1"]),
            "metric": s("10"),
        ]
        let expectedNetwork: [PhoneDataUciEdit] = [
            .add(type: "interface", name: "phone_wifi", values: tunnel),
            // The phone, exactly as the cable's tunnel has it.
            .add(
                type: "wireguard_phone_wifi", name: "phone_wifi_peer",
                values: Config.peerValues(phonePublicKey: "PHONEPUB=")),
        ]
        XCTAssertEqual(plan.network, expectedNetwork)
        XCTAssertEqual(
            plan.firewall,
            [.set(section: "cfg03dc81", values: ["network": strings(["wan", "wan6", "phone_wifi"])])])
        XCTAssertEqual(
            plan.travelmate,
            [
                .set(
                    section: "global",
                    values: [
                        "trm_vpn": s("1"),
                        "trm_proactive": s("1"),
                        "trm_vpnifacelist": strings(["phone_wifi"]),
                    ])
            ])
    }

    func testWiFiSetupOnAConfiguredRouterUpdatesItInPlaceWithTheNewValues() throws {
        let plan = try setupPlan(
            network: wifiNetwork(), wan: ["wan", "phone_wifi"],
            travelmate: wifiTravelmate())

        let expectedNetwork: [PhoneDataUciEdit] = [
            .set(
                section: "phone_wifi",
                values: Config.wifiInterfaceValues(privateKey: "ROUTERPRIV=", address: "10.7.0.3")),
            .set(
                section: "phone_wifi_peer",
                values: Config.peerValues(phonePublicKey: "PHONEPUB=")),
        ]
        XCTAssertEqual(plan.network, expectedNetwork)
        // Already a member of the zone: nothing to change there.
        XCTAssertEqual(plan.firewall, [])
        // Already in the list: not added twice.
        XCTAssertEqual(try writtenList(plan), ["phone_wifi"])
    }

    func testTheZoneKeepsItsMembersAndTheWiFiTunnelJoinsAfterThem() throws {
        let plan = try setupPlan(wan: ["wan", "phone_wg", "travel_wan"])
        XCTAssertEqual(
            plan.firewall,
            [
                .set(
                    section: "cfg03dc81",
                    values: ["network": strings(["wan", "phone_wg", "travel_wan", "phone_wifi"])])
            ])
    }

    func testWiFiSetupNeedsAWanZone() throws {
        let lanOnly = config([
            section("cfg02", "zone", index: 0, ["name": s("lan"), "network": strings(["lan"])])
        ])
        XCTAssertThrowsError(
            try Config.wifiSetupPlan(
                network: config([lan()]), firewall: lanOnly, travelmate: travelmate(),
                privateKey: "K=", address: "10.7.0.3", phonePublicKey: "P=")
        ) { error in
            XCTAssertEqual(error as? PhoneDataRouterError, .noWanZone)
        }
    }

    func testOtherPeersOfTheWiFiTunnelAreDroppedAndAForeignSectionUnderOurNameIsReplaced() throws {
        let network = config([
            lan(), wifiTunnel(),
            section("cfg0a1b2c", "wireguard_phone_wifi", index: 6, ["public_key": s("OLD=")]),
            section("phone_wifi_peer", "wireguard_other", index: 7, ["public_key": s("ODD=")]),
            // The cable's peer is not the Wi-Fi tunnel's business.
            section("phone_wg_peer", "wireguard_phone_wg", index: 8, ["public_key": s("USB=")]),
        ])
        let plan = try setupPlan(network: network)

        // A stray peer of the tunnel would fight over the same routes.
        XCTAssertTrue(plan.network.contains(.delete(section: "cfg0a1b2c")))
        // The foreign section is swapped for ours, not edited into shape.
        XCTAssertTrue(plan.network.contains(.delete(section: "phone_wifi_peer")))
        let peerAdds = plan.network.filter {
            if case .add(_, "phone_wifi_peer", _) = $0 { return true }
            return false
        }
        XCTAssertEqual(peerAdds.count, 1)
        XCTAssertFalse(plan.network.contains(.delete(section: "phone_wg_peer")))
        XCTAssertTrue(
            plan.network.contains(
                .set(
                    section: "phone_wifi",
                    values: Config.wifiInterfaceValues(
                        privateKey: "ROUTERPRIV=", address: "10.7.0.3"))))
    }

    func testTheHotspotsUplinkIsTheOneThatHooksUpTheTunnel() {
        XCTAssertEqual(
            Config.wifiUplinkValues,
            ["vpn": "1", "vpnservice": "wireguard", "vpniface": "phone_wifi"])
    }

    // MARK: - TravelMate's tunnel list

    func testAnEmptyListWithVPNHandlingOffGetsOnlyTheWiFiTunnel() throws {
        // Nothing is handled yet, so nothing needs keeping handled: the router's own tunnel
        // is left to whoever turns VPN handling on.
        let network = config([lan(), wireGuard("wg0", index: 1), usbTunnel()])
        for vpn in [nil, "0"] as [String?] {
            let plan = try setupPlan(network: network, travelmate: travelmate(vpn: vpn))
            XCTAssertEqual(try writtenList(plan), ["phone_wifi"], "trm_vpn \(vpn ?? "unset")")
        }
    }

    func testAnEmptyListWithVPNHandlingOnKeepsTheRoutersOwnTunnelsHandled() throws {
        // On and empty means "every WireGuard tunnel", and that is what the router has been
        // doing: the list says so before the Wi-Fi tunnel joins it. The cable's tunnel never does.
        let network = config([
            lan(), wireGuard("wg0", index: 1), wireGuard("office", index: 2), usbTunnel(),
        ])
        let plan = try setupPlan(network: network, travelmate: travelmate(vpn: "1"))
        XCTAssertEqual(try writtenList(plan), ["wg0", "office", "phone_wifi"])
    }

    func testAnEmptyListWithVPNHandlingOnAndNoOtherTunnelGetsOnlyTheWiFiTunnel() throws {
        let network = config([lan(), usbTunnel(), wifiTunnel()])
        let plan = try setupPlan(network: network, travelmate: travelmate(vpn: "1"))
        XCTAssertEqual(try writtenList(plan), ["phone_wifi"])
    }

    func testAnExistingListIsAddedToWithoutADuplicate() throws {
        let network = config([lan(), wireGuard("wg0", index: 1), wireGuard("office", index: 2)])

        // Nothing is seeded from the router's tunnels: the list is the user's.
        let added = try setupPlan(
            network: network, travelmate: travelmate(vpn: "1", list: strings(["wg0"])))
        XCTAssertEqual(try writtenList(added), ["wg0", "phone_wifi"])

        let already = try setupPlan(
            network: network,
            travelmate: travelmate(vpn: "1", list: strings(["wg0", "phone_wifi", "office"])))
        XCTAssertEqual(try writtenList(already), ["wg0", "phone_wifi", "office"])
    }

    func testAListWrittenAsOneStringIsRead() throws {
        let plan = try setupPlan(
            network: config([lan()]), travelmate: travelmate(vpn: "1", list: s("wg0 office")))
        XCTAssertEqual(try writtenList(plan), ["wg0", "office", "phone_wifi"])
    }

    func testTheCablesTunnelIsNeverInTheList() throws {
        // Travelmate takes down the tunnels in its list when it isn't on their uplink, and
        // the cable's has to stay up whatever the router is joined to.
        let plan = try setupPlan(
            travelmate: travelmate(vpn: "1", list: strings(["phone_wg", "wg0"])))
        XCTAssertEqual(try writtenList(plan), ["wg0", "phone_wifi"])
    }

    func testTheWiFiTunnelItselfIsNotSeededAsAnotherInterface() throws {
        let network = config([lan(), wireGuard("wg0", index: 1), wifiTunnel()])
        let plan = try setupPlan(network: network, travelmate: travelmate(vpn: "1"))
        XCTAssertEqual(try writtenList(plan), ["wg0", "phone_wifi"])
    }

    func testVPNHandlingAndProactiveModeAreSwitchedOn() throws {
        let plan = try setupPlan(travelmate: travelmate(vpn: "0"))
        guard case .set(let name, let values)? = plan.travelmate.first else {
            return XCTFail("travelmate's settings are not set")
        }
        XCTAssertEqual(name, "global")
        XCTAssertEqual(values["trm_vpn"], s("1"))
        XCTAssertEqual(values["trm_proactive"], s("1"))
    }

    func testWithoutASettingsSectionTravelmateGetsOne() throws {
        let noGlobal = config([uplink("cfg0a", index: 0, ssid: "Hotel", device: "radio0")])
        let plan = try setupPlan(travelmate: noGlobal)
        XCTAssertEqual(
            plan.travelmate,
            [
                .add(
                    type: "travelmate", name: "global",
                    values: [
                        "trm_vpn": s("1"),
                        "trm_proactive": s("1"),
                        "trm_vpnifacelist": strings(["phone_wifi"]),
                    ])
            ])
    }

    // MARK: - What removal writes

    func testWiFiRemovalDeletesTheTunnelAndItsPeerAndLeavesTheCableAlone() throws {
        let network = config([
            lan(),
            section("phone_usb", "interface", index: 2, ["proto": s("dhcp"), "device": s("eth2")]),
            usbTunnel(),
            section("phone_wg_peer", "wireguard_phone_wg", index: 4, ["public_key": s("USB=")]),
            wifiTunnel(), wifiPeer(),
        ])
        let plan = Config.wifiRemovalPlan(
            network: network,
            firewall: firewall(wan: ["wan", "phone_usb", "phone_wifi", "phone_wg"]),
            travelmate: wifiTravelmate())

        XCTAssertEqual(
            plan.network, [.delete(section: "phone_wifi_peer"), .delete(section: "phone_wifi")])
        XCTAssertEqual(
            plan.firewall,
            [
                .set(
                    section: "cfg03dc81",
                    values: ["network": strings(["wan", "phone_usb", "phone_wg"])])
            ])
    }

    func testRemovalLeavesTheListOfTheRoutersOwnTunnelsAlone() {
        let settings = travelmate(
            vpn: "1", list: strings(["wg0", "phone_wifi"]), uplinks: [phoneUplink()])
        let plan = Config.wifiRemovalPlan(
            network: wifiNetwork(), firewall: firewall(wan: ["wan", "phone_wifi"]),
            travelmate: settings)
        // Only the Wi-Fi tunnel leaves the list, and VPN handling stays on for the others.
        XCTAssertEqual(
            plan.travelmate,
            [.set(section: "global", values: ["trm_vpnifacelist": strings(["wg0"])])])
    }

    func testRemovalDropsAnEmptiedListAndSwitchesVPNHandlingOffAgain() {
        let settings = travelmate(
            vpn: "1", list: strings(["phone_wifi"]),
            uplinks: [uplink("cfg0a", index: 1, ssid: "Hotel", device: "radio0"), phoneUplink()])
        let plan = Config.wifiRemovalPlan(
            network: wifiNetwork(), firewall: firewall(wan: ["wan", "phone_wifi"]),
            travelmate: settings)
        // `uci set` refuses an empty list: the option is deleted.
        XCTAssertEqual(
            plan.travelmate,
            [
                .deleteOption(section: "global", option: "trm_vpnifacelist"),
                .set(section: "global", values: ["trm_vpn": s("0")]),
            ])
    }

    func testRemovalKeepsVPNHandlingOnWhileAnotherNetworkStillWantsATunnel() {
        let settings = travelmate(
            vpn: "1", list: strings(["phone_wifi"]),
            uplinks: [
                uplink("cfg0a", index: 1, ssid: "Hotel", device: "radio0", vpniface: "wg0", vpn: "1"),
                phoneUplink(),
            ])
        let plan = Config.wifiRemovalPlan(
            network: wifiNetwork(), firewall: firewall(wan: ["wan", "phone_wifi"]),
            travelmate: settings)
        XCTAssertEqual(
            plan.travelmate, [.deleteOption(section: "global", option: "trm_vpnifacelist")])
    }

    func testRemovalDoesNotSwitchOffWhatIsOffAlready() {
        let settings = travelmate(vpn: "0", list: strings(["phone_wifi"]))
        let plan = Config.wifiRemovalPlan(
            network: wifiNetwork(), firewall: firewall(), travelmate: settings)
        XCTAssertEqual(
            plan.travelmate, [.deleteOption(section: "global", option: "trm_vpnifacelist")])
    }

    func testRemovalLeavesTravelmateAloneWhenTheTunnelWasNotInItsList() {
        for list in [nil, strings(["wg0"])] as [JSONValue?] {
            let plan = Config.wifiRemovalPlan(
                network: wifiNetwork(), firewall: firewall(),
                travelmate: travelmate(vpn: "1", list: list))
            XCTAssertEqual(plan.travelmate, [])
        }
        XCTAssertEqual(
            Config.wifiRemovalPlan(network: wifiNetwork(), firewall: firewall(), travelmate: .null)
                .travelmate,
            [])
    }

    func testRemovalOnARouterWithoutWiFiSharingDoesNothing() {
        let plan = Config.wifiRemovalPlan(
            network: config([lan()]), firewall: firewall(), travelmate: travelmate())
        XCTAssertTrue(plan.isEmpty)
    }

    func testRemovalDeletesTheNetworkOptionWhenNothingIsLeftInTheZone() {
        let plan = Config.wifiRemovalPlan(
            network: wifiNetwork(), firewall: firewall(wan: ["phone_wifi"]), travelmate: .null)
        XCTAssertEqual(plan.firewall, [.deleteOption(section: "cfg03dc81", option: "network")])
    }

    func testTheIPhonesUplinksAreTheSavedNetworksWhoseTunnelIsThePhoneWiFi() {
        let saved = travelmate(
            uplinks: [
                uplink("cfg0a", index: 1, ssid: "Hotel", device: "radio0", vpniface: "wg0", vpn: "1"),
                phoneUplink(index: 2),
                uplink(
                    "cfg0c", index: 3, ssid: hotspotName, device: "radio0", vpniface: "phone_wifi",
                    vpn: "1"),
                uplink("cfg0d", index: 4, ssid: "Cafe", device: "radio1"),
            ])
        XCTAssertEqual(
            Config.wifiUplinks(in: saved),
            [
                Config.WifiUplink(section: "cfg0b", ssid: hotspotName, device: "radio1", bssid: ""),
                Config.WifiUplink(section: "cfg0c", ssid: hotspotName, device: "radio0", bssid: ""),
            ])
        XCTAssertEqual(Config.wifiUplinks(in: .null), [])
    }

    // MARK: - Putting the iPhone first

    func testTheIPhonesStationGoesBeforeEveryOtherStationAndNothingElseMoves() {
        let wireless = config([
            radio("radio0", index: 0), radio("radio1", index: 1),
            accessPoint("default_radio0", index: 2, device: "radio0"),
            accessPoint("default_radio1", index: 3, device: "radio1"),
            station("trm_uplink1", index: 4, device: "radio0", ssid: "Hotel"),
            station("cfg0e0f10", index: 5, device: "radio1", ssid: "Cafe"),
            station("trm_uplink3", index: 6, device: "radio1", ssid: hotspotName),
        ])
        let order = Config.wirelessOrder(wireless: wireless, phoneSection: "trm_uplink3")
        XCTAssertEqual(
            order,
            [
                "radio0", "radio1", "default_radio0", "default_radio1", "trm_uplink3",
                "trm_uplink1", "cfg0e0f10",
            ])
    }

    func testSectionsBetweenStationsKeepTheirOrderAmongThemselves() {
        let wireless = config([
            radio("radio0", index: 0),
            station("trm_uplink1", index: 1, device: "radio0", ssid: "Hotel"),
            accessPoint("default_radio0", index: 2, device: "radio0"),
            station("trm_uplink3", index: 3, device: "radio0", ssid: hotspotName),
        ])
        let order = Config.wirelessOrder(wireless: wireless, phoneSection: "trm_uplink3")
        XCTAssertEqual(order, ["radio0", "trm_uplink3", "trm_uplink1", "default_radio0"])
    }

    func testTheOrderIsTheFilesOrderNotTheNameOrder() {
        // By name the iPhone's would come first already; in the file it doesn't.
        let wireless = config([
            radio("radio0", index: 0),
            station("zz_hotel", index: 1, device: "radio0", ssid: "Hotel"),
            station("aa_phone", index: 2, device: "radio0", ssid: hotspotName),
        ])
        XCTAssertEqual(
            Config.wirelessOrder(wireless: wireless, phoneSection: "aa_phone"),
            ["radio0", "aa_phone", "zz_hotel"])
    }

    func testNothingMovesWhenTheIPhoneIsFirstAlreadyOrAloneOrMissing() {
        let first = config([
            radio("radio0", index: 0),
            accessPoint("default_radio0", index: 1, device: "radio0"),
            station("trm_uplink3", index: 2, device: "radio0", ssid: hotspotName),
            station("trm_uplink1", index: 3, device: "radio0", ssid: "Hotel"),
        ])
        XCTAssertNil(Config.wirelessOrder(wireless: first, phoneSection: "trm_uplink3"))

        // An access point ahead of it is not a station.
        let alone = config([
            radio("radio0", index: 0),
            accessPoint("default_radio0", index: 1, device: "radio0"),
            station("trm_uplink3", index: 2, device: "radio0", ssid: hotspotName),
        ])
        XCTAssertNil(Config.wirelessOrder(wireless: alone, phoneSection: "trm_uplink3"))

        XCTAssertNil(Config.wirelessOrder(wireless: first, phoneSection: "trm_uplink9"))
        XCTAssertNil(Config.wirelessOrder(wireless: .null, phoneSection: "trm_uplink3"))
    }

    func testNoOrderIsGuessedWhenTheRouterDoesntSayWhereSectionsStand() {
        // Without a position for every section the order could only come from their names, and
        // `uci order` would scramble the file.
        var sections = [
            radio("radio0", index: 0),
            station("trm_uplink1", index: 1, device: "radio0", ssid: "Hotel"),
            station("trm_uplink3", index: 2, device: "radio0", ssid: hotspotName),
        ]
        XCTAssertNotNil(
            Config.wirelessOrder(wireless: config(sections), phoneSection: "trm_uplink3"))

        guard case .object(var options) = sections[1].value else { return XCTFail("not a section") }
        options[".index"] = nil
        sections[1] = (sections[1].name, .object(options))
        XCTAssertNil(Config.wirelessOrder(wireless: config(sections), phoneSection: "trm_uplink3"))
    }

    // MARK: - What the router says

    func testStateOfARouterSetUpForWiFi() {
        let state = wifiState(
            wifiUp: true, statusFile: statusFile("connected, net ok/72", station: phoneStation))
        XCTAssertTrue(state.travelmateInstalled)
        XCTAssertTrue(state.wifiConfigured)
        XCTAssertEqual(state.wifiSSID, "Nitin's iPhone")
        XCTAssertEqual(state.wifiPhonePublicKey, "PHONEPUB=")
        XCTAssertTrue(state.wifiTunnelUp)
        XCTAssertTrue(state.wifiUplinkActive)
        XCTAssertTrue(state.wifiPackagesInstalled)
        // The cable is its own business.
        XCTAssertFalse(state.configured)
        XCTAssertFalse(state.tunnelUp)
    }

    func testStateOfARouterThatNeverHeardOfWiFiSharing() {
        let state = Config.state(
            network: config([lan()]), firewall: firewall(), interfaceDump: dump(wifiUp: nil),
            travelmate: travelmate(uplinks: [uplink("cfg0a", index: 1, ssid: "Hotel", device: "radio0")]),
            wireless: wifiWireless(), missingPackages: [], missingWifiPackages: ["kmod-wireguard"],
            usbDevice: nil)
        XCTAssertTrue(state.travelmateInstalled)
        XCTAssertFalse(state.wifiConfigured)
        XCTAssertNil(state.wifiSSID)
        XCTAssertNil(state.wifiPhonePublicKey)
        XCTAssertFalse(state.wifiTunnelUp)
        XCTAssertFalse(state.wifiUplinkActive)
        XCTAssertEqual(state.missingWifiPackages, ["kmod-wireguard"])
        XCTAssertFalse(state.wifiPackagesInstalled)
    }

    func testTravelmateIsInstalledWhenItsConfigExists() {
        // The config of an installed package can be empty; a router without the package has none.
        XCTAssertTrue(wifiState(travelmate: .object([:])).travelmateInstalled)
        let missing = wifiState(withoutTravelmate: true)
        XCTAssertFalse(missing.travelmateInstalled)
        XCTAssertFalse(missing.wifiConfigured)
        XCTAssertNil(missing.wifiSSID)
    }

    func testWiFiOnlyCountsAsConfiguredWithEveryPart() {
        XCTAssertTrue(wifiState().wifiConfigured)
        XCTAssertFalse(wifiState(network: config([lan(), wifiPeer()])).wifiConfigured, "no tunnel")
        XCTAssertFalse(wifiState(network: config([lan(), wifiTunnel()])).wifiConfigured, "no peer")
        XCTAssertFalse(wifiState(wan: ["wan"]).wifiConfigured, "tunnel outside the wan zone")
        XCTAssertFalse(
            wifiState(
                travelmate: travelmate(
                    uplinks: [uplink("cfg0b", index: 2, ssid: hotspotName, device: "radio1")])
            ).wifiConfigured,
            "the saved network doesn't carry the tunnel")
        XCTAssertFalse(
            wifiState(
                wireless: config([
                    radio("radio0", index: 0),
                    station("trm_uplink1", index: 1, device: "radio0", ssid: "Hotel"),
                ])
            ).wifiConfigured,
            "a saved network with no station behind it can't connect")
        XCTAssertFalse(
            wifiState(wireless: wifiWireless(phoneDevice: "radio0")).wifiConfigured,
            "the station is on another radio than the saved network")
    }

    func testTheWiFiTunnelIsUpIndependentlyOfTheUplink() {
        XCTAssertTrue(wifiState(wifiUp: true).wifiTunnelUp)
        XCTAssertFalse(wifiState(wifiUp: false).wifiTunnelUp)
        // `auto 0`: until TravelMate raises it the interface is down, or not even listed.
        XCTAssertFalse(wifiState(wifiUp: nil).wifiTunnelUp)
    }

    func testTheUplinkIsActiveOnlyWhileTravelmateIsConnectedToTheIPhone() {
        func active(_ status: String, station: String) -> Bool {
            wifiState(statusFile: statusFile(status, station: station)).wifiUplinkActive
        }
        XCTAssertTrue(active("connected, net ok/72", station: phoneStation))
        // Connected is connected, whatever the internet check made of it.
        XCTAssertTrue(active("connected, net cp 'portal.example.com'/72", station: phoneStation))
        XCTAssertFalse(active("not connected", station: phoneStation))
        XCTAssertFalse(active("processing", station: phoneStation))
        XCTAssertFalse(active("connected, net ok/72", station: "radio0/Hotel/DE:AD:BE:EF:10:01"))
        // The same name on the other radio is another saved network.
        XCTAssertFalse(active("connected, net ok/72", station: "radio0/Nitin's iPhone/FE:4D:3A:91:2C:07"))
        // A status that doesn't say which radio can't rule the saved one out.
        XCTAssertTrue(active("connected, net ok/72", station: "-/Nitin's iPhone/-"))
        XCTAssertFalse(active("connected, net ok/72", station: "-/-/-"))
    }

    func testNoStatusFileOrAnUnreadableOneMeansNotConnected() {
        XCTAssertFalse(wifiState(statusFile: "").wifiUplinkActive)
        XCTAssertFalse(wifiState(statusFile: "not json").wifiUplinkActive)
    }

    func testMissingWiFiPackagesKeepTheOrderOfTheRequiredList() {
        XCTAssertEqual(RouterService.phoneDataWifiPackages, ["kmod-wireguard", "wireguard-tools"])
        XCTAssertEqual(
            Config.missingPackages(
                required: RouterService.phoneDataWifiPackages, installed: ["wireguard-tools", "busybox"]),
            ["kmod-wireguard"])
        XCTAssertEqual(
            wifiState(missingWifi: ["kmod-wireguard"]).missing,
            PhoneDataMissingPackages(usb: [], wifi: ["kmod-wireguard"]))
    }

    func testRecordingASetupFillsInWhatTheRouterWouldSay() {
        var state = PhoneDataRouterState(
            missingPackages: ["usbmuxd"], configured: false, configuredPhonePublicKey: nil,
            configuredDevice: nil, usbDevice: nil, usbLinkUp: false, tunnelUp: false,
            missingWifiPackages: ["kmod-wireguard"])
        XCTAssertFalse(state.wifiConfigured)

        state.recordWifiSetup(ssid: hotspotName, phonePublicKey: "PHONEPUB=")
        XCTAssertTrue(state.travelmateInstalled)
        XCTAssertTrue(state.wifiConfigured)
        XCTAssertEqual(state.wifiSSID, hotspotName)
        XCTAssertEqual(state.wifiPhonePublicKey, "PHONEPUB=")
        XCTAssertTrue(state.wifiPackagesInstalled)
        // Nothing of the cable's changes.
        XCTAssertFalse(state.configured)
        XCTAssertEqual(state.missingPackages, ["usbmuxd"])
        XCTAssertFalse(PhoneDataRouterController.needsWifiRepair(state: state, phonePublicKey: "PHONEPUB="))
    }

    // MARK: - Repair

    func testWiFiRepairIsOnlyForARouterThatIsSetUpForAnotherPhone() {
        let setUp = wifiState()
        XCTAssertFalse(PhoneDataRouterController.needsWifiRepair(state: setUp, phonePublicKey: "PHONEPUB="))
        XCTAssertFalse(
            PhoneDataRouterController.needsWifiRepair(state: setUp, phonePublicKey: " PHONEPUB=\n"))
        XCTAssertTrue(PhoneDataRouterController.needsWifiRepair(state: setUp, phonePublicKey: "OTHER="))

        // Not set up for Wi-Fi: not set up for another phone either.
        let notSetUp = wifiState(network: config([lan()]))
        XCTAssertFalse(PhoneDataRouterController.needsWifiRepair(state: notSetUp, phonePublicKey: "OTHER="))
        XCTAssertFalse(PhoneDataRouterController.needsWifiRepair(state: nil, phonePublicKey: "OTHER="))
        // No key to compare with: nothing to disagree about.
        XCTAssertFalse(PhoneDataRouterController.needsWifiRepair(state: setUp, phonePublicKey: ""))

        // The cable's tunnel is judged by its own key.
        let usbOnly = PhoneDataRouterState(
            missingPackages: [], configured: true, configuredPhonePublicKey: "OLD=",
            configuredDevice: "eth2", usbDevice: nil, usbLinkUp: false, tunnelUp: false)
        XCTAssertFalse(PhoneDataRouterController.needsWifiRepair(state: usbOnly, phonePublicKey: "OTHER="))
        XCTAssertTrue(PhoneDataRouterController.needsRepair(state: usbOnly, phonePublicKey: "OTHER="))
    }

    // MARK: - Finding the hotspot

    private func scan(
        _ ssid: String, _ device: String, _ signal: Int, band: Int = 5, encryption: String = "psk2"
    ) -> WifiScanResult {
        WifiScanResult(
            ssid: ssid, bssid: "AA:BB:CC:DD:EE:FF", device: device, signal: signal, quality: 40,
            qualityMax: 70, encrypted: encryption != "none", encryption: encryption, band: band,
            channel: 36)
    }

    func testHotspotsListLikelyIPhonesFirstThenTheStrongest() {
        let hotspots = Config.hotspots(from: [
            scan("Hotel", "radio0", -50, band: 2),
            scan("Nitin's iPhone", "radio1", -60),
            scan("Cafe", "radio1", -40, encryption: "none"),
            scan("iphone de Marie", "radio0", -70, band: 2),
            scan("Mystery", "radio0", 0, band: 0),
            scan("Nitin's iPhone", "radio0", -80, band: 2),
        ])
        XCTAssertEqual(
            hotspots.map { "\($0.ssid)|\($0.device)" },
            [
                "Nitin's iPhone|radio1", "iphone de Marie|radio0", "Nitin's iPhone|radio0",
                "Cafe|radio1", "Hotel|radio0", "Mystery|radio0",
            ])
        XCTAssertEqual(hotspots.map(\.looksLikeIPhone), [true, true, true, false, false, false])
    }

    func testAHotspotKeepsItsStrongestSignalPerRadioAndHiddenNetworksAreLeftOut() {
        let hotspots = Config.hotspots(from: [
            scan("Nitin's iPhone", "radio1", -60),
            scan("", "radio1", -30),
            scan("Nitin's iPhone", "radio1", -45),
            scan("Nitin's iPhone", "radio1", -70),
        ])
        XCTAssertEqual(
            hotspots,
            [
                PhoneDataHotspot(
                    ssid: "Nitin's iPhone", device: "radio1", encryption: "psk2", signal: -45,
                    band: "5 GHz")
            ])
    }

    func testWhatTheScanDoesntSayIsNil() {
        let hotspots = Config.hotspots(from: [scan("Mystery", "radio0", 0, band: 0)])
        XCTAssertEqual(hotspots.count, 1)
        XCTAssertNil(hotspots[0].signal)
        XCTAssertNil(hotspots[0].band)
        XCTAssertEqual(Config.hotspots(from: []), [])
    }

    func testAnyCaseOfIPhoneLooksLikeAnIPhone() {
        func looksLike(_ name: String) -> Bool {
            PhoneDataHotspot(ssid: name, device: "radio0", encryption: "psk2", signal: nil, band: nil)
                .looksLikeIPhone
        }
        XCTAssertTrue(looksLike("Nitin's iPhone"))
        XCTAssertTrue(looksLike("IPHONE 15"))
        XCTAssertTrue(looksLike("Marie's iphone"))
        XCTAssertFalse(looksLike("Galaxy S24"))
        XCTAssertFalse(looksLike("Hotel Wi-Fi"))
    }

    // MARK: - Wording

    func testAMissingTravelmateIsExplainedInPlainWords() {
        let message = PhoneDataRouterController.message(for: PhoneDataRouterError.travelmateMissing)
        XCTAssertTrue(message.contains("TravelMate"))
        XCTAssertTrue(message.contains("travelmate package"))
    }
}
