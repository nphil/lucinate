import Foundation
import Observation
import OSLog
import Security
import UIKit

private let phoneDataLogger = Logger(subsystem: "app.cogwheel.lucimobile", category: "phonedata")

/// The iPhone's side of Phone Data: keeps the routers' keys, listens on the Personal Hotspot network
/// while a router is set up and the hotspot is on, and tells the screen what is going on. The
/// engine itself (Go) is `PhoneDataServer`; `KeepAlive` and `KeepAlivePolicy` keep Lucinate running
/// in the background while it is needed; the Shortcuts actions are in PhoneDataIntents.swift.
@MainActor
@Observable
final class PhoneDataController {
    /// The screens and the Shortcuts actions share it. An action can launch Lucinate in the
    /// background with no screen, and this is all that runs then.
    static let shared = PhoneDataController()

    enum Status: Equatable, Sendable {
        /// No router has been set up for Phone Data.
        case notSetUp
        /// A router is set up, but Personal Hotspot has no network yet: it is off, or nothing is plugged in.
        case waitingForHotspot
        /// Listening on the hotspot, and no router has connected yet.
        case waitingForRouter
        /// At least one router connected recently.
        case sharing
        /// Why it isn't working, in plain words.
        case problem(String)
    }

    // MARK: - What the screens read

    private(set) var status: Status = .notSetUp
    /// Speeds now, in bits per second. Sampled every second while the app is on screen and the
    /// engine runs, zero otherwise.
    private(set) var downBitsPerSecond = 0.0
    private(set) var upBitsPerSecond = 0.0
    /// Bytes carried since launch, across restarts of the engine. Updated by the sampler while the
    /// app is on screen, and when a Shortcut asks.
    private(set) var traffic = PhoneDataTraffic()
    /// The routers with a recent handshake. Updated like `traffic`.
    private(set) var connectedRouterIDs: Set<String> = []
    /// The routers this iPhone lets in.
    private(set) var peers: [PhoneDataPeer] = []

    func isRouterConnected(_ routerID: String) -> Bool { connectedRouterIDs.contains(routerID) }
    func hasPeer(for routerID: String) -> Bool { peers.contains { $0.routerID == routerID } }

    /// The iPhone's public key, base64, to compare with the one a router was set up with. Empty
    /// until the first router is set up, and while the keys can't be read (see `status`).
    func publicKey() -> String {
        keyStore.keys?.serverPublicKey.base64EncodedString() ?? ""
    }

    // MARK: - Setting routers up

    /// A new key pair for the router, and its address in the tunnel: the lowest free one, or the one
    /// it already has. Saved, and handed to the engine if it is running, before this returns. Setting
    /// a router up again replaces its key, so what the router had stops working. Throws when the
    /// keys can't be read or saved.
    func prepareRouter(routerID: String) throws -> PhoneDataRouterKeys {
        loadKeysIfNeeded()
        let keys = try keyStore.prepareRouter(routerID: routerID)
        log("A router was set up, \(keyStore.peers.count) in all")
        peersChanged()
        return keys
    }

    /// The router is no longer let in. With the last one the engine and the keep-alive sound stop.
    func forgetRouter(routerID: String) {
        do {
            try keyStore.forgetRouter(routerID: routerID)
        } catch {
            log("A router couldn't be removed: \(error.localizedDescription)")
            return
        }
        log("A router was removed, \(keyStore.peers.count) left")
        peersChanged()
    }

    /// Follows a saved router whose `Router.id` changed (new address or username), so it keeps its
    /// keys and needs no new setup.
    func renameRouter(from oldID: String, to newID: String) {
        loadKeysIfNeeded()
        do {
            try keyStore.renameRouter(from: oldID, to: newID)
        } catch {
            log("A router couldn't be renamed: \(error.localizedDescription)")
            return
        }
        peersChanged()
    }

    /// The saved keys exist but this version can't use them. Only `resetKeys()` gets past that.
    var needsKeyReset: Bool { keyStore.needsReset }

    /// Gives up on saved keys this version can't use: a new key for the iPhone and no routers, so
    /// every router has to be set up again. Does nothing unless `needsKeyReset`.
    func resetKeys() {
        guard keyStore.needsReset else { return }
        do {
            try keyStore.reset()
        } catch {
            log("The keys couldn't be started over: \(error.localizedDescription)")
            return
        }
        log("The saved keys were replaced with new ones")
        loggedKeyProblem = nil
        peersChanged()
    }

