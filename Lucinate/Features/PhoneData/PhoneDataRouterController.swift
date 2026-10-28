import Foundation
import Observation
import UIKit

/// Owns the router side of Phone Data: what is installed and set up on the router, and the
/// three things that change it. Like the other controllers it borrows the authenticated
/// `RouterService` per call and never retains `AppState`.
@MainActor
@Observable
final class PhoneDataRouterController {
    /// Where setup stands, in the order the screen walks through it.
    enum Step: Equatable, Sendable {
        /// Software the router needs isn't installed.
        case install
        /// Everything is installed, the router isn't set up, and no iPhone is plugged in.
        case connectPhone
        /// An iPhone is plugged in and the router needs setting up, or needs to be pointed at
        /// the USB device the iPhone shows up as now.
        case finish
        case done
    }

    /// The router's answer; nil until the first successful `load`.
    private(set) var state: PhoneDataRouterState?

    /// The router has given a definitive answer. A failed call never sets it, so an error
    /// can not pass for a state.
    private(set) var loaded = false

    /// An action (install, set up, remove) is in flight. `load` does not set it.
    private(set) var isBusy = false
    /// What the router is doing for the action in flight.
    private(set) var busyMessage: String?

    /// Why the last `load` failed; nil after a successful one.
    private(set) var loadError: String?

    /// Why the last action failed. Cleared when the next one starts, or by `reset()`.
    private(set) var actionError: String?

    /// When the router's package list was last read. Polling reuses that answer for a while:
    /// reading the list makes the router run apk, the heaviest thing this screen asks of it.
    @ObservationIgnored private var packagesCheckedAt: ContinuousClock.Instant?
    private static let packageRecheckInterval: Duration = .seconds(30)

    /// Where setup stands. It only knows the router: whether the router belongs to this iPhone
    /// is `needsRepair(phonePublicKey:)`, which asks for the phone's key. Not meaningful
    /// before `loaded`.
    var step: Step { Self.step(for: state) }

    /// The router's tunnel points at a different phone than this iPhone (the iPhone's keys
    /// were reset, or the router was set up from another one).
    func needsRepair(phonePublicKey: String) -> Bool {
        Self.needsRepair(state: state, phonePublicKey: phonePublicKey)
    }

    /// Forget everything (used when the selected router changes).
    func reset() {
        state = nil
        loaded = false
        isBusy = false
        busyMessage = nil
        loadError = nil
        actionError = nil
        packagesCheckedAt = nil
    }

    // MARK: - Load

    /// Reads the router's state. Does nothing while an action is in flight: actions read the
    /// state again themselves when they finish, so the screen can poll this freely.
    func load(service: RouterService) async {
        guard !isBusy else { return }
        await refresh(service: service)
    }

    /// True when the state was read. `forcePackageCheck` reads the router's package list even
    /// when a recent answer would still do.
    @discardableResult
    private func refresh(service: RouterService, forcePackageCheck: Bool = false) async -> Bool {
        var known: [String]?
        if !forcePackageCheck, let state, let checkedAt = packagesCheckedAt,
            ContinuousClock.now - checkedAt < Self.packageRecheckInterval
        {
            known = state.missingPackages
        }
        do {
            state = try await service.phoneDataState(knownMissingPackages: known)
            if known == nil { packagesCheckedAt = ContinuousClock.now }
            loaded = true
            loadError = nil
            return true
        } catch is CancellationError {
            // View went away mid-load; keep whatever state we had.
            return false
        } catch {
            if !Task.isCancelled {
                loadError = Self.message(for: error)
            }
            return false
        }
    }

    // MARK: - Actions

    /// Installs the software the router is missing. True when it is all there afterwards.
    func installPackages(service: RouterService) async -> Bool {
        guard !isBusy else { return false }
        if let state, state.packagesInstalled { return true }
        let names = state?.missingPackages ?? RouterService.phoneDataPackages

        begin("Installing USB and tunnel support…")
        // A minutes-long install: the screen lock would suspend the network work that
        // drives it, so the display stays awake for exactly as long as it runs.
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            end()
        }

