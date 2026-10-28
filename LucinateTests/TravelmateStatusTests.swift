import XCTest

@testable import Lucinate

final class TravelmateStatusTests: XCTestCase {

    /// A runtime file as travelmate writes it: everything sits under `data`.
    private func runtime(status: String, station: String = "-/-/-") -> String {
        #"{"data":{"travelmate_status":"\#(status)","station_id":"\#(station)","station_subnet":"10.1.0.0/22 (lan: 192.168.8.0/24)"}}"#
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONValue.parse(try XCTUnwrap(text.data(using: .utf8)))
    }

    private func scan(_ ssid: String, device: String) -> WifiScanResult {
        WifiScanResult(
            ssid: ssid, bssid: "AA:BB:CC:DD:EE:01", device: device, signal: -60, quality: 50,
            qualityMax: 70, encrypted: false, encryption: "none", band: 5, channel: 36)
    }

    // MARK: - travelmate_status

    func testCaptivePortalWithHost() {
        let status = TravelmateStatus.fromRuntime(
            runtime(
                status: "connected, net cp 'portal.example.com'/72",
                station: "radio1/MarriottBonvoy_Guest/-"),
            enabled: true)
        XCTAssertEqual(status.connectivity, .captivePortal(host: "portal.example.com"))
        XCTAssertEqual(status.portalHost, "portal.example.com")
        XCTAssertEqual(status.phase, .signInNeeded)
        XCTAssertTrue(status.isConnected)
        XCTAssertFalse(status.isProcessing)
        XCTAssertEqual(status.activeSsid, "MarriottBonvoy_Guest")
        XCTAssertEqual(status.activeDevice, "radio1")
        XCTAssertTrue(status.enabled)
    }

    func testCaptivePortalWithoutHost() {
        for text in ["connected, net cp ''/72", "connected, net cp/72"] {
            let status = TravelmateStatus.fromRuntime(runtime(status: text), enabled: true)
            XCTAssertEqual(status.connectivity, .captivePortal(host: nil), text)
            XCTAssertNil(status.portalHost, text)
        }
    }

    func testOnline() {
        let status = TravelmateStatus.fromRuntime(
            runtime(status: "connected, net ok/72", station: "radio0/CoffeeHouse/-"), enabled: true)
        XCTAssertEqual(status.connectivity, .online)
        XCTAssertNil(status.portalHost)
        XCTAssertEqual(status.phase, .online)
        XCTAssertTrue(status.isConnected)
    }

    func testNoInternet() {
        for text in ["connected, net nok/40", "connected, net fail/40"] {
            let status = TravelmateStatus.fromRuntime(runtime(status: text), enabled: true)
            XCTAssertEqual(status.connectivity, .noInternet, text)
            XCTAssertEqual(status.phase, .noInternet, text)
            XCTAssertTrue(status.isConnected, text)
        }
    }

    func testProcessing() {
        let status = TravelmateStatus.fromRuntime(runtime(status: "processing"), enabled: true)
        XCTAssertEqual(status.connectivity, .unknown)
        XCTAssertTrue(status.isProcessing)
        XCTAssertFalse(status.isConnected)
        XCTAssertEqual(status.phase, .connecting)
        XCTAssertEqual(status.activeSsid, "")
        XCTAssertEqual(status.activeDevice, "")
    }

    func testNotConnected() {
        let status = TravelmateStatus.fromRuntime(runtime(status: "not connected"), enabled: true)
        XCTAssertEqual(status.connectivity, .unknown)
        XCTAssertFalse(status.isProcessing)
        XCTAssertFalse(status.isConnected)
        XCTAssertFalse(status.hasError)
        XCTAssertEqual(status.phase, .notConnected)
    }

    func testProgramError() {
        let status = TravelmateStatus.fromRuntime(runtime(status: "program error"), enabled: true)
        XCTAssertEqual(status.connectivity, .unknown)
        XCTAssertTrue(status.hasError)
        XCTAssertEqual(status.phase, .notConnected)
    }

