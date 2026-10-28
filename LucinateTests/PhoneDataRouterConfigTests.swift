import XCTest

@testable import Lucinate

final class PhoneDataRouterConfigTests: XCTestCase {

    // MARK: - Fixtures

    private func json(_ text: String) throws -> JSONValue {
        try JSONValue.parse(try XCTUnwrap(text.data(using: .utf8)))
    }

    private func strings(_ items: [String]) -> JSONValue {
        .array(items.map { JSONValue.string($0) })
    }

    /// `uci get network` of a router that never heard of Phone Data.
    private func stockNetwork() throws -> JSONValue {
        try json(
            #"""
            {
              "loopback": {".type": "interface", ".name": "loopback", "device": "lo", "proto": "static"},
              "lan": {".type": "interface", ".name": "lan", "device": "br-lan", "proto": "static"}
            }
            """#)
    }

    /// The same, with Phone Data as `applyPhoneData` writes it.
    private func configuredNetwork(
        device: String = "eth2", phoneKey: String = "PHONEPUB="
    ) throws -> JSONValue {
        try json(
            #"""
            {
              "loopback": {".type": "interface", ".name": "loopback", "device": "lo", "proto": "static"},
              "phone_usb": {".type": "interface", ".name": "phone_usb", "proto": "dhcp", "device": "\#(device)", "defaultroute": "0", "peerdns": "0"},
              "phone_wg": {".type": "interface", ".name": "phone_wg", "proto": "wireguard", "private_key": "ROUTERPRIV=", "addresses": ["10.7.0.2/32"], "mtu": "1420", "tunlink": "phone_usb", "dns": ["1.1.1.1"]},
              "phone_wg_peer": {".type": "wireguard_phone_wg", ".name": "phone_wg_peer", "public_key": "\#(phoneKey)", "endpoint_host": "172.20.10.1", "endpoint_port": "51820", "allowed_ips": ["0.0.0.0/1", "128.0.0.0/1"], "route_allowed_ips": "1", "persistent_keepalive": "25"}
            }
            """#)
    }

    /// `uci get firewall`; `wan` is the JSON of the wan zone's `network` option.
    private func firewall(wan: String = #"["wan", "wan6"]"#) throws -> JSONValue {
        try json(
            #"""
            {
              "cfg01e63d": {".type": "defaults", ".name": "cfg01e63d", "input": "REJECT"},
              "cfg02dc81": {".type": "zone", ".name": "cfg02dc81", "name": "lan", "network": ["lan"]},
              "cfg03dc81": {".type": "zone", ".name": "cfg03dc81", "name": "wan", "masq": "1", "network": \#(wan)}
            }
            """#)
    }

    private func interfaceDump(
        usbUp: Bool = true, usbHasAddress: Bool = true, tunnelUp: Bool = true
    ) throws -> JSONValue {
        let address = usbHasAddress ? #"[{"address": "172.20.10.2", "mask": 28}]"# : "[]"
        return try json(
            #"""
            {"interface": [
              {"interface": "lan", "up": true, "proto": "static", "ipv4-address": [{"address": "192.168.1.1", "mask": 24}]},
              {"interface": "phone_usb", "up": \#(usbUp), "proto": "dhcp", "ipv4-address": \#(address)},
              {"interface": "phone_wg", "up": \#(tunnelUp), "proto": "wireguard", "ipv4-address": [{"address": "10.7.0.2", "mask": 32}]}
            ]}
            """#)
    }

    private func routerState(
        missing: [String] = [], configured: Bool, key: String? = nil,
        configuredDevice: String? = nil, usbDevice: String? = nil
    ) -> PhoneDataRouterState {
        PhoneDataRouterState(
            missingPackages: missing, configured: configured, configuredPhonePublicKey: key,
            configuredDevice: configuredDevice, usbDevice: usbDevice, usbLinkUp: false,
            tunnelUp: false)
    }

    // MARK: - Reading uci

    func testListOptionsComeAsArraysOrAsSpaceSeparatedStrings() {
        XCTAssertEqual(PhoneDataRouterConfig.listValues(strings(["wan", "wan6"])), ["wan", "wan6"])
        XCTAssertEqual(PhoneDataRouterConfig.listValues(.string("wan wan6")), ["wan", "wan6"])
        XCTAssertEqual(PhoneDataRouterConfig.listValues(.string("wan")), ["wan"])
        XCTAssertEqual(PhoneDataRouterConfig.listValues(.array([])), [])
        XCTAssertEqual(PhoneDataRouterConfig.listValues(.null), [])
    }

    func testTheWanZoneIsFoundByItsName() throws {
        let zone = try XCTUnwrap(PhoneDataRouterConfig.wanZone(in: try firewall()))
        XCTAssertEqual(
            zone, PhoneDataRouterConfig.Zone(section: "cfg03dc81", networks: ["wan", "wan6"]))
    }

    func testARuleCalledWanIsNotTheWanZone() throws {
        let firewall = try json(
            #"""
            {
              "cfg02": {".type": "zone", "name": "lan", "network": ["lan"]},
              "cfg09": {".type": "rule", "name": "wan", "network": ["x"]}
            }
            """#)
        XCTAssertNil(PhoneDataRouterConfig.wanZone(in: firewall))
    }

    // MARK: - Values written

    func testSetupOnAFreshRouterAddsThreeSectionsAndJoinsTheWanZone() throws {
        let plan = try PhoneDataRouterConfig.setupPlan(
            network: try stockNetwork(), firewall: try firewall(), usbDevice: "eth2",
            privateKey: "ROUTERPRIV=", address: "10.7.0.2", phonePublicKey: "PHONEPUB=")

        let usb: [String: JSONValue] = [
            "proto": .string("dhcp"),
            "device": .string("eth2"),
            "defaultroute": .string("0"),
            "peerdns": .string("0"),
        ]
        let tunnel: [String: JSONValue] = [
            "proto": .string("wireguard"),
            "private_key": .string("ROUTERPRIV="),
            "addresses": strings(["10.7.0.2/32"]),
            "mtu": .string("1420"),
            "tunlink": .string("phone_usb"),
            "dns": strings(["1.1.1.1"]),
        ]
        let peer: [String: JSONValue] = [
            "description": .string("Lucinate Phone Data"),
            "public_key": .string("PHONEPUB="),
            "endpoint_host": .string("172.20.10.1"),
            "endpoint_port": .string("51820"),
            "allowed_ips": strings(["0.0.0.0/1", "128.0.0.0/1"]),
            "route_allowed_ips": .string("1"),
            "persistent_keepalive": .string("25"),
        ]
        let expectedNetwork: [PhoneDataUciEdit] = [
            .add(type: "interface", name: "phone_usb", values: usb),
            .add(type: "interface", name: "phone_wg", values: tunnel),
            .add(type: "wireguard_phone_wg", name: "phone_wg_peer", values: peer),
        ]
        let expectedFirewall: [PhoneDataUciEdit] = [
            .set(
                section: "cfg03dc81",
                values: ["network": strings(["wan", "wan6", "phone_usb", "phone_wg"])])
        ]
        XCTAssertEqual(plan.network, expectedNetwork)
        XCTAssertEqual(plan.firewall, expectedFirewall)
    }

    func testSetupOnAConfiguredRouterUpdatesItInPlaceWithTheNewValues() throws {
        let plan = try PhoneDataRouterConfig.setupPlan(
            network: try configuredNetwork(), firewall: try firewall(wan: #"["wan", "phone_usb", "phone_wg"]"#),
            usbDevice: "eth3", privateKey: "NEWPRIV=", address: "10.7.0.5",
            phonePublicKey: "NEWPUB=")

        let expectedNetwork: [PhoneDataUciEdit] = [
            .set(
                section: "phone_usb",
                values: PhoneDataRouterConfig.usbInterfaceValues(device: "eth3")),
            .set(
                section: "phone_wg",
                values: PhoneDataRouterConfig.tunnelInterfaceValues(
                    privateKey: "NEWPRIV=", address: "10.7.0.5")),
            .set(
                section: "phone_wg_peer",
                values: PhoneDataRouterConfig.peerValues(phonePublicKey: "NEWPUB=")),
        ]
        XCTAssertEqual(plan.network, expectedNetwork)
        // Both names are in the zone already: nothing to change there.
        XCTAssertEqual(plan.firewall, [])
    }

    func testTheZoneKeepsItsMembersAndNeverGetsADuplicate() throws {
        // One of the two is there already; the other is added after the existing members.
        let plan = try PhoneDataRouterConfig.setupPlan(
            network: try stockNetwork(),
            firewall: try firewall(wan: #"["wan", "phone_wg", "travel_wan"]"#),
            usbDevice: "eth2", privateKey: "K=", address: "10.7.0.2", phonePublicKey: "P=")
        let expected: [PhoneDataUciEdit] = [
            .set(
                section: "cfg03dc81",
                values: ["network": strings(["wan", "phone_wg", "travel_wan", "phone_usb"])])
        ]
        XCTAssertEqual(plan.firewall, expected)
    }

    func testAZoneWrittenAsOneSpaceSeparatedStringKeepsItsMembers() throws {
        let plan = try PhoneDataRouterConfig.setupPlan(
            network: try stockNetwork(), firewall: try firewall(wan: #""wan wan6""#),
            usbDevice: "eth2", privateKey: "K=", address: "10.7.0.2", phonePublicKey: "P=")
        let expected: [PhoneDataUciEdit] = [
            .set(
                section: "cfg03dc81",
                values: ["network": strings(["wan", "wan6", "phone_usb", "phone_wg"])])
        ]
        XCTAssertEqual(plan.firewall, expected)
    }

    func testAZoneWithoutAnyNetworkOptionGetsBothInterfaces() throws {
        let firewall = try json(
            #"{"cfg03": {".type": "zone", ".name": "cfg03", "name": "wan", "masq": "1"}}"#)
        let plan = try PhoneDataRouterConfig.setupPlan(
            network: try stockNetwork(), firewall: firewall, usbDevice: "eth2",
            privateKey: "K=", address: "10.7.0.2", phonePublicKey: "P=")
        let expected: [PhoneDataUciEdit] = [
            .set(section: "cfg03", values: ["network": strings(["phone_usb", "phone_wg"])])
        ]
        XCTAssertEqual(plan.firewall, expected)
    }

    func testOtherPeersOfTheTunnelAreDroppedAndAForeignSectionUnderOurNameIsReplaced() throws {
        let network = try json(
            #"""
            {
              "phone_usb": {".type": "interface", "proto": "dhcp", "device": "eth2"},
              "cfg0a1b2c": {".type": "wireguard_phone_wg", "public_key": "OLD="},
              "phone_wg_peer": {".type": "wireguard_other", "public_key": "ODD="}
            }
            """#)
        let plan = try PhoneDataRouterConfig.setupPlan(
            network: network, firewall: try firewall(), usbDevice: "eth2",
            privateKey: "K=", address: "10.7.0.2", phonePublicKey: "P=")

        // A stray peer of the tunnel would fight over the same routes.
        XCTAssertTrue(plan.network.contains(.delete(section: "cfg0a1b2c")))
        // The foreign section is swapped for ours, not edited into shape.
        XCTAssertTrue(plan.network.contains(.delete(section: "phone_wg_peer")))
        let peerAdds = plan.network.filter {
            if case .add(_, "phone_wg_peer", _) = $0 { return true }
            return false
        }
        XCTAssertEqual(peerAdds.count, 1)
        // A section that is there is set, not added a second time.
        XCTAssertTrue(
            plan.network.contains(
                .set(
                    section: "phone_usb",
                    values: PhoneDataRouterConfig.usbInterfaceValues(device: "eth2"))))
    }

    func testSetupNeedsAWanZone() throws {
        let lanOnly = try json(
            #"{"cfg02": {".type": "zone", ".name": "cfg02", "name": "lan", "network": ["lan"]}}"#)
        XCTAssertThrowsError(
            try PhoneDataRouterConfig.setupPlan(
                network: try stockNetwork(), firewall: lanOnly, usbDevice: "eth2",
                privateKey: "K=", address: "10.7.0.2", phonePublicKey: "P=")
        ) { error in
            XCTAssertEqual(error as? PhoneDataRouterError, .noWanZone)
        }
    }

    // MARK: - Removal

    func testRemovalDeletesTheThreeSectionsAndOnlyOurNamesFromTheZone() throws {
        let plan = PhoneDataRouterConfig.removalPlan(
            network: try configuredNetwork(),
            firewall: try firewall(wan: #"["wan", "phone_usb", "wan6", "phone_wg"]"#))

        let expectedNetwork: [PhoneDataUciEdit] = [
            .delete(section: "phone_wg_peer"),
            .delete(section: "phone_wg"),
            .delete(section: "phone_usb"),
        ]
        let expectedFirewall: [PhoneDataUciEdit] = [
            .set(section: "cfg03dc81", values: ["network": strings(["wan", "wan6"])])
        ]
        XCTAssertEqual(plan.network, expectedNetwork)
        XCTAssertEqual(plan.firewall, expectedFirewall)
    }

    func testRemovalOnlyTouchesWhatTheRouterHas() throws {
        // Half a setup: no tunnel and no peer, and only one name in the zone.
        let network = try json(
            #"{"phone_usb": {".type": "interface", "proto": "dhcp", "device": "eth2"}}"#)
        let plan = PhoneDataRouterConfig.removalPlan(
            network: network, firewall: try firewall(wan: #"["wan", "phone_usb"]"#))
        XCTAssertEqual(plan.network, [.delete(section: "phone_usb")])
        XCTAssertEqual(
            plan.firewall,
            [.set(section: "cfg03dc81", values: ["network": strings(["wan"])])])
    }

    func testRemovalOnARouterWithoutPhoneDataDoesNothing() throws {
        let plan = PhoneDataRouterConfig.removalPlan(
            network: try stockNetwork(), firewall: try firewall())
        XCTAssertTrue(plan.isEmpty)
    }

    func testRemovalDeletesTheNetworkOptionWhenNothingIsLeftInTheZone() throws {
        // The router refuses `uci set` with an empty list.
        let plan = PhoneDataRouterConfig.removalPlan(
            network: try configuredNetwork(),
            firewall: try firewall(wan: #"["phone_usb", "phone_wg"]"#))
        XCTAssertEqual(plan.firewall, [.deleteOption(section: "cfg03dc81", option: "network")])
    }

    // MARK: - State

    func testStateOfASetUpRouterWithThePhonePluggedIn() throws {
        let state = PhoneDataRouterConfig.state(
            network: try configuredNetwork(),
            firewall: try firewall(wan: #"["wan", "phone_usb", "phone_wg"]"#),
            interfaceDump: try interfaceDump(), missingPackages: [], usbDevice: "eth2")
        XCTAssertEqual(
            state,
            PhoneDataRouterState(
                missingPackages: [], configured: true, configuredPhonePublicKey: "PHONEPUB=",
                configuredDevice: "eth2", usbDevice: "eth2", usbLinkUp: true, tunnelUp: true))
        XCTAssertTrue(state.packagesInstalled)
    }

    func testStateOfARouterThatNeverHeardOfPhoneData() throws {
        let state = PhoneDataRouterConfig.state(
            network: try stockNetwork(), firewall: try firewall(),
            interfaceDump: try json(#"{"interface": []}"#), missingPackages: ["usbmuxd"],
            usbDevice: nil)
        XCTAssertEqual(
            state,
            PhoneDataRouterState(
                missingPackages: ["usbmuxd"], configured: false, configuredPhonePublicKey: nil,
                configuredDevice: nil, usbDevice: nil, usbLinkUp: false, tunnelUp: false))
        XCTAssertFalse(state.packagesInstalled)
    }

    func testARouterIsOnlyConfiguredWhenBothInterfacesAreInTheWanZone() throws {
        for wan in [#"["wan"]"#, #"["wan", "phone_usb"]"#, #"["wan", "phone_wg"]"#] {
            let state = PhoneDataRouterConfig.state(
                network: try configuredNetwork(), firewall: try firewall(wan: wan),
                interfaceDump: try interfaceDump(), missingPackages: [], usbDevice: nil)
            XCTAssertFalse(state.configured, wan)
        }
    }

    func testARouterWithoutAPeerIsNotConfigured() throws {
        let network = try json(
            #"""
            {
              "phone_usb": {".type": "interface", "proto": "dhcp", "device": "eth2"},
              "phone_wg": {".type": "interface", "proto": "wireguard"}
            }
            """#)
        let state = PhoneDataRouterConfig.state(
            network: network, firewall: try firewall(wan: #"["wan", "phone_usb", "phone_wg"]"#),
            interfaceDump: try interfaceDump(), missingPackages: [], usbDevice: nil)
        XCTAssertFalse(state.configured)
        XCTAssertNil(state.configuredPhonePublicKey)
        XCTAssertEqual(state.configuredDevice, "eth2")
    }

    func testMissingPackagesKeepTheOrderOfTheRequiredList() {
        XCTAssertEqual(
            PhoneDataRouterConfig.missingPackages(
                required: RouterService.phoneDataPackages,
                installed: ["wireguard-tools", "usbmuxd", "busybox"]),
            ["kmod-usb-net-ipheth", "kmod-wireguard"])
    }

    func testTheUSBLinkIsUpOnlyWithAnAddress() throws {
        func linkUp(_ dump: JSONValue) throws -> Bool {
            PhoneDataRouterConfig.state(
                network: try configuredNetwork(), firewall: try firewall(),
                interfaceDump: dump, missingPackages: [], usbDevice: nil
            ).usbLinkUp
        }
        XCTAssertTrue(try linkUp(try interfaceDump()))
        // Up but still waiting for the phone's DHCP answer.
        XCTAssertFalse(try linkUp(try interfaceDump(usbHasAddress: false)))
        XCTAssertFalse(try linkUp(try interfaceDump(usbUp: false)))
    }

    func testTheTunnelIsUpIndependentlyOfTheLink() throws {
        let dump = try interfaceDump(usbUp: false, tunnelUp: true)
        let state = PhoneDataRouterConfig.state(
            network: try configuredNetwork(), firewall: try firewall(),
            interfaceDump: dump, missingPackages: [], usbDevice: nil)
        XCTAssertTrue(state.tunnelUp)
        XCTAssertFalse(state.usbLinkUp)
        XCTAssertFalse(
            PhoneDataRouterConfig.state(
                network: try configuredNetwork(), firewall: try firewall(),
                interfaceDump: try interfaceDump(tunnelUp: false), missingPackages: [],
                usbDevice: nil
            ).tunnelUp)
    }

    // MARK: - Finding the iPhone

    func testOnlyUSBInterfacesOfTheDriverAreCandidates() throws {
        let listing = try json(
            #"""
            {"entries": [
              {"name": "bind", "type": "file"},
              {"name": "2-1.3:1.0", "type": "symlink"},
              {"name": "module", "type": "symlink"},
              {"name": "new_id", "type": "file"},
              {"name": "remove_id", "type": "file"},
              {"name": "1-1:4.2", "type": "symlink"},
              {"name": "uevent", "type": "file"},
              {"name": "unbind", "type": "file"}
            ]}
            """#)
        XCTAssertEqual(
            PhoneDataRouterConfig.usbInterfaceNames(inDriverListing: listing),
            ["1-1:4.2", "2-1.3:1.0"])
    }

    func testADriverWithNoPhoneBoundHasNoCandidates() throws {
        let listing = try json(
            #"""
            {"entries": [
              {"name": "bind", "type": "file"}, {"name": "module", "type": "symlink"},
              {"name": "new_id", "type": "file"}, {"name": "remove_id", "type": "file"},
              {"name": "uevent", "type": "file"}, {"name": "unbind", "type": "file"}
            ]}
            """#)
        XCTAssertEqual(PhoneDataRouterConfig.usbInterfaceNames(inDriverListing: listing), [])
        XCTAssertEqual(
            PhoneDataRouterConfig.usbInterfaceNames(inDriverListing: .object([:])), [])
    }

    func testTheNetworkDeviceIsTheEntryUnderNet() throws {
        let listing = try json(#"{"entries": [{"name": "eth2", "type": "directory"}]}"#)
        XCTAssertEqual(PhoneDataRouterConfig.netdevName(inNetListing: listing), "eth2")
        XCTAssertNil(PhoneDataRouterConfig.netdevName(inNetListing: try json(#"{"entries": []}"#)))
        XCTAssertNil(PhoneDataRouterConfig.netdevName(inNetListing: .object([:])))
    }

    // MARK: - Where setup stands

    func testStepWalksFromInstallingToDone() {
        func step(_ state: PhoneDataRouterState?) -> PhoneDataRouterController.Step {
            PhoneDataRouterController.step(for: state)
        }
        XCTAssertEqual(step(nil), .install)
        // Missing software comes first, whatever else is true.
        XCTAssertEqual(
            step(routerState(missing: ["usbmuxd"], configured: true, usbDevice: "eth2")), .install)
        XCTAssertEqual(step(routerState(configured: false)), .connectPhone)
        XCTAssertEqual(step(routerState(configured: false, usbDevice: "eth2")), .finish)
        XCTAssertEqual(
            step(routerState(configured: true, configuredDevice: "eth2", usbDevice: "eth2")),
            .done)
    }

    func testARouterThatIsSetUpStaysDoneWithThePhoneUnplugged() {
        XCTAssertEqual(
            PhoneDataRouterController.step(
                for: routerState(configured: true, configuredDevice: "eth2")),
            .done)
    }

    func testARenamedUSBDeviceNeedsFinishingAgain() {
        // The iPhone came back as eth3; the router still listens on eth2.
        XCTAssertEqual(
            PhoneDataRouterController.step(
                for: routerState(configured: true, configuredDevice: "eth2", usbDevice: "eth3")),
            .finish)
    }

    func testRepairIsOnlyForARouterThatIsSetUpForAnotherPhone() {
        let setUp = routerState(configured: true, key: "PHONEPUB=")
        XCTAssertFalse(PhoneDataRouterController.needsRepair(state: setUp, phonePublicKey: "PHONEPUB="))
        XCTAssertFalse(
            PhoneDataRouterController.needsRepair(state: setUp, phonePublicKey: " PHONEPUB=\n"))
        XCTAssertTrue(PhoneDataRouterController.needsRepair(state: setUp, phonePublicKey: "OTHER="))
        // A router that isn't set up isn't set up for another phone.
        XCTAssertFalse(
            PhoneDataRouterController.needsRepair(
                state: routerState(configured: false, key: "OLD="), phonePublicKey: "OTHER="))
        XCTAssertFalse(PhoneDataRouterController.needsRepair(state: nil, phonePublicKey: "OTHER="))
        // A peer without a key can't be right.
        XCTAssertTrue(
            PhoneDataRouterController.needsRepair(
                state: routerState(configured: true, key: nil), phonePublicKey: "OTHER="))
        // No key to compare with: nothing to disagree about.
        XCTAssertFalse(PhoneDataRouterController.needsRepair(state: setUp, phonePublicKey: ""))
    }

    // MARK: - Wording

    func testAnInstallFailureQuotesOnlyTheFirstLineOfApk() {
        let result = RouterService.ExecResult(
            stdout: "", stderr: "ERROR: unable to select packages:\n  usbmuxd (no such package)",
            code: 99)
        XCTAssertEqual(
            PhoneDataRouterController.installFailureMessage(result),
            "The router couldn't install the software it needs "
                + "(ERROR: unable to select packages:). "
                + "Make sure the router is online, then try again.")
        XCTAssertEqual(
            PhoneDataRouterController.installFailureMessage(
                RouterService.ExecResult(stdout: "", stderr: "", code: 1)),
            "The router couldn't install the software it needs. "
                + "Make sure the router is online, then try again.")
    }

    func testErrorsAreWordedForThePerson() {
        XCTAssertEqual(
            PhoneDataRouterController.message(for: PackageCatalogError.notApk),
            "Phone Data needs a router running OpenWrt 25.12 or newer.")
        XCTAssertEqual(
            PhoneDataRouterController.message(
                for: UbusError.ubusStatus(6, "Access to command denied by ACL")),
            PhoneDataRouterError.notPermitted.localizedDescription)
        XCTAssertEqual(
            PhoneDataRouterController.message(for: UbusError.network("The Internet connection appears to be offline.")),
            "The Internet connection appears to be offline.")
    }
}
