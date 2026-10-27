import Foundation
import Observation

/// Tells the UI when the hotel's sign-in page is standing between the travel router and the
/// internet.
///
/// The router (travelmate) is the device behind the portal, so its status is the primary signal.
/// While it reports no internet and the phone is on the router's own LAN, the phone's Wi-Fi shares
/// that uplink, so a Wi-Fi-pinned probe of Apple's check page is a second opinion. iOS only shows
/// its own sign-in sheet when the phone joins a network, which is long before the router reaches
/// the portal, so this is what brings the page up afterwards.
///
/// Driven by `MainTabView`, which runs `run(appState:)` while the app is active and connected.
@MainActor
@Observable
final class CaptivePortalMonitor {
    // MARK: Contract

    private(set) var needsSignIn = false
    private(set) var portalHost: String?

    /// Opens the in-app sign-in sheet.
    func presentSignIn() {
        signInRequestCount += 1
    }

    // MARK: Sheet plumbing (MainTabView)

    /// Bumped each time the sign-in sheet should open, on demand or automatically.
    private(set) var signInRequestCount = 0

    /// MainTabView blocks automatic presentation while another sheet owns the screen; a sheet that
    /// was held back opens as soon as the block is lifted.
    func setAutoPresentationBlocked(_ blocked: Bool) {
        isAutoPresentBlocked = blocked
        if !blocked { presentAutomaticallyIfNeeded() }
    }

    // MARK: Fed by the sign-in sheet

    /// The probe saw the internet through the router, so the sign-in worked. Clears the banner at
    /// once; travelmate re-checks only about once a minute and keeps reporting the portal until
    /// then, so those stale reports are ignored for a while.
    func confirmOnline() {
        confirmedOnlineAt = Date()
        setNeedsSignIn(false, host: nil)
    }

    /// Re-reads the router now instead of at the next tick.
    func refreshNow() {
        guard appState != nil else { return }
        Task { await refresh() }
    }

    // MARK: Polling

    private static let pollInterval = Duration.seconds(15)
    private static let signInGrace: TimeInterval = 180

    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private var routerID: String?
    @ObservationIgnored private var refreshTicket = 0
    @ObservationIgnored private var confirmedOnlineAt: Date?
    @ObservationIgnored private var presentedEpisode: Episode?
    @ObservationIgnored private var isAutoPresentBlocked = false

