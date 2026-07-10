import XCTest

@testable import Lucinate

final class ThemeCatalogTests: XCTestCase {

    func testDarkCatalogHasTenThemes() {
        XCTAssertEqual(Themes.dark.count, 10)
    }

    func testLightCatalogHasTenThemes() {
        XCTAssertEqual(Themes.light.count, 10)
    }

    func testAllThemeIDsAreUnique() {
        let ids = Themes.all.map(\.id)
        XCTAssertEqual(ids.count, 20)
        XCTAssertEqual(Set(ids).count, ids.count, "Theme ids must be unique")
    }

    func testDefaultThemesResolve() {
        XCTAssertNotNil(Themes.theme(id: "tokyo-day"))
        XCTAssertNotNil(Themes.theme(id: "catppuccin-mocha"))
    }

    func testUnknownThemeIDReturnsNil() {
        XCTAssertNil(Themes.theme(id: "no-such-theme"))
    }

    func testIsDarkFlagsMatchCatalogs() {
        for theme in Themes.dark {
            XCTAssertTrue(theme.isDark, "\(theme.id) is in the dark catalog but isDark is false")
        }
        for theme in Themes.light {
            XCTAssertFalse(theme.isDark, "\(theme.id) is in the light catalog but isDark is true")
        }
    }
}
