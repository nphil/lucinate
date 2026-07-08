import Foundation
import Observation

/// Loads and caches the client list for the Network → Clients segment,
/// mirroring `clients_screen.dart` (fetchAggregatedClients /
/// fetchClientsForSelectedRouter).
@MainActor
@Observable
final class ClientsController {
    /// When true, gather clients from every saved router (the Flutter "All"
    /// segment). Persisted across launches; defaults to true.
    private(set) var aggregateAll: Bool

    private(set) var clients: [Client] = []
    /// True only while loading with nothing cached (cached-first UX).
    private(set) var isLoading = false
    private(set) var error: String?

    /// Uppercased MACs blocked by app-created firewall rules on the ACTIVE
    /// router. Only populated in selected-router mode — in aggregate mode the
    /// active service may not match a client's router, so actions are hidden.
    private(set) var blockedMACs: Set<String> = []
    /// True when `etherwake` exists on the active router (checked once per
    /// load, selected-router mode only).
    private(set) var wolAvailable = false

    private static let aggregateDefaultsKey = "clients_aggregate_all"

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: ClientsController.aggregateDefaultsKey) == nil {
            aggregateAll = true
        } else {
            aggregateAll = defaults.bool(forKey: ClientsController.aggregateDefaultsKey)
        }
    }

    func setAggregateAll(_ value: Bool) {
        guard value != aggregateAll else { return }
        aggregateAll = value
        UserDefaults.standard.set(value, forKey: ClientsController.aggregateDefaultsKey)
    }

    // MARK: - Loading

    /// Loads clients. Pass the active service and the saved-router list in;
    /// the controller never retains AppState.
    func load(service: RouterService?, routers: [Router]) async {
        if clients.isEmpty { isLoading = true }
        defer { isLoading = false }

        if aggregateAll && !routers.isEmpty {
            // ALL mode: connect to every saved router in parallel, skipping
            // failures silently (mirrors fetchAggregatedClients).
            let gathered = await withTaskGroup(of: [Client].self) { group in
                for router in routers {
                    group.addTask { await ClientsController.gatherFromRouter(router) }
                }
                var all: [Client] = []
                for await part in group { all.append(contentsOf: part) }
                return all
            }
            clients = ClientsController.dedupeAndSort(gathered)
            error = nil
            blockedMACs = []
            wolAvailable = false
        } else if let service {
            // SELECTED mode: the already-connected service only.
            do {
                let gathered = try await ClientsController.gather(service: service)
                clients = ClientsController.dedupeAndSort(gathered)
                error = nil
            } catch {
                if clients.isEmpty {
                    self.error = error.localizedDescription
                }
            }
            blockedMACs = (try? await service.blockedClientMACs()) ?? []
            wolAvailable = await service.isToolAvailable("etherwake")
        } else {
            clients = []
            error = nil
            blockedMACs = []
            wolAvailable = false
        }
    }

    /// Local bookkeeping after a successful block/unblock, so the UI updates
    /// without a full reload.
    func markBlocked(mac: String, blocked: Bool) {
        let key = mac.uppercased()
        if blocked {
            blockedMACs.insert(key)
        } else {
            blockedMACs.remove(key)
        }
    }

    // MARK: - Filtering

    /// Case-insensitive contains over hostname / IP / MAC / vendor / DNS name
    /// (mirrors the Flutter search filter).
    func filtered(query: String) -> [Client] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return clients }
        return clients.filter { client in
            if client.hostname.lowercased().contains(trimmed) { return true }
            if client.ipAddress.lowercased().contains(trimmed) { return true }
            if client.macAddress.lowercased().contains(trimmed) { return true }
            if let vendor = client.vendor, vendor.lowercased().contains(trimmed) { return true }
            if let dnsName = client.dnsName, dnsName.lowercased().contains(trimmed) { return true }
            return false
        }
    }

    // MARK: - Per-router gather

    /// Logs into one saved router, gathers its clients, and always tears the
    /// connection down. Failures return an empty list (aggregate mode skips
    /// unreachable routers silently).
    private nonisolated static func gatherFromRouter(_ router: Router) async -> [Client] {
        let address = (router.useHttps ? "https://" : "") + router.ipAddress
        guard let endpoint = try? RouterEndpoint.parse(address) else { return [] }
        let client = UbusClient(endpoint: endpoint)
        var result: [Client] = []
        do {
            _ = try await client.login(username: router.username, password: router.password)
            result = (try? await gather(service: RouterService(transport: client))) ?? []
        } catch {
            // Skip this router silently.
        }
        await client.invalidate()
        return result
    }

    /// DHCP leases + wireless association MACs from one router, merged into
    /// Client values. Throws only when neither source could be fetched.
    private nonisolated static func gather(service: RouterService) async throws -> [Client] {
        // DHCP leases: the payload usually wraps the list in "dhcp_leases",
        // but tolerate the response being the bare array.
        var leases: [JSONValue] = []
        var leaseError: Error?
        do {
            let json = try await service.dhcpLeases()
            leases = json["dhcp_leases"].arrayValue ?? json.arrayValue ?? []
        } catch {
            leaseError = error
        }

        // Wireless association MACs, per SSID device, fetched in parallel.
        var wirelessMACs = Set<String>()
        var wirelessAvailable = false
        do {
            let json = try await service.wirelessDevices()
            wirelessAvailable = true
            let networks = WirelessNetwork.fromWirelessDevices(json)
            let devices = Set(networks.map(\.device).filter { !$0.isEmpty })
            await withTaskGroup(of: [String].self) { group in
                for device in devices {
                    group.addTask {
                        (try? await service.associatedStations(device: device)) ?? []
                    }
                }
                for await macs in group {
                    for mac in macs { wirelessMACs.insert(mac.uppercased()) }
                }
            }
        } catch {
            // Tolerate: routers without wireless still report DHCP clients.
        }

        if let leaseError, !wirelessAvailable {
            throw leaseError
        }

        // Merge: leases first (upgrading to .wireless when the MAC is
        // associated), then association-only stations without a lease.
        var merged: [Client] = []
        var leaseMACs = Set<String>()
        for lease in leases {
            var client = Client.fromLease(lease)
            let mac = client.macAddress.uppercased()
            leaseMACs.insert(mac)
            if wirelessMACs.contains(mac) {
                client = client.with(connectionType: .wireless)
            }
            merged.append(client)
        }
        for mac in wirelessMACs.sorted() where !leaseMACs.contains(mac) {
            merged.append(Client.fromWirelessStation(mac: mac))
        }
        return merged
    }

    // MARK: - Dedupe + sort

    /// Deduplicates by uppercased MAC (preferring entries that carry a real
    /// hostname / IP), then sorts wireless → wired → unknown, hostname
    /// case-insensitive within each group with "Unknown" hosts last.
    private nonisolated static func dedupeAndSort(_ clients: [Client]) -> [Client] {
        var byMAC: [String: Client] = [:]
        for client in clients {
            let key = client.macAddress.uppercased()
            if let existing = byMAC[key] {
                byMAC[key] = richness(client) > richness(existing) ? client : existing
            } else {
                byMAC[key] = client
            }
        }

        return byMAC.values.sorted { a, b in
            let rankA = typeRank(a.connectionType)
            let rankB = typeRank(b.connectionType)
            if rankA != rankB { return rankA < rankB }

            let unknownA = a.hostname == "Unknown"
            let unknownB = b.hostname == "Unknown"
            if unknownA != unknownB { return unknownB }

            let comparison = a.hostname.localizedCaseInsensitiveCompare(b.hostname)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return a.macAddress.uppercased() < b.macAddress.uppercased()
        }
    }

    private nonisolated static func richness(_ client: Client) -> Int {
        var score = 0
        if client.hostname != "Unknown" { score += 2 }
        if client.ipAddress != "N/A" { score += 1 }
        if client.connectionType != .unknown { score += 1 }
        return score
    }

    private nonisolated static func typeRank(_ type: Client.ConnectionType) -> Int {
        switch type {
        case .wireless: return 0
        case .wired: return 1
        case .unknown: return 2
        }
    }
}