    /// Polls every 15 s until cancelled or until polling no longer applies. Reviewer mode has no
    /// router, and a backgrounded app must not keep the radio busy; MainTabView restarts this
    /// when the app comes back or the router changes.
    func run(appState: AppState) async {
        self.appState = appState
        adopt(routerID: appState.selectedRouterID)
        while !Task.isCancelled, canPoll(appState) {
            await refresh()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    private func canPoll(_ appState: AppState) -> Bool {
        appState.phase == .main && appState.isAppActive && !appState.isReviewerMode
            && appState.service != nil
    }

    /// Forgets everything learned about the previous router.
    private func adopt(routerID newID: String?) {
        guard newID != routerID else { return }
        routerID = newID
        confirmedOnlineAt = nil
        presentedEpisode = nil
        setNeedsSignIn(false, host: nil)
    }

    private func refresh() async {
        guard let appState, let service = appState.service else { return }
        adopt(routerID: appState.selectedRouterID)
        refreshTicket &+= 1
        let ticket = refreshTicket
        let status: TravelmateStatus
        do {
            let raw = try await service.fileRead(path: TravelmateStatus.runtimeFilePath)
            status = TravelmateStatus.fromRuntime(raw, enabled: true)
        } catch {
            // The router is briefly unreachable or the file is missing: keep the last state
            // rather than flapping the banner.
            return
        }
        guard ticket == refreshTicket, appState.selectedRouterID == routerID else { return }

        switch status.connectivity {
        case .online:
            confirmedOnlineAt = nil
            presentedEpisode = nil
            setNeedsSignIn(false, host: nil)
        case .captivePortal(let host):
            if isWithinSignInGrace {
                setNeedsSignIn(false, host: nil)
            } else {
                confirmedOnlineAt = nil
                raise(host: host)
            }
        case .noInternet:
            await askPhoneAboutPortal(ticket: ticket)
        case .unknown:
            if status.isConnected {
                // Connected, but travelmate's own check result is missing or unreadable.
                await askPhoneAboutPortal(ticket: ticket)
            } else if !status.isProcessing, !status.statusText.isEmpty {
                // A definite "not connected": no uplink, so nothing to sign in to. Mid-connect or
                // no data keeps what we had.
                setNeedsSignIn(false, host: nil)
            }
        }
    }

    /// The router is connected but cannot confirm internet. Only when the phone shares the router's
    /// LAN does the phone's own Wi-Fi tell us anything about that uplink.
    private func askPhoneAboutPortal(ticket: Int) async {
        guard let router = appState?.selectedRouter,
            Self.isPrivateLANAddress(router.ipAddress)
        else {
            setNeedsSignIn(false, host: nil)
            return
        }
        let outcome = await WiFiPinnedProbe.run()
        guard ticket == refreshTicket else { return }
        switch outcome {
        case .captive(let redirect):
            confirmedOnlineAt = nil
            raise(host: redirect?.host)
        case .online:
            setNeedsSignIn(false, host: nil)
        case .unreachable:
            break  // could not ask: keep the last state
        }
    }

    private var isWithinSignInGrace: Bool {
        guard let confirmedOnlineAt else { return false }
        return Date().timeIntervalSince(confirmedOnlineAt) < Self.signInGrace
    }

    private func raise(host: String?) {
        setNeedsSignIn(true, host: host)
        presentAutomaticallyIfNeeded()
    }

    private func setNeedsSignIn(_ value: Bool, host: String?) {
        if needsSignIn != value { needsSignIn = value }
        if portalHost != host { portalHost = host }
    }

    // MARK: Automatic presentation

    /// One captive episode is one router behind one portal. The sheet opens by itself once per
    /// episode; a new episode starts when the router reports online again, or with another portal.
    private struct Episode {
        let routerID: String?
        let host: String?

        /// A missing host matches any: the router and the phone's probe may name the same portal
        /// at different moments.
        func isSame(as other: Episode) -> Bool {
            routerID == other.routerID && (host == nil || other.host == nil || host == other.host)
        }
    }

    private func presentAutomaticallyIfNeeded() {
        guard needsSignIn, !isAutoPresentBlocked else { return }
        let episode = Episode(routerID: routerID, host: portalHost)
        if let presentedEpisode, presentedEpisode.isSame(as: episode) { return }
        presentedEpisode = episode
        signInRequestCount += 1
    }

    // MARK: Address classification (pure)

    /// Whether a saved router address is one only a device on the same local network can reach:
    /// RFC 1918, link-local, unique-local IPv6, `.lan`, `.local`, `.home.arpa`, or a bare name.
    nonisolated static func isPrivateLANAddress(_ address: String) -> Bool {
        guard let endpoint = try? RouterEndpoint.parse(address) else { return false }
        var host = endpoint.host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }

        if host.contains(":") {
            guard let first = host.split(separator: ":", omittingEmptySubsequences: false).first,
                let group = Int(first, radix: 16)
            else { return false }
            return (group & 0xFFC0) == 0xFE80 || (group & 0xFE00) == 0xFC00
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = labels.compactMap { Int($0) }
        if labels.count == 4, octets.count == 4 {
            return octets[0] == 10
                || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168)
                || (octets[0] == 169 && octets[1] == 254)
        }
        return host.hasSuffix(".lan") || host.hasSuffix(".local") || host.hasSuffix(".home.arpa")
            || !host.contains(".")
    }
}
