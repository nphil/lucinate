import XCTest

@testable import Lucinate

final class CaptivePortalParsingTests: XCTestCase {

    // MARK: - Probe response classification

    private let successPage = "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"

    private func classify(_ text: String) -> WiFiPinnedProbe.Outcome {
        WiFiPinnedProbe.classify(Data(text.utf8))
    }

    func testAppleSuccessPageIsOnline() {
        let response =
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n"
            + "Content-Length: \(successPage.utf8.count)\r\nConnection: close\r\n\r\n\(successPage)"
        XCTAssertEqual(classify(response), .online)
    }

    func testRedirectWithAbsoluteLocationIsCaptive() {
        let response =
            "HTTP/1.1 302 Found\r\nLocation: https://portal.hotel.example/login?mac=aa\r\n"
            + "Content-Length: 0\r\n\r\n"
        XCTAssertEqual(
            classify(response),
            .captive(redirect: URL(string: "https://portal.hotel.example/login?mac=aa")))
    }

    func testRelativeLocationResolvesAgainstTheProbeURL() {
        let response = "HTTP/1.1 301 Moved Permanently\r\nLocation: /login\r\n\r\n"
        XCTAssertEqual(
            classify(response), .captive(redirect: URL(string: "http://captive.apple.com/login")))
    }

    func testRedirectWithoutLocationIsStillCaptive() {
        XCTAssertEqual(classify("HTTP/1.1 302 Found\r\n\r\n"), .captive(redirect: nil))
    }

    func testNetworkAuthenticationRequiredIsCaptive() {
        let response = "HTTP/1.1 511 Network Authentication Required\r\nContent-Length: 0\r\n\r\n"
        XCTAssertEqual(classify(response), .captive(redirect: nil))
    }

    func testSignInPageServedInPlaceOfAppleIsCaptive() {
        let response =
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body>Please log in</body></html>"
        XCTAssertEqual(classify(response), .captive(redirect: nil))
    }

    func testGatewayErrorsAreUnreachableNotCaptive() {
        for status in ["502 Bad Gateway", "503 Service Unavailable", "504 Gateway Timeout"] {
            XCTAssertEqual(classify("HTTP/1.1 \(status)\r\n\r\n"), .unreachable, status)
        }
    }

    func testEmptyAndNonHTTPRepliesAreUnreachable() {
        XCTAssertEqual(WiFiPinnedProbe.classify(Data()), .unreachable)
        XCTAssertEqual(classify("not http at all"), .unreachable)
    }

    func testBareLineFeedsAreTolerated() {
        XCTAssertEqual(
            classify("HTTP/1.0 200 OK\nContent-Type: text/html\n\n\(successPage)"), .online)
    }

    func testTruncatedResponseStillClassifiesFromWhatArrived() {
        XCTAssertEqual(
            classify("HTTP/1.1 302 Found\r\nLocation: http://p.example/"),
            .captive(redirect: URL(string: "http://p.example/")))
    }

    func testEarlyOutcomeWaitsForCompleteHeaders() {
        XCTAssertNil(WiFiPinnedProbe.earlyOutcome(Data("HTTP/1.1 200 OK\r\nContent-Le".utf8)))
    }

    func testEarlyOutcomeSettlesARedirectOnceHeadersAreIn() {
        let received = Data("HTTP/1.1 302 Found\r\nLocation: http://p.example/\r\n\r\n".utf8)
        XCTAssertEqual(
            WiFiPinnedProbe.earlyOutcome(received),
            .captive(redirect: URL(string: "http://p.example/")))
    }

    func testEarlyOutcomeSettlesSuccessWithoutWaitingForTheConnectionToClose() {
        let received = Data("HTTP/1.1 200 OK\r\n\r\n\(successPage)".utf8)
        XCTAssertEqual(WiFiPinnedProbe.earlyOutcome(received), .online)
    }

    func testEarlyOutcomeKeepsReadingAnUnfinishedBody() {
        let received = Data("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n<html>".utf8)
        XCTAssertNil(WiFiPinnedProbe.earlyOutcome(received))
    }

    // MARK: - Proxy request parsing

    private func parse(_ text: String) -> WiFiPinnedProxy.ParseResult {
        WiFiPinnedProxy.parseRequest(Data(text.utf8))
    }

    func testConnectYieldsTheTunnelTarget() {
        let result = parse(
            "CONNECT portal.hotel.example:443 HTTP/1.1\r\nHost: portal.hotel.example:443\r\n"
                + "Proxy-Connection: keep-alive\r\n\r\n")
        XCTAssertEqual(
            result, .request(.connect(host: "portal.hotel.example", port: 443, trailing: Data())))
    }

    func testConnectKeepsBytesThatFollowTheHeader() {
        let result = parse("CONNECT example.com:8443 HTTP/1.1\r\n\r\n\u{16}\u{03}\u{01}")
        XCTAssertEqual(
            result,
            .request(
                .connect(host: "example.com", port: 8443, trailing: Data([0x16, 0x03, 0x01]))))
    }

    func testConnectAcceptsABracketedIPv6Literal() {
        XCTAssertEqual(
            parse("CONNECT [2001:db8::1]:8443 HTTP/1.1\r\n\r\n"),
            .request(.connect(host: "2001:db8::1", port: 8443, trailing: Data())))
    }

