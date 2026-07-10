import XCTest

@testable import Lucinate

final class JSONValueTests: XCTestCase {

    func testParseUbusResponseEnvelope() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"result":[0,{"model":"GL-MT3000"}],"error":null}"#
        let data = try XCTUnwrap(json.data(using: .utf8))
        let value = try JSONValue.parse(data)

        XCTAssertEqual(value["jsonrpc"].stringValue, "2.0")
        XCTAssertEqual(value["id"].intValue, 1)
        XCTAssertTrue(value["error"].isNull)

        let result = value["result"]
        XCTAssertEqual(result[0].intValue, 0)
        XCTAssertEqual(result[1]["model"].stringValue, "GL-MT3000")
    }

    func testBoolCoercion() {
        XCTAssertEqual(JSONValue.string("1").boolValue, true)
        XCTAssertEqual(JSONValue.number(1).boolValue, true)
        XCTAssertEqual(JSONValue.bool(true).boolValue, true)

        XCTAssertEqual(JSONValue.string("0").boolValue, false)
        XCTAssertEqual(JSONValue.number(0).boolValue, false)
        XCTAssertEqual(JSONValue.bool(false).boolValue, false)

        XCTAssertNil(JSONValue.string("banana").boolValue)
        XCTAssertNil(JSONValue.null.boolValue)
    }

    func testMissingKeyReturnsNull() {
        let value = JSONValue.object(["present": .string("yes")])
        XCTAssertEqual(value["absent"], .null)
        XCTAssertTrue(value["absent"].isNull)
        // Out-of-range index also returns .null.
        XCTAssertTrue(JSONValue.array([.number(1)])[5].isNull)
        // Chained lookups through .null stay .null.
        XCTAssertTrue(value["absent"]["deeper"].isNull)
    }
}
