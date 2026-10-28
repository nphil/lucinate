import XCTest

/// Throwaway CI harness: walks reviewer mode to the Phone Data screens and attaches screenshots.
final class PhoneDataScreens: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    func testLight() { run(appearance: .light, tag: "light") }
    func testDark() { run(appearance: .dark, tag: "dark") }

    private func run(appearance: XCUIDevice.Appearance, tag: String) {
        XCUIDevice.shared.appearance = appearance
        let app = XCUIApplication()
        app.launch()

        let brand = app.staticTexts["Lucinate"]
        if brand.waitForExistence(timeout: 20) {
            brand.press(forDuration: 6)
            let alert = app.alerts.firstMatch
            if alert.waitForExistence(timeout: 5) {
                alert.textFields.firstMatch.tap()
                alert.textFields.firstMatch.typeText("REVIEWER")
                alert.buttons["Enable"].tap()
            }
        }
        shot(app, "\(tag)-0-after-login")

        let tab = app.tabBars.buttons["TravelMate"].exists ? app.tabBars.buttons["TravelMate"] : app.buttons["TravelMate"]
        if tab.waitForExistence(timeout: 15) { tab.tap() }
        sleep(3)
        shot(app, "\(tag)-1-travelmate")

        let card = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Phone Data'")).firstMatch
        if card.waitForExistence(timeout: 10) { card.tap() }
        sleep(3)
        shot(app, "\(tag)-2-phone-data-top")

        let fix = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Fix'")).firstMatch
        if fix.exists {
            fix.tap()
            sleep(4)
            shot(app, "\(tag)-3-after-fix")
        }
        app.swipeUp()
        sleep(1)
        shot(app, "\(tag)-4-phone-data-middle")
        let setUpWifi = app.buttons["Set up Wi-Fi sharing"]
        for _ in 0..<4 where !(setUpWifi.exists && setUpWifi.isHittable) { app.swipeUp() }
        shot(app, "\(tag)-5-phone-data-wifi-card")
        if setUpWifi.exists {
            setUpWifi.tap()
            sleep(4)
            shot(app, "\(tag)-6-wifi-sheet")
            let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'iPhone'")).firstMatch
            let cell = row.exists ? row : app.staticTexts["Nitin's iPhone"]
            if cell.waitForExistence(timeout: 10) {
                cell.tap()
                sleep(1)
                let field = app.secureTextFields["Hotspot password"]
                if field.waitForExistence(timeout: 5) {
                    field.tap()
                    field.typeText("hotspot123")
                }
                shot(app, "\(tag)-7-wifi-sheet-picked")
                let connect = app.buttons["Connect"]
                if connect.exists {
                    connect.tap()
                    sleep(1)
                    shot(app, "\(tag)-8-wifi-connecting")
                    sleep(12)
                }
            }
            if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
            sleep(2)
        }
        for _ in 0..<4 { app.swipeDown() }
        shot(app, "\(tag)-9-after-wifi-top")
        app.swipeUp()
        sleep(1)
        shot(app, "\(tag)-9b-after-wifi-middle")
        app.swipeUp()
        sleep(1)
        shot(app, "\(tag)-9c-after-wifi-bottom")

        let oneTap = app.buttons.containing(NSPredicate(format: "label CONTAINS 'one tap'")).firstMatch
        if oneTap.exists {
            oneTap.tap()
            sleep(2)
            shot(app, "\(tag)-6-shortcut-sheet")
            app.swipeUp()
            sleep(1)
            shot(app, "\(tag)-7-shortcut-sheet-scrolled")
        }
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
