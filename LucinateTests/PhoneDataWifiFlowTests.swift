import XCTest

@testable import Lucinate

/// Wi-Fi setup and removal from the service down to the config they leave, on the demo router
/// (`MockUbusClient`, which keeps uci in memory and answers `uci order`). There is no real router
/// to try this on, so this is the one place the pieces are run together: the scan, what is
/// staged and in which order, and what the state reads back afterwards.
final class PhoneDataWifiFlowTests: XCTestCase {

    private let hotspotName = "Nitin's iPhone"

    private let keys = PhoneDataRouterKeys(
        routerPrivateKey: "ROUTERPRIV=", routerAddress: "10.7.0.3", phonePublicKey: "PHONEPUB=")

    private func makeService() -> RouterService {
        RouterService(transport: MockUbusClient())
    }

    /// The iPhone's hotspot, found the way the setup sheet finds it.
    private func scannedHotspot(_ service: RouterService) async throws -> PhoneDataHotspot {
        var found: [WifiScanResult] = []
        for radio in await service.phoneDataScanRadios() {
            found += await service.phoneDataScan(radio: radio)
        }
        return try XCTUnwrap(PhoneDataRouterConfig.hotspots(from: found).first)
    }

    /// Every section of a config, in file order.
    private func sectionNames(_ service: RouterService, config: String) async throws -> [String] {
        let values = try await service.uciGet(config: config)
        return TravelmateConfig.orderedSections(values).map { $0.name }
    }

    /// The `mode sta` wifi-ifaces, in the order TravelMate tries them.
    private func stationNames(_ service: RouterService) async throws -> [String] {
        let wireless = try await service.uciGet(config: "wireless")
        return TravelmateConfig.orderedSections(wireless)
            .filter { $0.section["mode"].coercedString == "sta" }
            .map { $0.name }
    }

    func testTheScanOffersTheIPhoneFirst() async throws {
        let service = makeService()
        let radios = await service.phoneDataScanRadios()
        XCTAssertEqual(radios, ["radio0", "radio1"])

        let hotspot = try await scannedHotspot(service)
        XCTAssertEqual(hotspot.ssid, hotspotName)
        XCTAssertEqual(hotspot.device, "radio1")
        // WPA2 and WPA3 together is how an iPhone's hotspot shows up.
        XCTAssertEqual(hotspot.encryption, "sae-mixed")
        XCTAssertEqual(hotspot.band, "5 GHz")
        XCTAssertTrue(hotspot.looksLikeIPhone)
    }

