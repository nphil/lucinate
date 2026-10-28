import XCTest

@testable import Lucinate

final class PhoneDataShortcutReplyTests: XCTestCase {

    private typealias Reply = PhoneDataShortcutReply

    private let locked = "Unlock this iPhone once so Lucinate can read its keys."

    // MARK: - Is Phone Data On?

    func testStatusSaysWhereThingsStand() {
        XCTAssertEqual(
            Reply.status(.sharing(routers: 1)), "Phone Data is on. Your router is using this iPhone's data.")
        XCTAssertEqual(
            Reply.status(.waitingForRouter), "Phone Data is ready. Waiting for your router to connect.")
        XCTAssertEqual(
            Reply.status(.waitingForHotspot),
            "Phone Data is off. Plug your iPhone into the router with Personal Hotspot on.")
        XCTAssertEqual(Reply.status(.notSetUp), "Set up Phone Data in Lucinate's TravelMate tab first.")
    }

    func testStatusCountsSeveralRouters() {
        XCTAssertEqual(
            Reply.status(.sharing(routers: 2)), "Phone Data is on. 2 routers are using this iPhone's data.")
    }

    func testAProblemIsPassedOnInItsOwnWords() {
        XCTAssertEqual(Reply.status(.problem(locked)), "Phone Data isn't working. \(locked)")
    }

    // MARK: - Use Phone Data

    func testStartTellsWhatToDoNext() {
        XCTAssertEqual(
            Reply.start(.waitingForHotspot, keptAlive: true),
            "Ready. Plug your iPhone into the router with Personal Hotspot on. Lucinate waits 10 minutes.")
        XCTAssertEqual(
            Reply.start(.waitingForRouter, keptAlive: true), "Ready. Waiting for your router to connect.")
    }

    func testStartWhileAlreadyOnSaysSo() {
        XCTAssertEqual(Reply.start(.sharing(routers: 1), keptAlive: true), Reply.status(.sharing(routers: 1)))
    }

    func testStartAdmitsItCouldntKeepRunningInTheBackground() {
        let expected = "Lucinate couldn't keep running in the background. Open Lucinate once, then try again."
        for state in [Reply.State.waitingForHotspot, .waitingForRouter, .sharing(routers: 1)] {
            XCTAssertEqual(Reply.start(state, keptAlive: false), expected)
        }
    }

    func testNotSetUpAndProblemsComeBeforeTheBackgroundComplaint() {
        // Nothing should be playing then, so the sound's failure is not the news.
        XCTAssertEqual(Reply.start(.notSetUp, keptAlive: false), Reply.setUpFirst)
        XCTAssertEqual(Reply.start(.problem(locked), keptAlive: false), Reply.status(.problem(locked)))
        XCTAssertEqual(Reply.start(.notSetUp, keptAlive: true), Reply.setUpFirst)
    }

    // MARK: - The true and false the shortcut gets

    func testOnMeansARouterIsUsingTheData() {
        XCTAssertTrue(Reply.State.sharing(routers: 1).isOn)
        for state in [Reply.State.notSetUp, .waitingForHotspot, .waitingForRouter, .problem(locked)] {
            XCTAssertFalse(state.isOn)
        }
    }

    func testReadyMeansSetUpWithNothingWrong() {
        for state in [Reply.State.waitingForHotspot, .waitingForRouter, .sharing(routers: 1)] {
            XCTAssertTrue(state.isReady)
        }
        XCTAssertFalse(Reply.State.notSetUp.isReady)
        XCTAssertFalse(Reply.State.problem(locked).isReady)
    }
}
