import XCTest

@testable import Lucinate

final class TailscaleStatusTests: XCTestCase {

    // MARK: - Payload helpers

    private func status(_ json: String) throws -> TailscaleStatus {
        TailscaleStatus.fromJSON(try JSONValue.parse(Data(json.utf8)))
    }

    /// What the rpcd plugin returns when `tailscale status --json` fails.
    private let daemonDownJSON = """
        {"status":"","version":"","TUNMode":false,"health":"","ipv4":"Not running",
         "ipv6":"","domain_name":"","peers":{}}
        """

    // MARK: - State

    func testRunningPayload() throws {
        let parsed = try status(
            """
            {"status":"running","version":"1.76.1","TUNMode":true,"health":"",
             "ipv4":"100.101.102.103","ipv6":"fd7a:115c:a1e0::103",
             "domain_name":"tail1234.ts.net",
             "peers":{"n1":{"ip":"100.64.0.2<br>fd7a:115c:a1e0::2","hostname":"home-server",
                            "ostype":"linux","online":true,"exit_node":false,
                            "exit_node_option":true}}}
            """)
        XCTAssertEqual(parsed.state, .running)
        XCTAssertTrue(parsed.isRunning)
        XCTAssertEqual(parsed.tailnetIP, "100.101.102.103")
        XCTAssertEqual(parsed.ipv6, "fd7a:115c:a1e0::103")
        XCTAssertEqual(parsed.tailnetName, "tail1234.ts.net")
        XCTAssertEqual(parsed.tunMode, true)
        XCTAssertNil(parsed.health)
        XCTAssertEqual(parsed.peers.count, 1)
        XCTAssertEqual(parsed.peers.first?.ip, "100.64.0.2")
        XCTAssertEqual(parsed.exitNodeCandidates.count, 1)
    }

    func testLogoutMeansNeedsLogin() throws {
        let parsed = try status(
            """
            {"status":"logout","version":"1.76.1","TUNMode":true,"health":"",
             "ipv4":"No IP assigned","ipv6":"","domain_name":"","peers":{}}
            """)
        XCTAssertEqual(parsed.state, .needsLogin)
        XCTAssertNil(parsed.tailnetIP)
    }

    func testNotInstalledPayload() throws {
        let parsed = try status(
            """
            {"status":"not_installed","version":"","TUNMode":false,"health":"",
             "ipv4":"Not running","ipv6":"","domain_name":"","peers":{}}
            """)
        XCTAssertEqual(parsed.state, .notInstalled)
    }

    /// The reported bug: an empty status (daemon starting, stopped or offline
    /// behind a hotel portal) used to read as "not installed".
    func testEmptyStatusIsNotConnectedNeverNotInstalled() throws {
        let parsed = try status(daemonDownJSON)
        XCTAssertEqual(parsed.state, .notConnected)
        XCTAssertFalse(parsed.isRunning)
        XCTAssertNil(parsed.tailnetIP)
        XCTAssertNil(parsed.ipv6)
        XCTAssertNil(parsed.health)
    }

    func testUnrecognisedOrMissingStatusIsNotConnected() throws {
        XCTAssertEqual(try status(#"{"status":"starting"}"#).state, .notConnected)
        XCTAssertEqual(try status("{}").state, .notConnected)
        XCTAssertEqual(TailscaleStatus.fromJSON(.null).state, .notConnected)
    }

    func testStatusMatchingIgnoresCaseAndWhitespace() {
        XCTAssertEqual(TailscaleStatus.State(pluginStatus: " Running "), .running)
        XCTAssertEqual(TailscaleStatus.State(pluginStatus: "LOGOUT"), .needsLogin)
        XCTAssertEqual(TailscaleStatus.State(pluginStatus: nil), .notConnected)
    }

    // MARK: - Health + TUN mode

    func testHealthTextIsKeptWhileNotConnected() throws {
        let parsed = try status(
            """
            {"status":"","version":"1.76.1","TUNMode":true,
             "health":"  Tailscale can't reach the control server \\n",
             "ipv4":"No IP assigned","ipv6":"","domain_name":"","peers":{}}
            """)
        XCTAssertEqual(parsed.state, .notConnected)
        XCTAssertEqual(parsed.health, "Tailscale can't reach the control server")
        XCTAssertEqual(parsed.tunMode, true)
    }

    func testTUNModeIsOptional() throws {
        XCTAssertEqual(try status(#"{"TUNMode":false}"#).tunMode, false)
        XCTAssertEqual(try status(#"{"TUNMode":true}"#).tunMode, true)
        XCTAssertNil(try status("{}").tunMode)
    }

    // MARK: - Placeholder addresses

    func testPlaceholderAddressesAreIgnored() throws {
        XCTAssertNil(try status(#"{"ipv4":"Not running"}"#).tailnetIP)
        XCTAssertNil(try status(#"{"ipv4":"No IP assigned"}"#).tailnetIP)
        XCTAssertNil(try status(#"{"ipv4":"No IP assigned","ipv6":"Not running"}"#).ipv6)
        XCTAssertNil(try status(#"{"ipv4":""}"#).tailnetIP)
        XCTAssertNil(try status("{}").tailnetIP)
    }

    func testRealAddressesSurvive() throws {
        let parsed = try status(#"{"ipv4":" 100.101.102.103 ","ipv6":"fd7a:115c:a1e0::1"}"#)
        XCTAssertEqual(parsed.tailnetIP, "100.101.102.103")
        XCTAssertEqual(parsed.ipv6, "fd7a:115c:a1e0::1")
    }

    // MARK: - Absence check

    func testPluginAbsenceNeedsAConfidentObjectList() {
        XCTAssertTrue(TailscaleController.isPluginAbsent(objects: ["system", "uci", "luci-rpc"]))
        XCTAssertFalse(
            TailscaleController.isPluginAbsent(objects: ["system", "tailscale", "uci"]))
        // A failed or empty `list` proves nothing.
        XCTAssertFalse(TailscaleController.isPluginAbsent(objects: nil))
        XCTAssertFalse(TailscaleController.isPluginAbsent(objects: []))
    }
}