    func testSettingUpWiFiSavesTheHotspotPutsItFirstAndWritesTheTunnel() async throws {
        let service = makeService()
        let before = try await service.phoneDataState()
        XCTAssertTrue(before.travelmateInstalled)
        XCTAssertFalse(before.wifiConfigured)
        XCTAssertTrue(before.configured, "the demo router has the cable set up already")
        let stationsBefore = try await stationNames(service)
        XCTAssertEqual(stationsBefore, ["trm_uplink1", "trm_uplink2"])

        let hotspot = try await scannedHotspot(service)
        try await service.applyPhoneDataWifi(keys: keys, hotspot: hotspot, password: "hunter22")

        // What the router says now.
        let after = try await service.phoneDataState()
        XCTAssertTrue(after.wifiConfigured)
        XCTAssertEqual(after.wifiSSID, hotspotName)
        XCTAssertEqual(after.wifiPhonePublicKey, "PHONEPUB=")
        XCTAssertTrue(after.wifiPackagesInstalled)
        // The router is still on its coffee house network, with the tunnel waiting for the hotspot.
        XCTAssertFalse(after.wifiUplinkActive)
        XCTAssertFalse(after.wifiTunnelUp)
        XCTAssertFalse(
            PhoneDataRouterController.needsWifiRepair(state: after, phonePublicKey: "PHONEPUB="))
        XCTAssertTrue(
            PhoneDataRouterController.needsWifiRepair(state: after, phonePublicKey: "OTHER="))
        // The cable is untouched.
        XCTAssertEqual(after.configured, before.configured)
        XCTAssertEqual(after.configuredPhonePublicKey, before.configuredPhonePublicKey)

        // The iPhone's station comes before the other two, and nothing else moved.
        let stations = try await stationNames(service)
        XCTAssertEqual(stations, ["trm_uplink3", "trm_uplink1", "trm_uplink2"])
        let order = try await sectionNames(service, config: "wireless")
        XCTAssertEqual(
            order,
            [
                "radio0", "radio1", "default_radio0", "default_radio1", "trm_uplink3",
                "trm_uplink1", "trm_uplink2",
            ])
        let wireless = try await service.uciGet(config: "wireless")
        XCTAssertEqual(wireless["trm_uplink3"]["ssid"].coercedString, hotspotName)
        XCTAssertEqual(wireless["trm_uplink3"]["device"].coercedString, "radio1")
        XCTAssertEqual(wireless["trm_uplink3"]["key"].coercedString, "hunter22")

        // TravelMate: its tunnel settings, and the uplink that raises the tunnel.
        let travelmate = try await service.uciGet(config: "travelmate")
        let global = travelmate["global"]
        XCTAssertEqual(global["trm_vpn"].coercedString, "1")
        XCTAssertEqual(global["trm_proactive"].coercedString, "1")
        XCTAssertEqual(PhoneDataRouterConfig.listValues(global["trm_vpnifacelist"]), ["phone_wifi"])
        let uplinks = PhoneDataRouterConfig.wifiUplinks(in: travelmate)
        XCTAssertEqual(uplinks.map(\.ssid), [hotspotName])
        XCTAssertEqual(uplinks.map(\.device), ["radio1"])
        let uplinkSection = try XCTUnwrap(uplinks.first).section
        let uplink = travelmate[uplinkSection]
        XCTAssertEqual(uplink["enabled"].coercedString, "1")
        XCTAssertEqual(uplink["vpn"].coercedString, "1")
        XCTAssertEqual(uplink["vpnservice"].coercedString, "wireguard")

        // The tunnel, its phone, and the firewall zone.
        let network = try await service.uciGet(config: "network")
        XCTAssertEqual(network["phone_wifi"]["proto"].coercedString, "wireguard")
        XCTAssertEqual(network["phone_wifi"]["auto"].coercedString, "0")
        XCTAssertEqual(network["phone_wifi"]["metric"].coercedString, "10")
        XCTAssertEqual(
            PhoneDataRouterConfig.listValues(network["phone_wifi"]["addresses"]), ["10.7.0.3/32"])
        XCTAssertTrue(network["phone_wifi"]["tunlink"].isNull)
        XCTAssertEqual(network["phone_wifi_peer"][".type"].stringValue, "wireguard_phone_wifi")
        XCTAssertEqual(network["phone_wifi_peer"]["public_key"].coercedString, "PHONEPUB=")
        let firewall = try await service.uciGet(config: "firewall")
        let zone = try XCTUnwrap(PhoneDataRouterConfig.wanZone(in: firewall))
        XCTAssertTrue(zone.networks.contains("phone_wifi"))
        XCTAssertTrue(zone.networks.contains("phone_usb"))
    }

    func testSettingUpAgainChangesNoMoreThanTheKeys() async throws {
        let service = makeService()
        let hotspot = try await scannedHotspot(service)
        try await service.applyPhoneDataWifi(keys: keys, hotspot: hotspot, password: "hunter22")
        let wirelessOrder = try await sectionNames(service, config: "wireless")
        let travelmateSections = try await sectionNames(service, config: "travelmate")

        let newKeys = PhoneDataRouterKeys(
            routerPrivateKey: "NEWPRIV=", routerAddress: "10.7.0.3", phonePublicKey: "NEWPUB=")
        try await service.applyPhoneDataWifi(keys: newKeys, hotspot: hotspot, password: "")

        // Same stations, same order, the same single saved network.
        let wirelessAgain = try await sectionNames(service, config: "wireless")
        XCTAssertEqual(wirelessAgain, wirelessOrder)
        let travelmateAgain = try await sectionNames(service, config: "travelmate")
        XCTAssertEqual(travelmateAgain, travelmateSections)
        let travelmate = try await service.uciGet(config: "travelmate")
        XCTAssertEqual(PhoneDataRouterConfig.wifiUplinks(in: travelmate).count, 1)
        XCTAssertEqual(
            PhoneDataRouterConfig.listValues(travelmate["global"]["trm_vpnifacelist"]),
            ["phone_wifi"])
        // The password is kept when none is given, and the new keys are in.
        let wireless = try await service.uciGet(config: "wireless")
        XCTAssertEqual(wireless["trm_uplink3"]["key"].coercedString, "hunter22")
        let state = try await service.phoneDataState()
        XCTAssertEqual(state.wifiPhonePublicKey, "NEWPUB=")
        XCTAssertFalse(
            PhoneDataRouterController.needsWifiRepair(state: state, phonePublicKey: "NEWPUB="))
    }

