import Foundation

/// When the silent sound in `KeepAlive` plays. It keeps Lucinate running in the background, which
/// costs battery the whole time, so it plays only when a router could be using the iPhone:
/// - while Personal Hotspot is on and at least one router has been set up, and
/// - for a while after that, so a USB cable or the hotspot itself can come back, and so the
///   hotspot can be turned on after the Shortcut or the Phone Data screen asked for it (`wake`).
/// With no router set up it never plays. Merely opening Lucinate doesn't start the wait: it is
/// opened often for other things. Once the sound stops iOS suspends Lucinate until it is opened
/// again or a Shortcut wakes it. Foundation only, so the timing is unit-tested.
struct KeepAlivePolicy: Equatable, Sendable {
    /// Long enough for a USB cable or a Wi-Fi drop to come back, and for turning on Personal
    /// Hotspot in Settings after asking.
    static let grace: TimeInterval = 10 * 60

    /// Nil while the hotspot is on. Otherwise when the wait began: the first look that found the
    /// hotspot gone, or the last `wake`. A launch starts long past, so nothing plays until the
    /// hotspot shows up or something wakes Lucinate.
    private(set) var waitingSince: Date? = .distantPast

    /// Call at every look at the hotspot. The wait starts at the first look that doesn't find it,
    /// and later looks don't extend it.
    mutating func observe(hotspot: Bool, now: Date) {
        if hotspot {
            waitingSince = nil
        } else if waitingSince == nil {
            waitingSince = now
        }
    }

    /// The Shortcut, or the Phone Data screen appearing: the wait starts again from now. With the
    /// hotspot on there is no wait to restart, and the sound plays anyway.
    mutating func wake(now: Date) {
        if waitingSince != nil { waitingSince = now }
    }

    func plays(hasPeers: Bool, now: Date) -> Bool {
        guard hasPeers else { return false }
        guard let waitingSince else { return true }
        return now.timeIntervalSince(waitingSince) < Self.grace
    }

    /// The hotspot is watched every 5 seconds on screen, where starting at once shows. In the
    /// background a router that joins waits a little longer, and Lucinate wakes a third as often.
    /// `idle` is no router set up (and the keys readable): nothing to start or stop, so a slow
    /// look is enough.
    static func watchInterval(sceneActive: Bool, idle: Bool) -> (every: Duration, tolerance: Duration) {
        if idle { return (.seconds(60), .seconds(20)) }
        return sceneActive ? (.seconds(5), .seconds(1)) : (.seconds(15), .seconds(5))
    }
}
