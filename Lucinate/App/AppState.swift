import SwiftUI
import Observation

/// Root application state: auth lifecycle, multi-router management, the active
/// connection, throughput polling, reboot recovery, reviewer mode, and toasts.
@MainActor
@Observable
final class AppState {
    enum Phase: Equatable {
        case splash
        case login
        case main
    }

    // MARK: Lifecycle

    private(set) var phase: Phase = .splash
    private(set) var isReviewerMode = false

    /// True while the scene is `.active`. Pollers outside this class gate on
    /// it so nothing runs against a suspended app.
    private(set) var isAppActive = true
    /// +1 each time the app returns from the background in `.main`, after the
    /// session was re-validated. Screens `.onChange` it to refresh their data.
    private(set) var resumeCount = 0
    /// False after two consecutive failed throughput polls, true again on the
    /// next success. Drives the connection pill's "Reconnecting…" state.
    private(set) var linkHealthy = true

    // MARK: Cross-tab navigation

    enum MainTab: Hashable {
        case home, network, travelmate, tailscale
    }

    enum NetworkSegment: String, CaseIterable {
        case clients = "Clients"
        case interfaces = "Interfaces"
    }

    var selectedTab: MainTab = .home
    /// Set before switching to the Network tab to auto-scroll/expand an
    /// interface card (consumed by NetworkView).
    var networkScrollTarget: String?
    var networkSegment: NetworkSegment = .clients

    /// Jump to an interface in the Network tab (or its dedicated tab).
    func openInterface(named name: String) {
        let lower = name.lowercased()
        if lower.contains("tailscale") {
            selectedTab = .tailscale
        } else if lower.contains("travel_wan") || lower == "travelmate" {
            selectedTab = .travelmate
        } else {
            networkSegment = .interfaces
            networkScrollTarget = name
            selectedTab = .network
        }
    }

    // MARK: Routers

    private(set) var routers: [Router] = []
    private(set) var selectedRouterID: String?

    var selectedRouter: Router? {
        routers.first { $0.id == selectedRouterID }
    }

    // MARK: Active connection

    private(set) var client: UbusClient?
    private(set) var service: RouterService?

    /// Board info from `system board` (hostname, model, release).
    private(set) var boardInfo: JSONValue = .null

    var hostname: String {
        boardInfo["hostname"].stringValue
            ?? selectedRouter?.lastKnownHostname
            ?? selectedRouter?.ipAddress
            ?? "Router"
    }

    // MARK: Login UI state

    var isLoggingIn = false
    var loginError: String?
    /// Set when a TLS handshake was refused; drives the "Certificate Warning"
    /// accept-risk dialog. Holds "host:port".
    var pendingCertificate: String?
    private var pendingLogin: (address: String, username: String, password: String)?

    /// A silent auto-reconnect (from saved credentials) is in flight on the
    /// Login screen. The login form stays fully usable underneath so the user
    /// is never trapped when the router is unreachable.
    private(set) var isAutoConnecting = false
    /// Hostname/address shown in the "Connecting to …" banner.
    private(set) var autoConnectTarget: String?
    private var autoConnectTask: Task<Void, Never>?

    /// Saved credentials for pre-filling the login form (so a manual retry is
    /// one tap when auto-connect couldn't reach the router).
    var savedLoginPrefill: (address: String, username: String, password: String)? {
        let store = KeychainStore.shared
        guard let ip = store.string(for: KeychainStore.Key.ipAddress),
            let username = store.string(for: KeychainStore.Key.username),
            let password = store.string(for: KeychainStore.Key.password)
        else { return nil }
        let useHttps = store.string(for: KeychainStore.Key.useHttps) == "true"
        return (useHttps ? "https://\(ip)" : ip, username, password)
    }

    // MARK: Reboot

    private(set) var isRebooting = false

    // MARK: Toasts

    private(set) var toast: ToastMessage?