    // MARK: - Running

    /// Starts watching for the hotspot. Idempotent: called once at launch, and again by the
    /// Shortcuts actions in case Lucinate was launched for them with no screen.
    func start() {
        ensureRunning()
        syncWithHotspot()
    }

    /// Keeps Lucinate running for 10 minutes, and looks at the hotspot now. For the Shortcut, and
    /// for the Phone Data screen appearing: Personal Hotspot can then be turned on, and the cable
    /// plugged in, while Lucinate is in the background. Merely opening Lucinate doesn't do this.
    /// True when the silent sound plays, so iOS keeps Lucinate running after a Shortcut action ends.
    @discardableResult
    func wake() -> Bool {
        ensureRunning()
        policy.wake(now: Date())
        syncWithHotspot()
        return keepAlive.sounding
    }

    /// For the Shortcuts actions. In the background the sampler doesn't run, so the routers that
    /// are connected are read now.
    func shortcutState() -> PhoneDataShortcutReply.State {
        ensureRunning()
        syncWithHotspot()
        readServer()
        switch status {
        case .notSetUp: return .notSetUp
        case .waitingForHotspot: return .waitingForHotspot
        case .waitingForRouter: return .waitingForRouter
        case .sharing: return .sharing(routers: connectedRouterIDs.count)
        case .problem(let why): return .problem(why)
        }
    }

    // MARK: - State nothing observes

    private let server = PhoneDataServer()
    private let keyStore: PhoneDataKeyStore
    private let keepAlive = KeepAlive()
    @ObservationIgnored private var policy = KeepAlivePolicy()
    @ObservationIgnored private var started = false
    /// Only the on-screen sampler publishes speeds, so it runs only while the app is on screen.
    /// False in a launch from a Shortcut, which happens in the background.
    @ObservationIgnored private var sceneActive = false
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var sampler: Task<Void, Never>?
    @ObservationIgnored private var lastSample: (up: UInt64, down: UInt64, at: Date)?
    /// The hotspot address the engine listens on, while it does.
    @ObservationIgnored private var boundHost: String?
    /// Routers were added or removed since the running engine was told.
    @ObservationIgnored private var peersNeedPush = false
    /// Why the engine isn't running or can't be told the routers, while the hotspot is there.
    @ObservationIgnored private var serverProblem: String?
    @ObservationIgnored private var loggedKeyProblem: PhoneDataKeyError?

    private init() {
        keyStore = PhoneDataKeyStore(secrets: PhoneDataKeychain())
        sceneActive = UIApplication.shared.applicationState == .active
        peers = keyStore.peers
        updateStatus()
    }

    private func ensureRunning() {
        guard !started else { return }
        started = true
        observeApp()
        startWatcher()
    }

    // MARK: - Watching the hotspot

    /// The hotspot interface exists only while Personal Hotspot is on. This starts the engine when
    /// it appears and a router is set up, and stops it when it goes away or changes, so it never
    /// listens anywhere else. It also reads keys that couldn't be read before, tries an engine that
    /// failed to start again, and plays the keep-alive sound while it is needed.
    private func syncWithHotspot(now: Date = Date()) {
        loadKeysIfNeeded()
        let hotspot = HotspotInterfaces.hotspotAddress()
        let armed = keyStore.loaded && !keyStore.peers.isEmpty

        let wanted = armed ? hotspot : nil
        if server.running, wanted != boundHost {
            log(armed ? "Hotspot address gone or changed, stopping" : "No router set up any more, stopping")
            server.stop()
            boundHost = nil
            resetLive()
        }
        if wanted == nil { setServerProblem(nil) }
        if let wanted, !server.running {
            startServer(on: wanted)
        } else if server.running, peersNeedPush {
            pushPeers()
        }

        policy.observe(hotspot: hotspot != nil, now: now)
        updateKeepAlive(armed: armed, now: now)
        updateStatus()
    }

    /// Reads the keys again when the Keychain couldn't be read before: it can be locked until the
    /// first unlock after a restart.
    private func loadKeysIfNeeded() {
        guard !keyStore.loaded else { return }
        keyStore.load()
        publishPeers()
        guard keyStore.problem != loggedKeyProblem else { return }
        loggedKeyProblem = keyStore.problem
        if let problem = keyStore.problem {
            log("The keys can't be used yet: \(problem.message)")
        } else {
            log("The keys can be read now, \(keyStore.peers.count) routers")
        }
    }