    /// `connected, -`: associated, internet check not reported yet.
    func testConnectedWithoutCheckResultIsStillConnecting() {
        let status = TravelmateStatus.fromRuntime(runtime(status: "connected, -"), enabled: true)
        XCTAssertEqual(status.connectivity, .unknown)
        XCTAssertTrue(status.isConnected)
        XCTAssertEqual(status.phase, .connecting)
    }

    func testStatusTextIsCaseAndWhitespaceTolerant() {
        let status = TravelmateStatus.fromRuntime(
            runtime(status: " Connected, NET OK/72 "), enabled: true)
        XCTAssertEqual(status.connectivity, .online)
        XCTAssertTrue(status.isConnected)
    }

    func testMalformedOrEmptyFileFallsBack() {
        for raw in ["", "not json", "{}", #"{"data":[]}"#, #"{"data":"x"}"#] {
            let status = TravelmateStatus.fromRuntime(raw, enabled: true)
            XCTAssertEqual(status.statusText, "", raw)
            XCTAssertEqual(status.connectivity, .unknown, raw)
            XCTAssertEqual(status.phase, .notConnected, raw)
            XCTAssertFalse(status.isConnected, raw)
            XCTAssertTrue(status.enabled, raw)
        }
    }

    func testRunFlagsAreNotMistakenForAPortal() {
        let raw =
            #"{"data":{"travelmate_status":"connected, net ok/72","run_flags":"captive: ✔, netcheck: ✘"}}"#
        XCTAssertEqual(TravelmateStatus.fromRuntime(raw, enabled: true).connectivity, .online)
    }

    func testSameConnectionIgnoresSignalDrift() {
        let a = TravelmateStatus.fromRuntime(
            runtime(status: "connected, net ok/72", station: "radio0/Hotel/-"), enabled: true)
        let b = TravelmateStatus.fromRuntime(
            runtime(status: "connected, net ok/65", station: "radio0/Hotel/-"), enabled: true)
        let portal = TravelmateStatus.fromRuntime(
            runtime(status: "connected, net cp 'p.example.com'/65", station: "radio0/Hotel/-"),
            enabled: true)
        XCTAssertTrue(a.hasSameConnection(as: b))
        XCTAssertFalse(a.hasSameConnection(as: portal))
        XCTAssertFalse(a.hasSameConnection(as: .empty))
    }

    func testWithEnabledKeepsEverythingElse() {
        let status = TravelmateStatus.fromRuntime(
            runtime(status: "connected, net ok/72", station: "radio0/Hotel/-"), enabled: true)
        let off = status.withEnabled(false)
        XCTAssertFalse(off.enabled)
        XCTAssertEqual(off.statusText, status.statusText)
        XCTAssertEqual(off.activeSsid, status.activeSsid)
        XCTAssertEqual(off.connectivity, status.connectivity)
        XCTAssertEqual(off.subnet, status.subnet)
    }

    // MARK: - station_id

