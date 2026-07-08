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
    private(set) var loaded = false
    private(set) var isLoading = false

    /// A write (`set_settings`) is in flight — used to disable toggles.
    private(set) var isBusy = false
    private(set) var error: String?

    /// The `tailscale` rpcd object is absent (plugin not installed on the
    /// router) or the daemon reports `not_installed`. Drives the empty state
    /// instead of an error — this is expected on most routers.
    private(set) var notInstalled = false

    /// Forget everything (used when the selected router changes).
    func reset() {
        status = .empty
        settings = .empty
        loaded = false
        isLoading = false
        isBusy = false
        error = nil
        notInstalled = false
    }

    func load(service: RouterService) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            async let statusCall = service.tailscaleStatus()
            async let settingsCall = service.tailscaleSettings()
            let (statusJSON, settingsJSON) = try await (statusCall, settingsCall)
            status = TailscaleStatus.fromJSON(statusJSON)
            settings = TailscaleSettings.fromJSON(settingsJSON)
            notInstalled = !status.isInstalled
            loaded = true
        } catch let ubusError as UbusError where ubusError.isUnavailableObject {
            // The optional tailscale rpcd plugin isn't there — degrade to the
            // "not installed" empty state rather than an error.
            notInstalled = true
            loaded = true
        } catch is CancellationError {
            // View went away mid-load; keep whatever state we had.
        } catch {
            if !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
    }

    private func apply(formData: [String: JSONValue], service: RouterService) async -> Bool {
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            let result = try await service.tailscaleApply(formData: formData)
            if !result["error"].isNull {
                error = result["error"].coercedString ?? "Action failed"
                return false
            }
            await load(service: service)
            return true
        } catch {
            self.error = error.localizedDescription
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