    func testAbsoluteFormIsRewrittenToOriginFormWithConnectionClose() {
        let result = parse(
            "GET http://captive.apple.com/hotspot-detect.html HTTP/1.1\r\n"
                + "Host: captive.apple.com\r\nProxy-Connection: keep-alive\r\n"
                + "Connection: keep-alive\r\nKeep-Alive: timeout=5\r\nUser-Agent: Test\r\n\r\n")
        let head =
            "GET /hotspot-detect.html HTTP/1.1\r\nHost: captive.apple.com\r\n"
            + "User-Agent: Test\r\nConnection: close\r\n\r\n"
        XCTAssertEqual(
            result,
            .request(
                .http(host: "captive.apple.com", port: 80, head: Data(head.utf8), trailing: Data())))
    }

    func testAbsoluteFormKeepsPortAndQueryAndSuppliesAMissingPath() {
        let result = parse("GET http://example.com:8080?x=1 HTTP/1.1\r\nHost: example.com:8080\r\n\r\n")
        let head = "GET /?x=1 HTTP/1.1\r\nHost: example.com:8080\r\nConnection: close\r\n\r\n"
        XCTAssertEqual(
            result,
            .request(.http(host: "example.com", port: 8080, head: Data(head.utf8), trailing: Data())))
    }

    func testBodyBytesAfterTheHeaderAreKeptForForwarding() {
        let result = parse(
            "POST http://p.example/login HTTP/1.1\r\nHost: p.example\r\nContent-Length: 7\r\n\r\nroom=12")
        let head =
            "POST /login HTTP/1.1\r\nHost: p.example\r\nContent-Length: 7\r\nConnection: close\r\n\r\n"
        XCTAssertEqual(
            result,
            .request(
                .http(host: "p.example", port: 80, head: Data(head.utf8), trailing: Data("room=12".utf8))
            ))
    }

    func testMissingHostHeaderIsAddedFromTheTarget() {
        let result = parse("GET http://p.example:81/x HTTP/1.0\r\n\r\n")
        let head = "GET /x HTTP/1.0\r\nHost: p.example:81\r\nConnection: close\r\n\r\n"
        XCTAssertEqual(
            result,
            .request(.http(host: "p.example", port: 81, head: Data(head.utf8), trailing: Data())))
    }

    func testUserInfoIsDroppedFromTheTarget() {
        guard case .request(.http(let host, let port, _, _)) = parse(
            "GET http://user:pw@p.example/ HTTP/1.1\r\nHost: p.example\r\n\r\n")
        else { return XCTFail("expected a forwarded request") }
        XCTAssertEqual(host, "p.example")
        XCTAssertEqual(port, 80)
    }

    func testIncompleteHeaderNeedsMoreData() {
        XCTAssertEqual(parse("GET http://p.example/ HTTP/1.1\r\nHost: p.exam"), .needMoreData)
    }

    func testMalformedRequestsAreRejected() {
        XCTAssertEqual(parse("GARBAGE\r\n\r\n"), .rejected(.malformed))
        XCTAssertEqual(parse("CONNECT example.com HTTP/1.1\r\n\r\n"), .rejected(.malformed))
        XCTAssertEqual(parse("CONNECT example.com:0 HTTP/1.1\r\n\r\n"), .rejected(.malformed))
        XCTAssertEqual(parse("CONNECT example.com:99999 HTTP/1.1\r\n\r\n"), .rejected(.malformed))
        XCTAssertEqual(parse("GET http:///path HTTP/1.1\r\n\r\n"), .rejected(.malformed))
    }

    func testOriginFormIsNotAProxyRequest() {
        XCTAssertEqual(
            parse("GET /index.html HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"), .rejected(.notAProxyRequest))
    }

    func testAbsoluteFormOtherThanHTTPIsRejected() {
        XCTAssertEqual(
            parse("GET https://p.example/ HTTP/1.1\r\n\r\n"), .rejected(.unsupportedScheme))
    }

    func testOversizedHeaderIsRejected() {
        let request =
            "GET http://p.example/ HTTP/1.1\r\nX: "
            + String(repeating: "a", count: WiFiPinnedProxy.maxHeadBytes)
        XCTAssertEqual(parse(request), .rejected(.headTooLarge))
    }

    // MARK: - Router address classification

    func testPrivateLANAddresses() {
        let addresses = [
            "192.168.8.1", "10.0.0.1:8080", "172.16.5.4", "172.31.255.1", "169.254.1.1",
            "https://192.168.1.1", "router.lan", "gl-mt3000.local", "openwrt", "[fe80::1]",
            "[fd12:3456::1]:8080",
        ]
        for address in addresses {
            XCTAssertTrue(CaptivePortalMonitor.isPrivateLANAddress(address), address)
        }
    }

    func testPublicAndOverlayAddressesAreNotLAN() {
        let addresses = [
            "8.8.8.8", "172.32.0.1", "172.15.0.1", "100.101.102.103", "router.example.com",
            "[2001:db8::1]", "", "300.1.1.1",
        ]
        for address in addresses {
            XCTAssertFalse(CaptivePortalMonitor.isPrivateLANAddress(address), address)
        }
    }
}