    /// If the engine can't start, the problem shows in `status`. The next look tries again.
    private func startServer(on host: String) {
        guard let keys = keyStore.keys else { return }
        do {
            try server.start(host: host, serverPrivateKey: keys.serverPrivateKey, peers: keys.peers)
        } catch {
            setServerProblem("Lucinate couldn't start sharing this iPhone's data. It will try again.", detail: error)
            return
        }
        boundHost = host
        peersNeedPush = false
        setServerProblem(nil)
        resetLive()
        startSampler() // only does something while the app is on screen
        log("Listening on \(host):\(PhoneDataServer.port) for \(keys.peers.count) routers")
    }

    private func pushPeers() {
        do {
            try server.setPeers(keyStore.peers)
        } catch {
            setServerProblem("Lucinate couldn't update the list of routers. It will try again.", detail: error)
            return
        }
        peersNeedPush = false
        setServerProblem(nil)
    }

    /// A problem is logged once, not on every try.
    private func setServerProblem(_ problem: String?, detail: Error? = nil) {
        guard problem != serverProblem else { return }
        serverProblem = problem
        if let problem {
            let reason = detail.map { String(describing: $0) } ?? "no detail"
            log("\(problem) (\(reason))")
        }
    }

    /// Routers were added or removed: the engine is told at once, and the watcher starts its wait
    /// over, since how often it looks depends on whether any router is set up.
    private func peersChanged() {
        publishPeers()
        peersNeedPush = true
        syncWithHotspot()
        if started { startWatcher() }
    }

    private func publishPeers() {
        let current = keyStore.peers
        if current != peers { peers = current }
    }

    /// Plays the silent sound while a router could use the iPhone, see `KeepAlivePolicy`. Once it
    /// stops, iOS suspends Lucinate until it is opened or a Shortcut wakes it.
    private func updateKeepAlive(armed: Bool, now: Date) {
        if policy.plays(hasPeers: armed, now: now) {
            keepAlive.start()
        } else if keepAlive.playing {
            let minutes = Int(KeepAlivePolicy.grace / 60)
            log(armed
                ? "No hotspot for \(minutes) minutes, letting iOS suspend Lucinate until it's opened"
                : "No router set up, stopping the keep-alive sound")
            keepAlive.stop()
        }
    }

    private func updateStatus() {
        let new: Status
        if let problem = keyStore.problem {
            new = .problem(problem.message)
        } else if keyStore.peers.isEmpty {
            new = .notSetUp
        } else if let serverProblem {
            new = .problem(serverProblem)
        } else if !server.running {
            new = .waitingForHotspot
        } else {
            new = connectedRouterIDs.isEmpty ? .waitingForRouter : .sharing
        }
        guard new != status else { return }
        status = new
        log("Status is now \(String(describing: new))")
    }

    // MARK: - Speeds and routers connected

