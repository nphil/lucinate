import Foundation

/// What the Shortcuts actions (PhoneDataIntents.swift) say back. Foundation only, so the wording
/// is unit-tested. Short and plain: Siri reads it out.
enum PhoneDataShortcutReply {
    /// Where Phone Data stands: `PhoneDataController.Status`, plus how many routers are using it.
    enum State: Equatable, Sendable {
        case notSetUp
        case waitingForHotspot
        case waitingForRouter
        case sharing(routers: Int)
        /// The plain-language reason from `PhoneDataController.Status.problem`.
        case problem(String)

        /// A router is using the iPhone's data now.
        var isOn: Bool {
            if case .sharing = self { return true }
            return false
        }

        /// Set up and nothing is wrong: it is on, or will be as soon as the router connects.
        var isReady: Bool {
            switch self {
            case .waitingForHotspot, .waitingForRouter, .sharing: true
            case .notSetUp, .problem: false
            }
        }
    }

    static let setUpFirst = "Set up Phone Data in Lucinate's TravelMate tab first."

    /// After Use Phone Data. `keptAlive` is false when the silent sound couldn't start, and then
    /// iOS suspends Lucinate again as soon as the action ends.
    static func start(_ state: State, keptAlive: Bool) -> String {
        guard state.isReady else { return status(state) }
        guard keptAlive else {
            return "Lucinate couldn't keep running in the background. Open Lucinate once, then try again."
        }
        switch state {
        case .waitingForHotspot:
            let minutes = Int(KeepAlivePolicy.grace / 60)
            return "Ready. Turn on Personal Hotspot, and plug in the USB cable if your router uses it. Lucinate waits \(minutes) minutes."
        case .waitingForRouter:
            return "Ready. Waiting for your router to connect."
        case .sharing, .notSetUp, .problem:
            return status(state)
        }
    }

    static func status(_ state: State) -> String {
        switch state {
        case .notSetUp:
            return setUpFirst
        case .problem(let why):
            return "Phone Data isn't working. \(why)"
        case .waitingForHotspot:
            return "Phone Data is off. Turn on Personal Hotspot, and plug in the USB cable if your router uses it."
        case .waitingForRouter:
            return "Phone Data is ready. Waiting for your router to connect."
        case .sharing(let routers):
            if routers > 1 { return "Phone Data is on. \(routers) routers are using this iPhone's data." }
            return "Phone Data is on. Your router is using this iPhone's data."
        }
    }
}
