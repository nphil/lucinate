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

    /// DHCP(v4+v6) leases + wireless association MACs from one router, merged
    /// into Client values and enriched with LuCI host hints. Throws only when
    /// neither primary source could be fetched.
    private nonisolated static func gather(service: RouterService) async throws -> [Client] {
        // MACs ever seen in an assoclist (persisted): lets sleeping Wi-Fi
        // devices that dropped out of the assoclist keep their Wi-Fi type
        // instead of falling back to "Unknown". Read once here, written once
        // at the end (UserDefaults is thread-safe; gather runs off-main).
        let defaults = UserDefaults.standard
        let storedWirelessMACs =
            (defaults.stringArray(forKey: Self.knownWirelessMACsKey) ?? [])
            .map { $0.uppercased() }

        // DHCP leases: the payload usually wraps the lists in "dhcp_leases" /
        // "dhcp6_leases", but tolerate the response being the bare array.
        var leases: [JSONValue] = []
        var leases6: [JSONValue] = []
        var leaseError: Error?
        do {
            let json = try await service.dhcpLeases()
            leases = json["dhcp_leases"].arrayValue ?? json.arrayValue ?? []
            leases6 = json["dhcp6_leases"].arrayValue ?? []
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

        // Kernel neighbor tables (ARP/NDP): liveness signal for wired and
        // non-associated clients. Must never fail the load.
        let neighborOutput = (try? await service.ipNeighbors()) ?? ""
        let neighborStates = Self.parseNeighborStates(neighborOutput)

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

        // Index by uppercased MAC for the enrichment passes below.
        var indexByMAC: [String: Int] = [:]
        for (index, client) in merged.enumerated() {
            indexByMAC[client.macAddress.uppercased()] = index
        }

        // DHCPv6 leases carrying a MAC: enrich the existing client's IPv6
        // addresses (and hostname when the v4 lease had none), or add a new
        // row when no client exists for that MAC yet.
        for lease6 in leases6 {
            let mac = (lease6["macaddr"].coercedString ?? lease6["mac"].coercedString ?? "")
                .uppercased()
            guard !mac.isEmpty else { continue }
            let ipv6 = Client.ipv6Addresses(from: lease6)
            if let index = indexByMAC[mac] {
                merged[index] = merged[index].enriched(
                    hostname: lease6["hostname"].coercedString,
                    ipAddress: nil,
                    ipv6: ipv6)
            } else {
                var client = Client.fromLease(lease6)
                if wirelessMACs.contains(mac) {
                    client = client.with(connectionType: .wireless)
                }
                merged.append(client)
                indexByMAC[mac] = merged.count - 1
            }
        }

        // Host hints (LuCI's DHCP-config + ARP/neighbor + mDNS aggregation):
        // fill in missing hostnames / IPs on EXISTING clients only — hints
        // include stale entries, so never create rows from them. A hints
        // failure must never fail the load.
        if let hints = try? await service.hostHints(), let entries = hints.objectValue {
            for (mac, hint) in entries {
                guard let index = indexByMAC[mac.uppercased()] else { continue }
                let ipv4 = firstString(in: hint["ipaddrs"]) ?? firstString(in: hint["ipv4"])
                let ipv6 = stringList(in: hint["ip6addrs"]) + stringList(in: hint["ipv6"])
                merged[index] = merged[index].enriched(
                    hostname: hint["name"].coercedString,
                    ipAddress: ipv4,
                    ipv6: ipv6)
            }
        }

        // Presence + connection-type memory pass (after all enrichment).
        let knownWirelessMACs = Set(storedWirelessMACs).union(wirelessMACs)
        for index in merged.indices {
            var client = merged[index]
            let mac = client.macAddress.uppercased()

            // A MAC ever seen associated is a Wi-Fi client, even while asleep.
            if client.connectionType == .unknown, knownWirelessMACs.contains(mac) {
                client = client.with(connectionType: .wireless)
            }

            let presence: Client.Presence
            if wirelessMACs.contains(mac) {
                presence = .online
            } else {
                switch neighborStates[mac] ?? "" {
                case "REACHABLE", "DELAY", "PROBE":
                    presence = .online
                case "STALE":
                    presence = .idle
                default:
                    presence = .offline
                }
            }

            // An awake device that isn't associated to Wi-Fi is on a cable.
            if client.connectionType == .unknown, presence == .online {
                client = client.with(connectionType: .wired)
            }

            merged[index] = client.with(presence: presence)
        }

        // Persist the wireless-MAC memory (only when this gather saw
        // something new), most-recently-seen first, capped.
        if !wirelessMACs.isEmpty, !wirelessMACs.isSubset(of: Set(storedWirelessMACs)) {
            var ordered = wirelessMACs.sorted()
            ordered.append(contentsOf: storedWirelessMACs.filter { !wirelessMACs.contains($0) })
            defaults.set(
                Array(ordered.prefix(Self.knownWirelessMACsCap)),
                forKey: Self.knownWirelessMACsKey)
        }

        return merged
    }

    // MARK: - Neighbor (ARP/NDP) parsing

    private nonisolated static let knownWirelessMACsKey = "known_wireless_macs"
    private nonisolated static let knownWirelessMACsCap = 512

    /// Parses `ip -4/-6 neigh show` lines such as
    /// `192.168.1.50 dev br-lan lladdr aa:bb:cc:dd:ee:ff REACHABLE` into
    /// [uppercased MAC: state]. The state is the last whitespace token; lines
    /// without an lladdr, or in FAILED/INCOMPLETE state, carry no liveness.
    /// When a MAC appears more than once (v4 + v6), the most-alive state wins.
    private nonisolated static func parseNeighborStates(_ output: String) -> [String: String] {
        var states: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard tokens.count >= 2 else { continue }
            guard let lladdrIndex = tokens.firstIndex(of: "lladdr"),
                lladdrIndex + 1 < tokens.count
            else { continue }
            let mac = tokens[lladdrIndex + 1].uppercased()
            let state = tokens[tokens.count - 1]
            if state == "FAILED" || state == "INCOMPLETE" { continue }
            if let existing = states[mac], aliveRank(existing) >= aliveRank(state) { continue }
            states[mac] = state
        }
        return states
    }

    /// REACHABLE > DELAY/PROBE > STALE > anything else.
    private nonisolated static func aliveRank(_ state: String) -> Int {
        switch state {
        case "REACHABLE": return 3
        case "DELAY", "PROBE": return 2
        case "STALE": return 1
        default: return 0
        }
    }

    // MARK: - Defensive hint readers (values may be a string or a list)

    private nonisolated static func firstString(in value: JSONValue) -> String? {
        if let single = value.coercedString, !single.isEmpty { return single }
        return value.arrayValue?
            .compactMap { $0.coercedString }
            .first { !$0.isEmpty }
    }

    private nonisolated static func stringList(in value: JSONValue) -> [String] {
        if let list = value.arrayValue {
            return list.compactMap { $0.coercedString }.filter { !$0.isEmpty }
        }
        if let single = value.coercedString, !single.isEmpty { return [single] }
        return []
    }

    // MARK: - Dedupe + sort

    /// Deduplicates by uppercased MAC (preferring entries that carry a real
    /// hostname / IP), then sorts online → idle → offline, then wireless →
    /// wired → unknown, hostname case-insensitive within each group with
    /// "Unknown" hosts last.
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
            let presenceA = presenceRank(a.presence)
            let presenceB = presenceRank(b.presence)
            if presenceA != presenceB { return presenceA < presenceB }

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

    private nonisolated static func presenceRank(_ presence: Client.Presence) -> Int {
        switch presence {
        case .online: return 0
        case .idle: return 1
        case .offline: return 2
        }
    }
}

