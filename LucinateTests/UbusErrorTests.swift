import XCTest

@testable import Lucinate

final class UbusErrorTests: XCTestCase {

    // MARK: - Access denied

    func testExpiredSessionReplyIsAccessDenied() {
        // What LuCI answers, for every call, when the session id is unknown or expired.
        let error = UbusError.rpcError(code: -32002, message: "Access denied")
        XCTAssertTrue(error.isAccessDenied)
        XCTAssertFalse(error.isNotFound)
        XCTAssertFalse(error.isTransient)
    }

    func testPermissionDeniedStatusAndForbiddenHTTPAreAccessDenied() {
        XCTAssertTrue(UbusError.ubusStatus(6, nil).isAccessDenied)
        XCTAssertTrue(UbusError.ubusStatus(6, "Access to command denied by ACL").isAccessDenied)
        XCTAssertTrue(UbusError.httpStatus(403).isAccessDenied)
    }

    func testOtherFailuresAreNotAccessDenied() {
        XCTAssertFalse(
            UbusError.rpcError(code: -32602, message: "Invalid parameters").isAccessDenied)
        XCTAssertFalse(UbusError.ubusStatus(2, nil).isAccessDenied)
        XCTAssertFalse(UbusError.httpStatus(404).isAccessDenied)
        XCTAssertFalse(UbusError.badCredentials.isAccessDenied)
        XCTAssertFalse(UbusError.notLoggedIn.isAccessDenied)
    }

    func testAccessDeniedReadsTheSameWhicheverWayTheRouterSaidIt() {
        let message = UbusError.rpcError(code: -32002, message: "Access denied").errorDescription
        XCTAssertEqual(message, UbusError.ubusStatus(6, nil).errorDescription)
        XCTAssertEqual(message, UbusError.httpStatus(403).errorDescription)
        XCTAssertFalse(message?.contains("-32002") ?? true)
    }

    // MARK: - Not found

    func testMissingMethodAndObjectAreNotFound() {
        XCTAssertTrue(UbusError.ubusStatus(3, nil).isNotFound)  // METHOD_NOT_FOUND
        XCTAssertTrue(UbusError.ubusStatus(4, "not found").isNotFound)  // NOT_FOUND
        // LuCI reports an object no ACL covers (an uninstalled plugin) as access denied.
        XCTAssertFalse(UbusError.rpcError(code: -32002, message: "Access denied").isNotFound)
        XCTAssertFalse(UbusError.ubusStatus(6, nil).isNotFound)
        XCTAssertFalse(UbusError.network("offline").isNotFound)
    }

    func testUnavailableObjectIsNotFoundOrAccessDenied() {
        XCTAssertTrue(UbusError.ubusStatus(4, nil).isUnavailableObject)
        XCTAssertTrue(UbusError.ubusStatus(6, nil).isUnavailableObject)
        XCTAssertTrue(
            UbusError.rpcError(code: -32002, message: "Access denied").isUnavailableObject)
        // INVALID_ARGUMENT is a bad request, not a missing plugin.
        XCTAssertFalse(UbusError.ubusStatus(2, nil).isUnavailableObject)
        XCTAssertFalse(UbusError.network("offline").isUnavailableObject)
    }

    // MARK: - Transient

    func testTransientFailures() {
        XCTAssertTrue(UbusError.network("The request timed out.").isTransient)
        XCTAssertTrue(UbusError.ubusStatus(7, nil).isTransient)  // TIMEOUT
        XCTAssertTrue(UbusError.ubusStatus(10, nil).isTransient)  // CONNECTION_FAILED
        for code in [500, 502, 503, 504] {
            XCTAssertTrue(UbusError.httpStatus(code).isTransient, "HTTP \(code)")
        }
    }

    func testDefinitiveFailuresAreNotTransient() {
        XCTAssertFalse(UbusError.ubusStatus(2, nil).isTransient)
        XCTAssertFalse(UbusError.ubusStatus(4, nil).isTransient)
        XCTAssertFalse(UbusError.ubusStatus(6, nil).isTransient)
        XCTAssertFalse(UbusError.httpStatus(403).isTransient)
        XCTAssertFalse(UbusError.httpStatus(404).isTransient)
        XCTAssertFalse(UbusError.rpcError(code: -32002, message: "Access denied").isTransient)
        XCTAssertFalse(UbusError.badCredentials.isTransient)
        XCTAssertFalse(UbusError.certificateNotTrusted(hostPort: "192.168.1.1:443").isTransient)
        XCTAssertFalse(UbusError.notLoggedIn.isTransient)
        XCTAssertFalse(UbusError.invalidResponse.isTransient)
    }

    // MARK: - Retry policy

    func testReadOnlyProceduresMayBeRetried() {
        let names = [
            "get", "read", "list", "status", "info", "board", "dump", "assoclist", "scan",
            "access", "state", "stat",
            "getWirelessDevices", "getDHCPLeases", "getFeatures", "getWgInstances",
            "get_status", "get_settings",
        ]
        for name in names {
            XCTAssertTrue(UbusRetryPolicy.isReadOnly(procedure: name), name)
        }
    }

    func testMutatingProceduresAreSingleAttempt() {
        let names = [
            "set", "add", "delete", "commit", "exec", "write", "set_settings", "reboot",
            "restart", "apply", "",
        ]
        for name in names {
            XCTAssertFalse(UbusRetryPolicy.isReadOnly(procedure: name), name)
        }
    }

    func testOnlyConnectionSetupFailuresProveTheRequestNeverLeft() {
        let neverSent = [
            NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
            NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet,
        ]
        for code in neverSent {
            XCTAssertTrue(UbusRetryPolicy.requestNeverSent(urlErrorCode: code), "\(code)")
        }
        // A timeout or dropped connection can happen after the router already acted.
        let maybeSent = [
            NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorBadServerResponse,
            NSURLErrorCancelled,
        ]
        for code in maybeSent {
            XCTAssertFalse(UbusRetryPolicy.requestNeverSent(urlErrorCode: code), "\(code)")
        }
    }

    // MARK: - Object list

    func testObjectListIsUnwrappedFromLuciReply() {
        let reply = JSONValue.array([.array([.string("system"), .string("tailscale")])])
        XCTAssertEqual(UbusClient.parseObjectList(reply), ["system", "tailscale"])
    }

    func testObjectListToleratesBareArray() {
        let reply = JSONValue.array([.string("uci"), .string("file")])
        XCTAssertEqual(UbusClient.parseObjectList(reply), ["uci", "file"])
    }

    func testEmptyAndMalformedObjectLists() {
        XCTAssertEqual(UbusClient.parseObjectList(.array([])), [])
        XCTAssertEqual(UbusClient.parseObjectList(.array([.array([])])), [])
        XCTAssertNil(UbusClient.parseObjectList(.object([:])))
        XCTAssertNil(UbusClient.parseObjectList(.null))
    }
}
