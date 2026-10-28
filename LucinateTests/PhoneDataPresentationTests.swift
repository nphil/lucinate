import XCTest

@testable import Lucinate

final class PhoneDataPresentationTests: XCTestCase {

    private typealias Presentation = PhoneDataPresentation

    // MARK: - Sharing says how

    func testSharingNamesTheLinksInUse() {
        XCTAssertEqual(Presentation.sharing(links: [.usb]).title, "Sharing over USB")
        XCTAssertEqual(Presentation.sharing(links: [.wifi]).title, "Sharing over Wi-Fi")
        XCTAssertEqual(
            Presentation.sharing(links: [.usb, .wifi]).title, "Sharing over USB and Wi-Fi")
    }

    func testSharingWithNoLinkNamedDoesNotGuessOne() {
        // The iPhone counts the router as connected but no link says so: better vague than wrong.
        XCTAssertEqual(Presentation.sharing(links: []).title, "Sharing iPhone data")
    }

    // MARK: - Waiting asks only for what is missing

    func testWaitingAsksForTheCableOnlyWhenUSBIsHowTheRouterWasSetUp() {
        let usb = Presentation.waitingForPhone(setUp: [.usb])
        let wifi = Presentation.waitingForPhone(setUp: [.wifi])
        let both = Presentation.waitingForPhone(setUp: [.usb, .wifi])

        XCTAssertTrue(usb.summaryLine.contains("Plug in"))
        XCTAssertFalse(wifi.summaryLine.contains("Plug in"))
        XCTAssertFalse(both.summaryLine.contains("Plug in"))

        XCTAssertTrue(usb.detail(routerSeesPhone: false).contains("USB port"))
        XCTAssertFalse(wifi.detail(routerSeesPhone: false).contains("USB"))
        XCTAssertTrue(both.detail(routerSeesPhone: false).contains("cable"))
        XCTAssertTrue(both.detail(routerSeesPhone: false).contains("Wi-Fi"))
    }

    func testARouterThatAlreadySeesTheIPhoneOnlyNeedsTheHotspot() {
        let setUps: [Set<PhoneDataLink>] = [[.usb], [.wifi], [.usb, .wifi]]
        for setUp in setUps {
            XCTAssertEqual(
                Presentation.waitingForPhone(setUp: setUp).detail(routerSeesPhone: true),
                "The router can see your iPhone. Turn on Personal Hotspot, and tap Trust if it asks."
            )
        }
    }
}