    func testStationIDParsing() {
        let plain = TravelmateStatus.parseStationID("radio0/MarriottBonvoy_Guest/-")
        XCTAssertEqual(plain.device, "radio0")
        XCTAssertEqual(plain.ssid, "MarriottBonvoy_Guest")
        XCTAssertEqual(plain.bssid, "")

        let pinned = TravelmateStatus.parseStationID("radio1/Hotel/AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(pinned.device, "radio1")
        XCTAssertEqual(pinned.ssid, "Hotel")
        XCTAssertEqual(pinned.bssid, "AA:BB:CC:DD:EE:FF")
    }

    func testStationIDKeepsSlashesInSsid() {
        let parts = TravelmateStatus.parseStationID("radio1/Cafe/Guest/AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(parts.device, "radio1")
        XCTAssertEqual(parts.ssid, "Cafe/Guest")
        XCTAssertEqual(parts.bssid, "AA:BB:CC:DD:EE:FF")
    }

    func testStationIDPlaceholdersAndOddInput() {
        let none = TravelmateStatus.parseStationID("-/-/-")
        XCTAssertEqual(none.device, "")
        XCTAssertEqual(none.ssid, "")
        XCTAssertEqual(none.bssid, "")

        XCTAssertEqual(TravelmateStatus.parseStationID("radio0").device, "radio0")
        XCTAssertEqual(TravelmateStatus.parseStationID("radio0").ssid, "")
        XCTAssertEqual(TravelmateStatus.parseStationID("").device, "")
        // A trailing space is part of the SSID and must still equal the saved one.
        XCTAssertEqual(TravelmateStatus.parseStationID("radio0/Hotel /-").ssid, "Hotel ")
    }

    // MARK: - saved uplinks

    func testUplinkEnabledFollowsTravelmateDefaults() throws {
        func uplink(_ body: String) throws -> TravelmateUplink {
            TravelmateUplink.fromUci(sectionId: "cfg1", try json(body))
        }
        XCTAssertTrue(try uplink(#"{"ssid":"A","device":"radio0","enabled":"1"}"#).enabled)
        XCTAssertFalse(try uplink(#"{"ssid":"A","device":"radio0","enabled":"0"}"#).enabled)
        // Travelmate reads a missing `enabled` as off.
        XCTAssertFalse(try uplink(#"{"ssid":"A","device":"radio0"}"#).enabled)

        let pinned = try uplink(#"{"ssid":"A","device":"radio1","enabled":"1","bssid":"AA:BB"}"#)
        XCTAssertEqual(pinned.bssid, "AA:BB")
        XCTAssertEqual(pinned.device, "radio1")
    }

    func testOnlyThePhoneDataTunnelMarksAnUplinkAsPhoneData() throws {
        func uplink(_ body: String) throws -> TravelmateUplink {
            TravelmateUplink.fromUci(sectionId: "cfg1", try json(body))
        }
        XCTAssertTrue(
            try uplink(#"{"ssid":"iPhone","device":"radio0","vpn":"1","vpniface":"phone_wifi"}"#)
                .carriesPhoneData)
        // The owner's own VPN on a hotel network is not Phone Data.
        XCTAssertFalse(
            try uplink(#"{"ssid":"Hotel","device":"radio0","vpn":"1","vpniface":"wg0"}"#)
                .carriesPhoneData)
        XCTAssertFalse(try uplink(#"{"ssid":"Hotel","device":"radio0"}"#).carriesPhoneData)
    }

    func testSavedMatchSameRadio() {
        let uplinks = [
            TravelmateUplink(sectionId: "a", ssid: "Hotel", device: "radio0", enabled: false),
            TravelmateUplink(sectionId: "b", ssid: "Hotel", device: "radio1", enabled: true),
            TravelmateUplink(sectionId: "c", ssid: "Other", device: "radio0", enabled: true),
        ]
        XCTAssertEqual(
            scan("Hotel", device: "radio0").savedMatch(in: uplinks), .saved(uplinks[0]))
        XCTAssertEqual(
            scan("Hotel", device: "radio1").savedMatch(in: uplinks), .saved(uplinks[1]))
    }

    func testSavedMatchOnlyOtherRadio() {
        let uplinks = [
            TravelmateUplink(sectionId: "a", ssid: "Hotel", device: "radio0", enabled: true)
        ]
        XCTAssertEqual(
            scan("Hotel", device: "radio1").savedMatch(in: uplinks),
            .savedOnOtherRadio(devices: ["radio0"]))
        XCTAssertEqual(scan("Cafe", device: "radio0").savedMatch(in: uplinks), .notSaved)
        XCTAssertEqual(scan("hotel", device: "radio0").savedMatch(in: uplinks), .notSaved)
    }

    func testSavedMatchPrefersEnabledCopy() {
        let uplinks = [
            TravelmateUplink(sectionId: "a", ssid: "Hotel", device: "radio0", enabled: false),
            TravelmateUplink(sectionId: "b", ssid: "Hotel", device: "radio0", enabled: true),
        ]
        XCTAssertEqual(
            scan("Hotel", device: "radio0").savedMatch(in: uplinks), .saved(uplinks[1]))
    }

    // MARK: - uci section lookup

    private let wireless = #"""
        {
          "default_radio0": {".type":"wifi-iface",".index":1,"mode":"ap","ssid":"MiniBeast","device":"radio0"},
          "cfg0a1b2c": {".type":"wifi-iface",".index":2,"mode":"sta","ssid":"MarriottBonvoy_Guest","device":"radio1","bssid":"aa:bb:cc:dd:ee:ff"},
          "trm_uplink1": {".type":"wifi-iface",".index":3,"mode":"sta","ssid":"MarriottBonvoy_Guest","device":"radio1","disabled":"1"},
          "trm_uplink2": {".type":"wifi-iface",".index":4,"mode":"sta","ssid":"MarriottBonvoy_Guest","device":"radio0"},
          "trm_uplink10": {".type":"wifi-iface",".index":5,"mode":"sta","ssid":"Other","device":"radio0"},
          "radio1": {".type":"wifi-device",".index":0,"ssid":"MarriottBonvoy_Guest","device":"radio1"}
        }
        """#

    func testStaSectionsPickOnlyTheMatchingRadioAndSsid() throws {
        let sections = TravelmateConfig.staSections(
            in: try json(wireless), ssid: "MarriottBonvoy_Guest", device: "radio1")
        // The AP, the other radio and the wifi-device are not candidates; the
        // section travelmate named itself outranks a hand-made one.
        XCTAssertEqual(sections, ["trm_uplink1", "cfg0a1b2c"])
    }

    func testStaSectionsPreferTheLinkedBssid() throws {
        let sections = TravelmateConfig.staSections(
            in: try json(wireless), ssid: "MarriottBonvoy_Guest", device: "radio1",
            bssid: "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(sections.first, "cfg0a1b2c")
        XCTAssertEqual(sections.count, 2)
    }

    func testStaSectionsEmptyWhenNothingMatches() throws {
        XCTAssertTrue(
            TravelmateConfig.staSections(in: try json(wireless), ssid: "Nope", device: "radio0")
                .isEmpty)
        XCTAssertTrue(TravelmateConfig.staSections(in: .null, ssid: "x", device: "radio0").isEmpty)
    }

    func testUplinkSectionTakesTheFirstInFileOrder() throws {
        let travelmate = try json(
            #"""
            {
              "global": {".type":"travelmate",".index":0,"trm_enabled":"1"},
              "cfgb": {".type":"uplink",".index":5,"ssid":"Hotel","device":"radio0","enabled":"1"},
              "cfga": {".type":"uplink",".index":2,"ssid":"Hotel","device":"radio0","enabled":"0"},
              "cfgc": {".type":"uplink",".index":3,"ssid":"Hotel","device":"radio1","enabled":"1"}
            }
            """#)
        XCTAssertEqual(
            TravelmateConfig.uplinkSection(in: travelmate, ssid: "Hotel", device: "radio0"), "cfga")
        XCTAssertEqual(
            TravelmateConfig.uplinkSection(in: travelmate, ssid: "Hotel", device: "radio1"), "cfgc")
        XCTAssertNil(
            TravelmateConfig.uplinkSection(in: travelmate, ssid: "Hotel", device: "radio2"))
    }

    func testNextStaSectionName() throws {
        XCTAssertEqual(TravelmateConfig.nextStaSectionName(in: try json(wireless)), "trm_uplink11")
        XCTAssertEqual(TravelmateConfig.nextStaSectionName(in: .null), "trm_uplink1")
        XCTAssertEqual(
            TravelmateConfig.nextStaSectionName(
                in: try json(#"{"trm_uplinkX":{".type":"wifi-iface"}}"#)),
            "trm_uplink1")
    }
}
