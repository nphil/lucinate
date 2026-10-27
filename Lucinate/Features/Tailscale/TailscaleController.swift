import Foundation
import Observation

/// Owns the Tailscale module's state, mirroring
/// `lib/state/tailscale_controller.dart`. The feature stays self-contained:
/// the authenticated RPC channel is borrowed per-call via the `RouterService`
/// passed into each method, so the controller never retains `AppState`.
@MainActor
@Observable
final class TailscaleController {
    private(set) var status: TailscaleStatus = .empty
    private(set) var settings: TailscaleSettings = .empty

    /// The router has given a definitive answer: a status payload, or proof
    /// that the plugin is absent. A failed call never sets it, so an error
    /// can not pass for a state.
    private(set) var loaded = false
    private(set) var isLoading = false

    /// A write (`set_settings`) is in flight — used to disable toggles.
    private(set) var isBusy = false

    /// Why the last `load` failed; nil after a successful one. Before the
    /// first answer it drives the error screen, afterwards an inline notice
    /// over the last known data.
    private(set) var loadError: String?

    /// Why the last write failed (for toasts); cleared when the next starts.
    private(set) var actionError: String?

    /// Tailscale is definitively absent: the plugin reported `not_installed`
    /// or the `tailscale` ubus object is not registered.
    var isNotInstalled: Bool { loaded && status.state == .notInstalled }

    /// Forget everything (used when the selected router changes).
    func reset() {
        status = .empty
        settings = .empty
        loaded = false
        isLoading = false
        isBusy = false
        loadError = nil
        actionError = nil
    }

    func load(service: RouterService) async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let statusCall = service.tailscaleStatus()
            async let settingsCall = service.tailscaleSettings()
            let (statusJSON, settingsJSON) = try await (statusCall, settingsCall)
            status = TailscaleStatus.fromJSON(statusJSON)
            settings = TailscaleSettings.fromJSON(settingsJSON)
            loaded = true
            loadError = nil
        } catch is CancellationError {
            // View went away mid-load; keep whatever state we had.
        } catch let ubusError as UbusError where ubusError.isUnavailableObject {
            // Object missing or access refused: only the router's object
            // list can tell the two apart.
            let objects = try? await service.ubusObjects()
            if Self.isPluginAbsent(objects: objects) {
                status = .notInstalled
                settings = .empty
                loaded = true
                loadError = nil
            } else if !Task.isCancelled {
                loadError = ubusError.localizedDescription
            }
        } catch {
            if !Task.isCancelled {
                loadError = error.localizedDescription
            }
        }
    }

    /// `list` needs no session, so it separates "the plugin isn't installed"
    /// from a router or session that is misbehaving. A failed or empty list is
    /// a broken reply, not proof of absence.
    nonisolated static func isPluginAbsent(objects: [String]?) -> Bool {
        guard let objects, !objects.isEmpty else { return false }
        return !objects.contains("tailscale")
    }

    private func apply(formData: [String: JSONValue], service: RouterService) async -> Bool {
        isBusy = true
        actionError = nil
        defer { isBusy = false }
        do {
            let result = try await service.tailscaleApply(formData: formData)
            if !result["error"].isNull {
                actionError = result["error"].coercedString ?? "Action failed"
                return false
            }
            await load(service: service)
            return true
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }

    /// Flip a single boolean setting (e.g. `accept_routes`, `shields_up`,
    /// `disable_magic_dns`, `advertise_exit_node`), preserving everything else
    /// — `set_settings` requires the FULL form, so unspecified flags would be
    /// cleared otherwise.
    @discardableResult
    func setFlag(_ key: String, value: Bool, service: RouterService) async -> Bool {
        let data = settings.toFormData(
            exitNodeIp: status.currentExitNode?.ip ?? "",
            overrides: [key: .string(value ? "1" : "0")]
        )
        return await apply(formData: data, service: service)
    }

    /// Select an exit node by IP, or pass nil/"" to clear it.
    @discardableResult
    func setExitNode(ip: String?, service: RouterService) async -> Bool {
        let target = ip ?? ""
        let data = settings.toFormData(
            exitNodeIp: target,
            overrides: ["exit_node": .string(target)]
        )
        return await apply(formData: data, service: service)
    }
}