    /// Every second while the app is on screen and the engine runs. With nothing running there is
    /// nothing to read, and in the background nothing on screen needs it, so it stops. It starts
    /// again with the engine and when the app comes back.
    private func startSampler() {
        sampler?.cancel()
        sampler = nil
        guard sceneActive, server.running else { return }
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                guard self?.sampleTraffic() == true else { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Reads the engine's counters: which routers are connected, and the speeds from how far the
    /// counters moved since the last sample. Only publishes what changed, so the screen isn't
    /// redrawn every second for nothing. `snapshot()` reads a small JSON from Go, which is fine to
    /// do on the main actor. False once the engine has stopped, which ends the sampler.
    private func sampleTraffic(now: Date = Date()) -> Bool {
        let snapshot = readServer()
        guard server.running else {
            lastSample = nil
            clearSpeeds()
            return false
        }
        defer { lastSample = (snapshot.bytesUp, snapshot.bytesDown, now) }
        guard let last = lastSample else { return true } // the first sample has nothing to compare with
        let seconds = now.timeIntervalSince(last.at)
        guard seconds > 0 else { return true }
        setSpeeds(
            up: Self.bitsPerSecond(snapshot.bytesUp, since: last.up, over: seconds),
            down: Self.bitsPerSecond(snapshot.bytesDown, since: last.down, over: seconds))
        return true
    }

    @discardableResult
    private func readServer() -> PhoneDataTraffic {
        let snapshot = server.snapshot() // also refreshes which addresses have a recent handshake
        if snapshot != traffic { traffic = snapshot }
        publishConnections()
        updateStatus()
        return snapshot
    }

    private func publishConnections() {
        let addresses = server.running ? server.connectedAddresses : []
        let connected = Set(peers.filter { addresses.contains($0.address) }.map(\.routerID))
        if connected != connectedRouterIDs { connectedRouterIDs = connected }
    }

    /// A session starts with zero speeds and nobody connected. The byte totals carry on.
    private func resetLive() {
        lastSample = nil
        clearSpeeds()
        let totals = server.snapshot()
        if totals != traffic { traffic = totals }
        publishConnections()
    }

    private func setSpeeds(up: Double, down: Double) {
        if up != upBitsPerSecond { upBitsPerSecond = up }
        if down != downBitsPerSecond { downBitsPerSecond = down }
    }

    private func clearSpeeds() {
        setSpeeds(up: 0, down: 0)
    }

    /// The engine's counters never go backwards. The guard is only a safety net.
    private static func bitsPerSecond(_ new: UInt64, since old: UInt64, over seconds: TimeInterval) -> Double {
        new >= old ? Double(new - old) * 8 / seconds : 0
    }

    // MARK: - The app coming and going

    /// The hotspot is watched every 5 seconds on screen, every 15 in the background, and rarely when
    /// nothing is set up. The slack lets iOS wake the app for this together with other timers.
    private func startWatcher() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.watchInterval else { return }
                try? await Task.sleep(for: interval.every, tolerance: interval.tolerance)
                guard !Task.isCancelled else { return }
                self?.syncWithHotspot()
            }
        }
    }

    private var watchInterval: (every: Duration, tolerance: Duration) {
        KeepAlivePolicy.watchInterval(sceneActive: sceneActive, idle: keyStore.loaded && keyStore.peers.isEmpty)
    }

    private func observeApp() {
        observe(UIApplication.didBecomeActiveNotification) { $0.appDidBecomeActive() }
        observe(UIApplication.willResignActiveNotification) { $0.appWillResignActive() }
        observe(UIApplication.didReceiveMemoryWarningNotification) { $0.server.freeMemory() }
    }

    private func observe(
        _ name: Notification.Name, _ handler: @escaping @MainActor @Sendable (PhoneDataController) -> Void
    ) {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { handler(self) }
            }
        }
    }

    private func appDidBecomeActive() {
        sceneActive = true
        // Not `wake()`: Lucinate is opened often for other things, and that is no reason to keep it running.
        syncWithHotspot()
        startWatcher() // the on-screen rhythm starts now, not after the background one's sleep
        startSampler() // samples at once, then every second
    }

    private func appWillResignActive() {
        sceneActive = false
        sampler?.cancel()
        sampler = nil
        lastSample = nil // or the first speed back on screen averages the whole time away
        clearSpeeds()
    }

    /// Internal log, read in Console.app. Never keys.
    private func log(_ message: String) {
        phoneDataLogger.info("\(message, privacy: .public)")
    }
}

// MARK: - Keychain

/// The keys' Keychain item. Its reads say why they failed, so "locked since a restart" is never
/// taken for "nothing saved": `KeychainStore` answers nil to both, and a new key made then would
/// lock out every router set up with the old one. It has a service of its own, so it never mixes
/// with the router logins `KeychainStore` keeps.
final class PhoneDataKeychain: PhoneDataSecretStore {
    private let service = "app.cogwheel.lucimobile.phonedata"
    private let account = "keys"
    /// A locked Keychain is asked again every few seconds. The log says so once, not each time.
    private var lastLoadFailure: OSStatus?

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = kCFBooleanTrue
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw loadFailure(errSecDecode) }
            lastLoadFailure = nil
            return data
        case errSecItemNotFound:
            lastLoadFailure = nil
            return nil
        default:
            throw loadFailure(status)
        }
    }

    func save(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // After the first unlock, so the engine can start in the background after a restart.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            phoneDataLogger.info("The keys couldn't be saved, Keychain status \(status, privacy: .public)")
            throw PhoneDataSecretFailure(code: status, lockedForNow: false)
        }
    }

    private func loadFailure(_ status: OSStatus) -> PhoneDataSecretFailure {
        if status != lastLoadFailure {
            lastLoadFailure = status
            phoneDataLogger.info("The keys couldn't be read, Keychain status \(status, privacy: .public)")
        }
        // Locked since a restart, until the first unlock: worth waiting out. Anything else isn't.
        return PhoneDataSecretFailure(code: status, lockedForNow: status == errSecInteractionNotAllowed)
    }
}