    func testAHotspotWithoutItsPasswordChangesNothing() async throws {
        let service = makeService()
        let hotspot = try await scannedHotspot(service)
        var thrown: Error?
        do {
            try await service.applyPhoneDataWifi(keys: keys, hotspot: hotspot, password: "")
        } catch {
            thrown = error
        }
        XCTAssertEqual(thrown as? TravelmateError, .passwordRequired)

        let state = try await service.phoneDataState()
        XCTAssertFalse(state.wifiConfigured)
        let stations = try await stationNames(service)
        XCTAssertEqual(stations, ["trm_uplink1", "trm_uplink2"])
        let network = try await service.uciGet(config: "network")
        XCTAssertTrue(network["phone_wifi"].isNull)
    }

    func testRemovingWiFiTakesTheHotspotTheTunnelAndTheSettingsItAddedAway() async throws {
        let service = makeService()
        let hotspot = try await scannedHotspot(service)
        try await service.applyPhoneDataWifi(keys: keys, hotspot: hotspot, password: "hunter22")

        try await service.removePhoneDataWifi()

        let state = try await service.phoneDataState()
        XCTAssertFalse(state.wifiConfigured)
        XCTAssertNil(state.wifiSSID)
        XCTAssertTrue(state.travelmateInstalled)
        // The hotspot's station and uplink are gone, the others are as they were.
        let stations = try await stationNames(service)
        XCTAssertEqual(stations, ["trm_uplink1", "trm_uplink2"])
        let travelmate = try await service.uciGet(config: "travelmate")
        XCTAssertEqual(PhoneDataRouterConfig.wifiUplinks(in: travelmate), [])
        XCTAssertEqual(
            Set(TravelmateConfig.orderedSections(travelmate).map { $0.name }),
            ["global", "cfg047f11", "cfg05aa02"])
        // The list is emptied, so the option goes and VPN handling goes back off.
        XCTAssertTrue(travelmate["global"]["trm_vpnifacelist"].isNull)
        XCTAssertEqual(travelmate["global"]["trm_vpn"].coercedString, "0")

        let network = try await service.uciGet(config: "network")
        XCTAssertTrue(network["phone_wifi"].isNull)
        XCTAssertTrue(network["phone_wifi_peer"].isNull)
        let firewall = try await service.uciGet(config: "firewall")
        let zone = try XCTUnwrap(PhoneDataRouterConfig.wanZone(in: firewall))
        XCTAssertFalse(zone.networks.contains("phone_wifi"))
        // The cable's side is left alone.
        XCTAssertTrue(state.configured)
        XCTAssertTrue(zone.networks.contains("phone_usb"))
        XCTAssertTrue(zone.networks.contains("phone_wg"))
        XCTAssertFalse(network["phone_usb"].isNull)
        XCTAssertFalse(network["phone_wg_peer"].isNull)
    }

    func testRemovingWiFiFromARouterThatNeverHadItDoesNothing() async throws {
        let service = makeService()
        let before = try await service.uciGet(config: "travelmate")
        try await service.removePhoneDataWifi()
        let after = try await service.uciGet(config: "travelmate")
        XCTAssertEqual(after, before)
        let stations = try await stationNames(service)
        XCTAssertEqual(stations, ["trm_uplink1", "trm_uplink2"])
    }
}
