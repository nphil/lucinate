import Foundation
import Observation

/// Loads interface data for the Network → Interfaces segment, mirroring
/// `interfaces_screen.dart`: wired interfaces from `network.interface dump`,
/// wireless SSIDs from luci-rpc, and optional WireGuard peer info.
@MainActor
@Observable
final class InterfacesController {
    /// Logical interfaces from the dump, excluding wireless ifnames.
    private(set) var wired: [NetworkInterface] = []
    /// SSID broadcasts / STA uplinks from luci-rpc getWirelessDevices.
    private(set) var wireless: [WirelessNetwork] = []
    /// WireGuard peers keyed by interface name (empty when the
    /// luci.wireguard rpcd object is not installed).
    private(set) var wireGuardPeers: [String: [WireGuardPeer]] = [:]

    /// True only while loading with nothing cached (cached-first UX).
    private(set) var isLoading = false
    private(set) var error: String?

    var isEmpty: Bool { wired.isEmpty && wireless.isEmpty }

    func load(service: RouterService?) async {
        guard let service else {
            wired = []
            wireless = []
            wireGuardPeers = [:]
            error = nil
            return
        }

        if isEmpty { isLoading = true }
        defer { isLoading = false }

        do {
            // Required: the interface dump. Failure here is the error state.
            let dump = try await service.interfaceDump()
            let all = (dump["interface"].arrayValue ?? []).map(NetworkInterface.fromDump)

            // Optional: wireless devices (wired-only routers lack them).
            var networks: [WirelessNetwork] = []
            if let wirelessJSON = try? await service.wirelessDevices() {
                networks = WirelessNetwork.fromWirelessDevices(wirelessJSON)
            }

            // Optional: WireGuard peers (luci.wireguard may be absent).
            var peers: [String: [WireGuardPeer]] = [:]
            do {
                let wgJSON = try await service.wireGuardInstances()
                peers = WireGuardPeer.parse(fromWgInstances: wgJSON)
            } catch let ubusError as UbusError where ubusError.isUnavailableObject {
                peers = [:]
            } catch {
                peers = [:]
            }

            // Wired list = dump entries whose device is not a wireless ifname.
            let wirelessIfnames = Set(networks.map(\.device).filter { !$0.isEmpty })
            wired = all.filter { !wirelessIfnames.contains($0.device) }
            wireless = networks
            wireGuardPeers = peers
            error = nil
        } catch {
            if isEmpty {
                self.error = error.localizedDescription
            }
        }
    }
}