    struct ToastMessage: Equatable, Identifiable {
        let id: Int
        let text: String
        let isPersistent: Bool
    }
    private var toastCounter = 0

    func showToast(_ text: String, persistent: Bool = false) {
        toastCounter += 1
        toast = ToastMessage(id: toastCounter, text: text, isPersistent: persistent)
        if !persistent {
            let shown = toast
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.toast == shown else { return }
                self.toast = nil
            }
        }
    }

    func dismissToast() { toast = nil }

    // MARK: Throughput

    private(set) var throughput = ThroughputCalculator()
    private var throughputTask: Task<Void, Never>?
    private var throughputDevices: Set<String> = []
    private var consecutivePollFailures = 0
    private static let pollFailuresBeforeUnhealthy = 2
    private var isInBackground = false
    private var resumeTask: Task<Void, Never>?

    // MARK: - Bootstrap (splash → auto-login → main | login)

    func bootstrap() async {
        loadRouters()

        if KeychainStore.shared.string(for: "reviewer_mode_enabled") == "true" {
            enterReviewerMode(persist: false)
            return
        }

        // Brief branded splash, then always land on the Login screen — never
        // block the splash on a network call. When the router is reachable the
        // background auto-connect promotes us to the app; when it isn't, the
        // user is already on Login (reviewer mode + manual retry available).
        try? await Task.sleep(nanoseconds: 900_000_000)

        guard let saved = savedLoginPrefill else {
            phase = .login
            return
        }
        phase = .login
        beginAutoConnect(
            address: saved.address, username: saved.username, password: saved.password)
    }

    /// Silent reconnect from saved credentials, run in the background so the
    /// Login screen stays interactive. Fails fast (one attempt) — a dead router
    /// shouldn't leave the user waiting.
    func beginAutoConnect(address: String, username: String, password: String) {
        autoConnectTask?.cancel()
        isAutoConnecting = true
        autoConnectTarget =
            selectedRouter?.lastKnownHostname ?? (try? RouterEndpoint.parse(address))?.host
            ?? address
        autoConnectTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.login(
                address: address, username: username, password: password,
                quiet: true, maxAttempts: 1)
            self.isAutoConnecting = false
            self.autoConnectTask = nil
        }
    }

    /// User dismissed the "Connecting…" banner to log in manually / enter
    /// reviewer mode. Cancels the silent attempt (quiet mode makes the
    /// resulting cancellation harmless — no cert dialog, no error).
    func cancelAutoConnect() {
        autoConnectTask?.cancel()
        autoConnectTask = nil
        isAutoConnecting = false
    }

    // MARK: - Login / logout

    /// Returns true on success. On TLS trust failure, stashes the attempt and
    /// sets `pendingCertificate` so the UI can offer "Accept Risk".
    @discardableResult
    func login(
        address: String, username: String, password: String,
        quiet: Bool = false, maxAttempts: Int = 3
    ) async -> Bool {
        // A manual login supersedes any in-flight silent auto-connect.
        if !quiet { cancelAutoConnect() }

        loginError = nil
        isLoggingIn = true
        defer { isLoggingIn = false }

        let endpoint: RouterEndpoint
        do {
            endpoint = try RouterEndpoint.parse(address)
        } catch {
            if !quiet { loginError = error.localizedDescription }
            return false
        }

        stopThroughputPolling()
        cancelResume()
        if let old = client { await old.invalidate() }

        let newClient = UbusClient(endpoint: endpoint)
        do {
            let result = try await newClient.login(
                username: username, password: password, maxAttempts: maxAttempts)
            client = newClient
            service = RouterService(transport: newClient)
            isReviewerMode = false

            persistCredentials(
                ipAddress: endpoint.hostWithPort, username: username, password: password,
                useHttps: result.useHttps)
            await refreshBoardInfo()
            upsertRouter(
                ipAddress: endpoint.hostWithPort, username: username, password: password,
                useHttps: result.useHttps,
                hostname: boardInfo["hostname"].stringValue)
            recordLinkResult(succeeded: true)
            startThroughputPolling()
            phase = .main
            return true
        } catch let error as UbusError {
            await newClient.invalidate()
            // Silent auto-connect never pops dialogs or shows errors — a
            // returning user's cert is already trusted, and a cancelled/timed-
            // out silent attempt must not surface as a certificate prompt.
            if case .certificateNotTrusted(let hostPort) = error, !quiet {
                pendingLogin = (address, username, password)
                pendingCertificate = hostPort
                loginError = nil
            } else if !quiet {
                loginError = error.localizedDescription
            }
            return false
        } catch {
            await newClient.invalidate()
            if !quiet { loginError = error.localizedDescription }
            return false
        }
    }

    /// User tapped "Accept Risk" in the certificate warning dialog.
    func acceptPendingCertificate() async {
        guard let hostPort = pendingCertificate else { return }
        KeychainStore.shared.acceptCertificate(hostPort: hostPort)
        pendingCertificate = nil
        if let pending = pendingLogin {
            pendingLogin = nil
            await login(address: pending.address, username: pending.username, password: pending.password)
        }
    }

    func declinePendingCertificate() {
        pendingCertificate = nil
        pendingLogin = nil
    }

    func logout() {
        stopThroughputPolling()
        cancelResume()
        let oldClient = client
        Task { await oldClient?.invalidate() }
        client = nil
        service = nil
        boardInfo = .null
        let store = KeychainStore.shared
        store.delete(KeychainStore.Key.ipAddress)
        store.delete(KeychainStore.Key.username)
        store.delete(KeychainStore.Key.password)
        store.delete(KeychainStore.Key.useHttps)
        store.clearAcceptedCertificates()
        if isReviewerMode {
            store.delete("reviewer_mode_enabled")
            isReviewerMode = false
        }
        phase = .login
    }

    private func persistCredentials(
        ipAddress: String, username: String, password: String, useHttps: Bool
    ) {
        let store = KeychainStore.shared
        store.set(ipAddress, for: KeychainStore.Key.ipAddress)
        store.set(username, for: KeychainStore.Key.username)
        store.set(password, for: KeychainStore.Key.password)
        store.set(useHttps ? "true" : "false", for: KeychainStore.Key.useHttps)
    }

    // MARK: - Reviewer mode

    func enterReviewerMode(persist: Bool = true) {
        if persist {
            KeychainStore.shared.set("true", for: "reviewer_mode_enabled")
        }
        isReviewerMode = true
        let mock = MockUbusClient()
        service = RouterService(transport: mock)
        client = nil
        boardInfo = .null
        phase = .main
        Task { await refreshBoardInfo() }
        recordLinkResult(succeeded: true)
        startThroughputPolling()
    }

    func exitReviewerMode() {
        KeychainStore.shared.delete("reviewer_mode_enabled")
        isReviewerMode = false
        stopThroughputPolling()
        cancelResume()
        service = nil
        phase = .login
    }

    // MARK: - Saved routers

    private func loadRouters() {
        let store = KeychainStore.shared
        if let text = store.string(for: KeychainStore.Key.routers),
            let data = text.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([Router].self, from: data)
        {
            routers = decoded
        }
        selectedRouterID = store.string(for: KeychainStore.Key.selectedRouterId)
    }

    private func saveRouters() {
        if let data = try? JSONEncoder().encode(routers),
            let text = String(data: data, encoding: .utf8)
        {
            KeychainStore.shared.set(text, for: KeychainStore.Key.routers)
        }
        if let selectedRouterID {
            KeychainStore.shared.set(selectedRouterID, for: KeychainStore.Key.selectedRouterId)
        } else {
            KeychainStore.shared.delete(KeychainStore.Key.selectedRouterId)
        }
    }

    private func upsertRouter(
        ipAddress: String, username: String, password: String, useHttps: Bool, hostname: String?
    ) {
        let id = Router.makeID(ipAddress: ipAddress, username: username)
        let router = Router(
            id: id, ipAddress: ipAddress, username: username, password: password,
            useHttps: useHttps, lastKnownHostname: hostname)
        if let index = routers.firstIndex(where: { $0.id == id }) {
            routers[index] = router
        } else {
            routers.append(router)
        }
        selectedRouterID = id
        saveRouters()
    }

    /// Add a saved router without switching to it. Returns false on duplicate.
    func addRouter(_ router: Router) -> Bool {
        guard !routers.contains(where: { $0.id == router.id }) else { return false }
        routers.append(router)
        saveRouters()
        return true
    }

    func updateRouter(_ router: Router) {
        if let index = routers.firstIndex(where: { $0.id == router.id }) {
            routers[index] = router
            saveRouters()
        }
    }

    func removeRouter(id: String) {
        if let router = routers.first(where: { $0.id == id }),
            let key = Self.certificateKey(of: router)
        {
            KeychainStore.shared.removeCertificate(hostPort: key)
        }
        routers.removeAll { $0.id == id }
        if selectedRouterID == id {
            selectedRouterID = routers.first?.id
        }
        saveRouters()
    }

    /// Re-keys a saved router whose address or username changed, in place. The
    /// active router stays active (the new id is persisted as the selection),
    /// and its accepted certificate is dropped only when host:port changed.
    /// Returns false when the new id already belongs to another router.
    func replaceRouter(id oldID: String, with replacement: Router) -> Bool {
        guard let index = routers.firstIndex(where: { $0.id == oldID }) else { return false }
        if replacement.id != oldID, routers.contains(where: { $0.id == replacement.id }) {
            return false
        }
        if let oldKey = Self.certificateKey(of: routers[index]),
            oldKey != Self.certificateKey(of: replacement)
        {
            KeychainStore.shared.removeCertificate(hostPort: oldKey)
        }
        routers[index] = replacement
        if selectedRouterID == oldID { selectedRouterID = replacement.id }
        saveRouters()
        return true
    }

    /// The "host:port" accepted certificates are stored under.
    private static func certificateKey(of router: Router) -> String? {
        let scheme = router.useHttps ? "https://" : "http://"
        return (try? RouterEndpoint.parse(scheme + router.ipAddress))?.certificateKey
    }

    /// Switch the active connection to a saved router.
    func switchRouter(id: String) async {
        guard let router = routers.first(where: { $0.id == id }), id != selectedRouterID || client == nil
        else { return }
        selectedRouterID = id
        saveRouters()
        throughput.reset()
        let address = (router.useHttps ? "https://" : "") + router.ipAddress
        let ok = await login(
            address: address, username: router.username, password: router.password)
        if ok {
            showToast("Connected to \(hostname)")
        } else if loginError != nil {
            showToast("Could not connect to \(router.displayName)")
        }
    }

    // MARK: - Board / system info

    /// One `system board` read. Returns whether the router answered.
    @discardableResult
    func refreshBoardInfo() async -> Bool {
        guard let service, let board = try? await service.board() else { return false }
        boardInfo = board
        // Keep the saved router's hostname fresh for the switcher menu.
        if let name = board["hostname"].stringValue,
            let id = selectedRouterID,
            let index = routers.firstIndex(where: { $0.id == id }),
            routers[index].lastKnownHostname != name
        {
            routers[index] = routers[index].copyWith(lastKnownHostname: name)
            saveRouters()
        }
        return true
    }

    // MARK: - Throughput polling (2s cadence)

    func startThroughputPolling() {
        stopThroughputPolling()
        guard service != nil, !isInBackground else { return }
        throughputTask = Task { [weak self] in
            // Which devices count toward the aggregate. Retried each round until
            // the router answers: an empty set means every non-loopback device,
            // which double-counts bridge members.
            var devicesResolved = false
            while !Task.isCancelled {
                guard let self, let service = self.service else { return }
                do {
                    if !devicesResolved {
                        let dump = try await service.interfaceDump()
                        self.throughputDevices = ThroughputCalculator.aggregateDevices(
                            fromInterfaceDump: dump)
                        devicesResolved = true
                    }
                    let devices = try await service.networkDevices()
                    self.throughput.ingest(
                        devices: devices,
                        includedDevices: self.throughputDevices,
                        now: Date().timeIntervalSince1970)
                    self.recordLinkResult(succeeded: true)
                } catch {
                    // A cancelled poll (router switch, background) says nothing about the link.
                    if Task.isCancelled { return }
                    self.recordLinkResult(succeeded: false)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stopThroughputPolling() {
        throughputTask?.cancel()
        throughputTask = nil
    }

    // MARK: - App lifecycle (scene phase)

    /// Driven by RootView. Sockets die and LuCI sessions expire while the phone
    /// is away, so polling stops in the background; coming back re-validates
    /// the session (the transport re-logs in if it expired) before polling
    /// resumes and screens are told to refresh.
    func handleScenePhase(_ scenePhase: ScenePhase) {
        switch scenePhase {
        case .active:
            isAppActive = true
            if isInBackground {
                isInBackground = false
                resumeFromBackground()
            }
        case .inactive:
            isAppActive = false
        case .background:
            isAppActive = false
            isInBackground = true
            cancelResume()
            stopThroughputPolling()
        @unknown default:
            break
        }
    }

    private func resumeFromBackground() {
        cancelResume()
        guard phase == .main, !isRebooting, !isLoggingIn else { return }
        // The first sample after the gap would average the whole absence.
        throughput.reset()
        resumeTask = Task { [weak self] in
            guard let self else { return }
            // Reviewer mode's mock transport has no session to validate.
            if !self.isReviewerMode, await self.refreshBoardInfo() {
                self.recordLinkResult(succeeded: true)
            }
            guard !Task.isCancelled, self.phase == .main, !self.isInBackground,
                !self.isRebooting
            else { return }
            self.startThroughputPolling()
            self.resumeCount += 1
        }
    }

    private func cancelResume() {
        resumeTask?.cancel()
        resumeTask = nil
    }

    /// Two consecutive failed polls mean the link is down; any success (poll,
    /// login, session re-validation) restores it.
    private func recordLinkResult(succeeded: Bool) {
        if succeeded {
            consecutivePollFailures = 0
            if !linkHealthy { linkHealthy = true }
        } else {
            consecutivePollFailures += 1
            if consecutivePollFailures >= Self.pollFailuresBeforeUnhealthy, linkHealthy {
                linkHealthy = false
            }
        }
    }

    // MARK: - Reboot (lockout + recovery polling — §3.8)

    func reboot() async {
        guard let service else { return }
        isRebooting = true
        stopThroughputPolling()
        showToast("Rebooting… Connection will be interrupted.", persistent: true)
        do {
            try await service.reboot()
        } catch {
            // The connection often drops before the response arrives — expected.
        }
        await waitForRouterRecovery()
    }

    private func waitForRouterRecovery() async {
        guard let client else {
            // Reviewer mode: pretend the reboot worked.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            isRebooting = false
            dismissToast()
            showToast("Router is back online, reconnecting…")
            startThroughputPolling()
            return
        }
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        let delays: [UInt64] = [3, 5, 8, 12, 18, 20]
        var attempt = 0
        while attempt < 40 {
            if await client.probeReachable() {
                dismissToast()
                showToast("Router is back online, reconnecting…")
                if let router = selectedRouter {
                    _ = await login(
                        address: (router.useHttps ? "https://" : "") + router.ipAddress,
                        username: router.username, password: router.password, quiet: true)
                }
                isRebooting = false
                return
            }
            let delay = delays[min(attempt, delays.count - 1)]
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            attempt += 1
        }
        dismissToast()
        showToast("Router did not come back online. Check the connection.")
        isRebooting = false
    }
}
