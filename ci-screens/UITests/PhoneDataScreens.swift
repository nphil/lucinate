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
        let remove = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Remove from Router'")).firstMatch
        for _ in 0..<4 where !remove.isHittable { app.swipeUp() }
        if remove.exists {
            remove.tap()
            let confirm = app.alerts.buttons["Remove"]
            if confirm.waitForExistence(timeout: 5) { confirm.tap() }
            sleep(4)
            for _ in 0..<4 { app.swipeDown() }
            shot(app, "\(tag)-3b-setup-checklist")
            app.swipeUp()
            shot(app, "\(tag)-3c-setup-checklist-scrolled")
            let finish = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Finish'")).firstMatch
            if finish.exists {
                finish.tap()
                sleep(4)
                for _ in 0..<4 { app.swipeDown() }
                shot(app, "\(tag)-3d-after-finish")
            }
        }
        for _ in 0..<4 { app.swipeDown() }
        sleep(1)
        shot(app, "\(tag)-5-phone-data-bottom")

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
