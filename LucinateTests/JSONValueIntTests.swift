import XCTest

@testable import Lucinate

final class JSONValueIntTests: XCTestCase {

    /// rpcd reports 64-bit counters as plain numbers; `Int(_: Double)` would
    /// trap on these instead of yielding nil.
    func testIntValueIsNilForNonFiniteAndOutOfRangeNumbers() {
        XCTAssertNil(JSONValue.number(.infinity).intValue)
        XCTAssertNil(JSONValue.number(-.infinity).intValue)
        XCTAssertNil(JSONValue.number(.nan).intValue)
        XCTAssertNil(JSONValue.number(1e19).intValue)
        XCTAssertNil(JSONValue.number(-1e19).intValue)
    }

    func testIntValueTruncatesTowardZeroLikeInt() {
        XCTAssertEqual(JSONValue.number(3.9).intValue, 3)
        XCTAssertEqual(JSONValue.number(-3.9).intValue, -3)
        XCTAssertEqual(JSONValue.number(1_700_000_000).intValue, 1_700_000_000)
        XCTAssertEqual(JSONValue.number(0).intValue, 0)
        XCTAssertEqual(JSONValue.string("42").intValue, 42)
        XCTAssertNil(JSONValue.string("forty-two").intValue)
        XCTAssertNil(JSONValue.bool(true).intValue)
    }
}
