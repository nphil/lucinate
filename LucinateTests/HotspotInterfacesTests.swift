import XCTest

@testable import Lucinate

final class HotspotInterfacesTests: XCTestCase {

    private func address(_ interface: String, _ ip: String) -> HotspotInterfaces.Address {
        HotspotInterfaces.Address(interface: interface, ip: ip)
    }

    func testTheBridgeOnTheHotspotSubnetIsTheHotspot() {
        let all = [
            address("en0", "192.168.1.20"),
            address("pdp_ip0", "10.20.30.40"),
            address("bridge100", "172.20.10.1"),
        ]
        XCTAssertEqual(HotspotInterfaces.hotspotAddress(among: all), "172.20.10.1")
    }

    func testAnIPhoneThatJoinedAnotherHotspotIsNotTheHotspot() {
        // As a client, its own Wi-Fi gets a 172.20.10.x address too, but on en0, not a bridge.
        XCTAssertNil(HotspotInterfaces.hotspotAddress(among: [address("en0", "172.20.10.3")]))
    }

    func testOtherBridgesAreNotTheHotspot() {
        let all = [address("bridge101", "192.168.2.1"), address("bridge0", "10.0.0.1")]
        XCTAssertNil(HotspotInterfaces.hotspotAddress(among: all))
    }

    func testNoAddressesMeansNoHotspot() {
        XCTAssertNil(HotspotInterfaces.hotspotAddress(among: []))
    }
}
