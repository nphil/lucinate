import XCTest

@testable import Lucinate

final class NetworkInterfaceTests: XCTestCase {

    // MARK: - Helpers

    private func iface(
        _ name: String = "lan", proto: String, device: String = "br-lan"
    ) -> NetworkInterface {
        NetworkInterface(name: name, isUp: true, protocolName: proto, uptime: 0, device: device)
    }

    private func wifi(
        _ device: String, mode: String, radio: String = "radio0"
    ) -> WirelessNetwork {
        WirelessNetwork(id: device, ssid: "ssid", device: device, radio: radio, mode: mode)
    }

    // MARK: - Type label

    func testTailscaleInterfaceReadsTailscaleVPN() {
        let tailscale = iface("tailscale", proto: "none", device: "tailscale0")
        XCTAssertEqual(tailscale.kind, .tailscale)
        XCTAssertEqual(tailscale.typeLabel, "Tailscale VPN")
        XCTAssertEqual(tailscale.systemImage, "lock.shield")
    }

    func testTailscaleIsRecognisedByNameOrDeviceAlone() {
        XCTAssertEqual(iface("tailscale", proto: "none", device: "N/A").kind, .tailscale)
        XCTAssertEqual(iface("vpn", proto: "none", device: "tailscale0").kind, .tailscale)
        XCTAssertEqual(iface("Tailscale", proto: "NONE", device: "N/A").kind, .tailscale)
    }

    func testUnmanagedInterface() {
        XCTAssertEqual(iface("wan", proto: "none", device: "eth1").typeLabel, "Unmanaged")
        XCTAssertEqual(iface("wan", proto: "", device: "eth1").typeLabel, "Unmanaged")
        XCTAssertEqual(iface("wan", proto: "none", device: "eth1").kind, .unmanaged)
    }

    func testManagedProtocolLabels() {
        let expected: [(proto: String, label: String)] = [
            ("dhcp", "DHCP"),
            ("dhcpv6", "DHCPv6"),
            ("static", "Static"),
            ("pppoe", "PPPoE"),
            ("wireguard", "WireGuard"),
            ("qmi", "Cellular (QMI)"),
            ("mbim", "Cellular (MBIM)"),
            ("ncm", "Cellular (NCM)"),
            ("modemmanager", "Cellular (ModemManager)"),
        ]
        for (proto, label) in expected {
            XCTAssertEqual(iface(proto: proto).typeLabel, label, "proto \(proto)")
        }
    }

    func testProtocolMatchingIgnoresCase() {
        XCTAssertEqual(iface(proto: "DHCP").typeLabel, "DHCP")
        XCTAssertEqual(iface(proto: "WireGuard").kind, .wireguard)
    }

    func testUnknownProtocolIsNotMistakenForUnmanaged() {
        let other = iface(proto: "gre")
        XCTAssertEqual(other.kind, .other)
        XCTAssertNotEqual(other.typeLabel, "Unmanaged")
    }

    func testVPNInterfacesShareTheLockShieldIcon() {
        XCTAssertEqual(iface(proto: "wireguard").systemImage, "lock.shield")
        XCTAssertEqual(iface("tailscale", proto: "none", device: "tailscale0").systemImage,
                       "lock.shield")
        XCTAssertEqual(iface(proto: "dhcp").systemImage, "cable.connector")
    }

    func testDumpEntryForTailscaleParsesToTheFriendlyLabel() throws {
        let entry = try JSONValue.parse(
            Data(
                """
                {"interface":"tailscale","up":true,"proto":"none","device":"tailscale0",
                 "uptime":120,"ipv4-address":[{"address":"100.101.102.103","mask":32}]}
                """.utf8))
        let parsed = NetworkInterface.fromDump(entry)
        XCTAssertEqual(parsed.name, "tailscale")
        XCTAssertEqual(parsed.ipAddress, "100.101.102.103")
        XCTAssertEqual(parsed.typeLabel, "Tailscale VPN")
    }

    // MARK: - Broadcast vs uplink

    func testBroadcastModes() {
        XCTAssertTrue(wifi("phy0-ap0", mode: "ap").isBroadcast)
        // No mode set: uci defaults to ap.
        XCTAssertTrue(wifi("phy0-ap0", mode: "").isBroadcast)
        // iwinfo's own spelling, used when the uci section has no mode.
        XCTAssertTrue(wifi("phy0-ap0", mode: "master").isBroadcast)
        XCTAssertFalse(wifi("phy0-sta0", mode: "sta").isBroadcast)
        XCTAssertFalse(wifi("phy0-mesh0", mode: "mesh").isBroadcast)
        XCTAssertFalse(wifi("phy0-mon0", mode: "monitor").isBroadcast)
        XCTAssertTrue(wifi("phy0-sta0", mode: "sta").isUplink)
        XCTAssertFalse(wifi("phy0-ap0", mode: "ap").isUplink)
    }

    func testBroadcastDevicesSkipUplinksAndUnnamedEntries() {
        let networks = [
            wifi("phy1-ap0", mode: "ap", radio: "radio1"),
            wifi("phy0-ap0", mode: "ap"),
            wifi("phy0-sta0", mode: "sta"),
            wifi("", mode: "ap"),
            wifi("phy0-ap0", mode: "ap"),
        ]
        XCTAssertEqual(WirelessNetwork.broadcastDevices(in: networks), ["phy0-ap0", "phy1-ap0"])
        XCTAssertEqual(WirelessNetwork.broadcastDevices(in: []), [])
    }

    /// The hotel AP showed up as an "Unknown" Wi-Fi client because the STA's
    /// assoclist (the upstream AP) was merged with the real clients.
    func testUplinkIsNeverQueriedForClients() throws {
        let payload = try JSONValue.parse(
            Data(
                """
                {"radio0":{"config":{"band":"2g","channel":"6"},"interfaces":[
                  {"ifname":"phy0-ap0","section":"default_radio0",
                   "config":{"mode":"ap","ssid":"MiniBeast","network":["lan"]},
                   "iwinfo":{"ssid":"MiniBeast","channel":6,"signal":0}},
                  {"ifname":"phy0-sta0","section":"trm_uplink1",
                   "config":{"mode":"sta","ssid":"Marriott_GUEST","network":["wwan"]},
                   "iwinfo":{"ssid":"Marriott_GUEST","channel":6,"signal":-58}}]}}
                """.utf8))
        let networks = WirelessNetwork.fromWirelessDevices(payload)
        XCTAssertEqual(networks.count, 2)
        XCTAssertEqual(WirelessNetwork.broadcastDevices(in: networks), ["phy0-ap0"])
        XCTAssertEqual(networks.first { $0.isUplink }?.signal, -58)
    }
}
