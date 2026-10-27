import XCTest

@testable import Lucinate

final class WifiCredentialRulesTests: XCTestCase {

    private func problem(_ password: String, _ encryption: String) -> String? {
        WifiCredentialRules.passphraseProblem(password, encryption: encryption)
    }

    // MARK: - SSID

    func testSSIDLimitIsBytesNotCharacters() {
        XCTAssertNil(WifiCredentialRules.ssidProblem(String(repeating: "a", count: 32)))
        XCTAssertNotNil(WifiCredentialRules.ssidProblem(String(repeating: "a", count: 33)))
        // Each of these is 4 bytes in UTF-8: 8 fit, 9 do not.
        XCTAssertNil(WifiCredentialRules.ssidProblem(String(repeating: "📶", count: 8)))
        XCTAssertNotNil(WifiCredentialRules.ssidProblem(String(repeating: "📶", count: 9)))
    }

    // MARK: - Passphrase

    func testPassphraseMustBeEightToSixtyThreeBytes() {
        for encryption in ["psk", "psk2", "psk2+ccmp", "psk-mixed", "sae", "sae-mixed"] {
            XCTAssertNotNil(problem("1234567", encryption), encryption)
            XCTAssertNil(problem("12345678", encryption), encryption)
            XCTAssertNil(problem(String(repeating: "x", count: 63), encryption), encryption)
            XCTAssertNotNil(problem(String(repeating: "x", count: 65), encryption), encryption)
        }
    }

    func testSixtyFourCharactersAreOnlyValidAsRawHexKey() {
        XCTAssertNil(problem(String(repeating: "f", count: 64), "psk2"))
        XCTAssertNotNil(problem(String(repeating: "g", count: 64), "psk2"))
    }

    func testEmptyPasswordMeansKeepTheCurrentOne() {
        XCTAssertNil(problem("", "psk2"))
        XCTAssertNil(problem("", "sae-mixed"))
    }

    func testModesWithoutAPassphraseAreNotChecked() {
        XCTAssertNil(problem("x", "none"))
        XCTAssertNil(problem("x", "owe"))
        XCTAssertNil(problem("x", "wpa2"))
    }
}