        do {
            let result = try await service.installPhoneDataPackages(names)
            guard result.succeeded else {
                actionError = Self.installFailureMessage(result)
                return false
            }
            // apk saying "done" is not the proof: what the router lists as installed is.
            if await refresh(service: service, forcePackageCheck: true), let state,
                !state.packagesInstalled
            {
                actionError =
                    "The router finished, but some of the software is still missing: "
                    + state.missingPackages.joined(separator: ", ") + ". Try again."
                return false
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            if !Task.isCancelled {
                actionError = Self.message(for: error)
            }
            return false
        }
    }

    /// Sets the router up for the iPhone that is plugged in: new keys for the router (the
    /// phone keeps its own), the router's interfaces and firewall zone. Also the way to fix a
    /// router that belongs to another phone, or lost track of the iPhone's USB device. True
    /// when the router has been set up.
    func finishSetup(
        service: RouterService, routerID: String, phone: PhoneDataController
    ) async -> Bool {
        guard !isBusy else { return false }
        begin("Setting up the router…")
        defer { end() }

        do {
            guard let device = await service.detectIPhoneUSBDevice() else {
                if !Task.isCancelled {
                    actionError =
                        "Plug your iPhone into the router's USB port, turn on Personal Hotspot "
                        + "and tap Trust on the iPhone."
                }
                return false
            }
            let keys = try phone.prepareRouter(routerID: routerID)
            try await service.applyPhoneData(keys: keys, usbDevice: device)
            await refresh(service: service)
            return true
        } catch is CancellationError {
            return false
        } catch {
            if !Task.isCancelled {
                actionError = Self.message(for: error)
            }
            return false
        }
    }

    /// Takes Phone Data off the router, and the router off the phone. The software stays
    /// installed. True when it is gone.
    func remove(service: RouterService, routerID: String, phone: PhoneDataController) async -> Bool {
        guard !isBusy else { return false }
        begin("Removing Phone Data from the router…")
        defer { end() }

        do {
            try await service.removePhoneData()
            // Only once the router has let go: until then the phone must keep accepting it.
            phone.forgetRouter(routerID: routerID)
            await refresh(service: service)
            return true
        } catch is CancellationError {
            return false
        } catch {
            if !Task.isCancelled {
                actionError = Self.message(for: error)
            }
            return false
        }
    }

    private func begin(_ message: String) {
        isBusy = true
        busyMessage = message
        actionError = nil
    }

    private func end() {
        isBusy = false
        busyMessage = nil
    }

    // MARK: - Derived state and wording

    /// install -> connect the phone -> finish -> done. Once the router is set up it stays done
    /// with the phone unplugged; with the phone plugged in it is only done when the router
    /// uses the USB device the phone shows up as.
    nonisolated static func step(for state: PhoneDataRouterState?) -> Step {
        guard let state, state.packagesInstalled else { return .install }
        guard let usbDevice = state.usbDevice else {
            return state.configured ? .done : .connectPhone
        }
        if !state.configured || state.configuredDevice != usbDevice { return .finish }
        return .done
    }

    /// A router that isn't set up isn't set up for another phone. An unknown phone key can't
    /// disagree with anything.
    nonisolated static func needsRepair(
        state: PhoneDataRouterState?, phonePublicKey: String
    ) -> Bool {
        let phoneKey = phonePublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let state, state.configured, !phoneKey.isEmpty else { return false }
        return state.configuredPhonePublicKey != phoneKey
    }

    /// An error as a plain sentence. The packages and the router's ACL have their own
    /// failure modes; everything else keeps the transport's wording.
    nonisolated static func message(for error: Error) -> String {
        if error is PackageCatalogError {
            return PhoneDataRouterError.opkgRouter.localizedDescription
        }
        if let ubusError = error as? UbusError, ubusError.isAccessDenied {
            return PhoneDataRouterError.notPermitted.localizedDescription
        }
        return error.localizedDescription
    }

    /// apk's reason when an install fails, after a plain sentence of ours. Only its first line:
    /// the rest is a list of package names.
    nonisolated static func installFailureMessage(_ result: RouterService.ExecResult) -> String {
        let reason = result.combinedOutput
            .split(whereSeparator: { $0.isNewline })
            .first
            .map { String($0.prefix(120)) }
        return "The router couldn't install the software it needs"
            + (reason.map { " (\($0))" } ?? "")
            + ". Make sure the router is online, then try again."
    }
}
