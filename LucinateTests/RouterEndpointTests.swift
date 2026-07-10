import XCTest

@testable import Lucinate

final class RouterEndpointTests: XCTestCase {

    // MARK: - Bare host

    func testBareIPv4DefaultsToHTTP80() throws {
        let endpoint = try RouterEndpoint.parse("192.168.1.1")
        XCTAssertEqual(endpoint.host, "192.168.1.1")
        XCTAssertEqual(endpoint.port, 80)
        XCTAssertFalse(endpoint.useHttps)
        XCTAssertEqual(endpoint.hostWithPort, "192.168.1.1")
        XCTAssertEqual(endpoint.baseURLString, "http://192.168.1.1")
        XCTAssertEqual(endpoint.certificateKey, "192.168.1.1:80")
    }

    // MARK: - Host with port

    func testHostnameWithNonTLSPortStaysHTTP() throws {
        let endpoint = try RouterEndpoint.parse("router.local:8080")
        XCTAssertEqual(endpoint.host, "router.local")
        XCTAssertEqual(endpoint.port, 8080)
        XCTAssertFalse(endpoint.useHttps)
        XCTAssertEqual(endpoint.hostWithPort, "router.local:8080")
    }

    func testPort8443InfersHTTPS() throws {
        let endpoint = try RouterEndpoint.parse("192.168.1.1:8443")
        XCTAssertEqual(endpoint.host, "192.168.1.1")
        XCTAssertEqual(endpoint.port, 8443)
        XCTAssertTrue(endpoint.useHttps)
        XCTAssertEqual(endpoint.hostWithPort, "192.168.1.1:8443")
    }

    // MARK: - Explicit scheme

    func testExplicitHTTPSDefaultsToPort443() throws {
        let endpoint = try RouterEndpoint.parse("https://192.168.1.1")
        XCTAssertEqual(endpoint.host, "192.168.1.1")
        XCTAssertEqual(endpoint.port, 443)
        XCTAssertTrue(endpoint.useHttps)
        // 443 is the default port for https, so it is omitted.
        XCTAssertEqual(endpoint.hostWithPort, "192.168.1.1")
        XCTAssertEqual(endpoint.baseURLString, "https://192.168.1.1")
    }

    func testExplicitHTTPSchemeWinsOverTLSLookingPort() throws {
        let endpoint = try RouterEndpoint.parse("http://10.0.0.1:8443/")
        XCTAssertEqual(endpoint.host, "10.0.0.1")
        XCTAssertEqual(endpoint.port, 8443)
        XCTAssertFalse(endpoint.useHttps)
        XCTAssertEqual(endpoint.baseURLString, "http://10.0.0.1:8443")
    }

    // MARK: - IPv6

    func testBracketedIPv6WithPort() throws {
        let endpoint = try RouterEndpoint.parse("[fe80::1]:8080")
        XCTAssertEqual(endpoint.host, "[fe80::1]")
        XCTAssertEqual(endpoint.port, 8080)
        XCTAssertFalse(endpoint.useHttps)
        XCTAssertEqual(endpoint.hostWithPort, "[fe80::1]:8080")
    }

    // MARK: - Invalid inputs

    func testInvalidIPv4OctetThrows() {
        XCTAssertThrowsError(try RouterEndpoint.parse("300.1.1.1")) { error in
            XCTAssertEqual(error as? RouterEndpoint.ParseError, .invalidHost)
        }
    }

    func testOutOfRangePortThrows() {
        XCTAssertThrowsError(try RouterEndpoint.parse("host:99999")) { error in
            XCTAssertEqual(error as? RouterEndpoint.ParseError, .invalidPort)
        }
    }

    func testEmptyInputThrows() {
        XCTAssertThrowsError(try RouterEndpoint.parse("")) { error in
            XCTAssertEqual(error as? RouterEndpoint.ParseError, .empty)
        }
    }
}