// MARK: - Live per-client speeds (wireless assoclist polling)

/// Instantaneous per-station throughput, derived from cumulative byte
/// counters between two polls. MAC keys are uppercased.
struct ClientRate: Equatable {
    let rxBytesPerSecond: Double
    let txBytesPerSecond: Double
}

/// Polls `iwinfo assoclist` for the ACTIVE router's wireless ifnames every
/// 3 seconds and publishes per-MAC rates. Kept separate from
/// ClientsController so the 3s tick only re-renders the tiny speed badges
/// that read `rates` — never the client rows or list.
@MainActor
@Observable
final class ClientSpeedsController {
    private(set) var rates: [String: ClientRate] = [:]

    private struct Sample {
        let rxBytes: Double
        let txBytes: Double
        let timestamp: TimeInterval
    }

    @ObservationIgnored private var samples: [String: Sample] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// Starts polling the given wireless ifnames. Replaces any previous run.
    func start(service: RouterService, devices: [String]) {
        stop()
        guard !devices.isEmpty else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce(service: service, devices: devices)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        samples = [:]
        rates = [:]
    }

    private func pollOnce(service: RouterService, devices: [String]) async {
        // Parallel + tolerant: a failing device just contributes no stations.
        let stations = await withTaskGroup(of: [JSONValue].self) { group in
            for device in devices {
                group.addTask {
                    (try? await service.stationList(device: device))?["results"]
                        .arrayValue ?? []
                }
            }
            var all: [JSONValue] = []
            for await part in group { all.append(contentsOf: part) }
            return all
        }
        guard !Task.isCancelled else { return }

        let now = Date().timeIntervalSince1970
        var newRates: [String: ClientRate] = [:]
        for entry in stations {
            guard let mac = entry["mac"].stringValue?.uppercased(), !mac.isEmpty else {
                continue
            }
            // If this iwinfo build exposes no byte counters at all, publish
            // nothing for the station (graceful degradation — no badge).
            let rx = ClientSpeedsController.byteCounter(entry, direction: "rx")
            let tx = ClientSpeedsController.byteCounter(entry, direction: "tx")
            guard rx != nil || tx != nil else { continue }
            let rxBytes = rx ?? 0
            let txBytes = tx ?? 0

            if let previous = samples[mac] {
                let elapsed = now - previous.timestamp
                if elapsed >= 0.5 {
                    newRates[mac] = ClientRate(
                        rxBytesPerSecond: max(0, (rxBytes - previous.rxBytes) / elapsed),
                        txBytesPerSecond: max(0, (txBytes - previous.txBytes) / elapsed))
                    samples[mac] = Sample(rxBytes: rxBytes, txBytes: txBytes, timestamp: now)
                } else if let held = rates[mac] {
                    // Too soon for a meaningful delta: keep the last rate.
                    newRates[mac] = held
                }
            } else {
                samples[mac] = Sample(rxBytes: rxBytes, txBytes: txBytes, timestamp: now)
            }
        }
        rates = newRates
    }

    /// Cumulative byte counter, tried across the assoclist shapes seen in the
    /// wild: entry["rx"]["bytes"], entry["rx_bytes"], entry["bytes"]["rx"].
    private nonisolated static func byteCounter(
        _ entry: JSONValue, direction: String
    ) -> Double? {
        if let value = entry[direction]["bytes"].doubleValue { return value }
        if let value = entry["\(direction)_bytes"].doubleValue { return value }
        if let value = entry["bytes"][direction].doubleValue { return value }
        return nil
    }
}
