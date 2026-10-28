import XCTest

@testable import Lucinate

final class KeepAlivePolicyTests: XCTestCase {

    private let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let grace = KeepAlivePolicy.grace

    private func at(_ seconds: TimeInterval) -> Date { origin.addingTimeInterval(seconds) }

    // MARK: - Whether it plays

    func testTheGraceIsTenMinutes() {
        XCTAssertEqual(KeepAlivePolicy.grace, 600)
    }

    func testNeverPlaysWithNoRouterSetUp() {
        var policy = KeepAlivePolicy()
        policy.observe(hotspot: true, now: at(0))
        XCTAssertFalse(policy.plays(hasPeers: false, now: at(0)))
        policy.wake(now: at(1))
        policy.observe(hotspot: false, now: at(2))
        XCTAssertFalse(policy.plays(hasPeers: false, now: at(3)))
    }

    func testPlaysWhileTheHotspotIsOnHoweverLong() {
        var policy = KeepAlivePolicy()
        policy.observe(hotspot: true, now: at(0))
        XCTAssertTrue(policy.plays(hasPeers: true, now: at(0)))
        policy.observe(hotspot: true, now: at(3 * 3600))
        XCTAssertTrue(policy.plays(hasPeers: true, now: at(3 * 3600)))
    }

    func testOpeningTheAppAloneNeverStartsIt() {
        // A launch is long past its wait: only the hotspot or a wake brings the sound.
        var policy = KeepAlivePolicy()
        for seconds in stride(from: 0.0, through: 3600, by: 60) {
            policy.observe(hotspot: false, now: at(seconds))
            XCTAssertFalse(policy.plays(hasPeers: true, now: at(seconds)), "at \(seconds) s")
        }
    }

    func testKeepsPlayingForTheGraceAfterTheHotspotGoes() {
        var policy = KeepAlivePolicy()
        policy.observe(hotspot: true, now: at(0))
        policy.observe(hotspot: false, now: at(100)) // the first look without it
        XCTAssertTrue(policy.plays(hasPeers: true, now: at(100)))
        XCTAssertTrue(policy.plays(hasPeers: true, now: at(100 + grace - 0.001)))
        XCTAssertFalse(policy.plays(hasPeers: true, now: at(100 + grace)))
        XCTAssertFalse(policy.plays(hasPeers: true, now: at(100 + grace + 1)))
    }

    func testLaterLooksWithoutTheHotspotDontExtendTheGrace() {
        var policy = KeepAlivePolicy()
        policy.observe(hotspot: true, now: at(0))
        for seconds in stride(from: 100.0, through: 700, by: 15) {
            policy.observe(hotspot: false, now: at(seconds))
        }
        XCTAssertFalse(policy.plays(hasPeers: true, now: at(100 + grace)))
    }

    func testTheHotspotComingBackEndsTheWaitAndLosingItAgainStartsANewOne() {
        var policy = KeepAlivePolicy()
        policy.observe(hotspot: true, now: at(0))
        policy.observe(hotspot: false, now: at(100))
        policy.observe(hotspot: true, now: at(300))
        XCTAssertTrue(policy.plays(hasPeers: true, now: at(100 + grace + 1000)))
        policy.observe(hotspot: false, now: at(5000))
        XCTAssertTrue(policy.plays(hasPeers: true, now: at(5000 + grace - 0.001)))
        XCTAssertFalse(policy.plays(hasPeers: true, now: at(5000 + grace)))
    }

    func testARouterSetUpDuringTheGraceGetsTheSound() {
        var policy = KeepAlivePolicy()
        policy.observe(hotspot: true, now: at(0))
        policy.observe(hotspot: false, now: at(100))
        XCTAssertFalse(policy.plays(hasPeers: false, now: at(200)))
        XCTAssertTrue(policy.plays(hasPeers: true, now: at(200)))
    }

    // MARK: - Waking

    func testWakeStartsTheGraceOnAFreshLaunch() {
        var policy = KeepAlivePolicy()
        policy.wake(now: at(50))
        policy.observe(hotspot: false, now: at(50)) // the look that follows a wake
        XCTAssertTrue(policy.plays(hasPeers: true, now: at(50)))
        XCTAssertTrue(policy.plays(hasPeers: true, now: at(50 + grace - 0.001)))
        XCTAssertFalse(policy.plays(hasPeers: true, now: at(50 + grace)))
    }

    func testWakeStartsTheGraceAgainWhileOneIsRunning() {
        var policy = KeepAlivePolicy()
        policy.observe(hotspot: true, now: at(0))
        policy.observe(hotspot: false, now: at(100))
        let late = 100 + grace - 10 // nearly over
        policy.wake(now: at(late))
        XCTAssertTrue(policy.plays(hasPeers: true, now: at(100 + grace + 100)))
        XCTAssertTrue(policy.plays(hasPeers: true, now: at(late + grace - 0.001)))
        XCTAssertFalse(policy.plays(hasPeers: true, now: at(late + grace)))
    }

    func testWakeBringsBackAGraceThatHasEnded() {
        var policy = KeepAlivePolicy()
        policy.observe(hotspot: true, now: at(0))
        policy.observe(hotspot: false, now: at(100))
        XCTAssertFalse(policy.plays(hasPeers: true, now: at(5000)))
        policy.wake(now: at(5000))
        XCTAssertTrue(policy.plays(hasPeers: true, now: at(5000)))
        XCTAssertFalse(policy.plays(hasPeers: true, now: at(5000 + grace)))
    }

    func testWakeWithTheHotspotOnDoesNotShortenTheWaitThatFollows() {
        var policy = KeepAlivePolicy()
        policy.observe(hotspot: true, now: at(0))
        policy.wake(now: at(60))
        policy.observe(hotspot: false, now: at(120))
        // The wait runs from the first look without the hotspot, not from the wake.
        XCTAssertTrue(policy.plays(hasPeers: true, now: at(120 + grace - 0.001)))
        XCTAssertFalse(policy.plays(hasPeers: true, now: at(120 + grace)))
    }

    // MARK: - How often it looks

    func testWatchesMoreOftenOnScreenAndRarelyWithNothingSetUp() {
        let onScreen = KeepAlivePolicy.watchInterval(sceneActive: true, idle: false)
        let background = KeepAlivePolicy.watchInterval(sceneActive: false, idle: false)
        XCTAssertEqual(onScreen.every, .seconds(5))
        XCTAssertEqual(background.every, .seconds(15))
        for sceneActive in [true, false] {
            let idle = KeepAlivePolicy.watchInterval(sceneActive: sceneActive, idle: true)
            XCTAssertGreaterThan(idle.every, background.every)
        }
    }
}
