import Foundation

/// A logical network interface from `network.interface dump`, mirroring
/// `lib/models/interface.dart`.
struct NetworkInterface: Sendable, Identifiable, Equatable {
    let name: String
    let isUp: Bool
    /// The interface protocol (Dart calls this `proto`, e.g. "static",
    /// "dhcp", "wireguard"). Named `protocolName` because `protocol` is a
    /// Swift keyword.
    let protocolName: String
    /// Uptime in seconds.
    let uptime: Int
    let device: String
    let ipAddress: String?
    let netmask: String?
    /// nil when the route's nexthop is missing or "0.0.0.0".
    let gateway: String?
    let dnsServers: [String]
    let rxBytes: Int64
    let txBytes: Int64
    let ipv6Addresses: [String]

    init(
        name: String,
        isUp: Bool,
        protocolName: String,
        uptime: Int,
        device: String,
        ipAddress: String? = nil,
        netmask: String? = nil,
        gateway: String? = nil,
        dnsServers: [String] = [],
        rxBytes: Int64 = 0,
        txBytes: Int64 = 0,
        ipv6Addresses: [String] = []
    ) {
        self.name = name
        self.isUp = isUp
        self.protocolName = protocolName
        self.uptime = uptime
        self.device = device
        self.ipAddress = ipAddress
        self.netmask = netmask
        self.gateway = gateway
        self.dnsServers = dnsServers
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.ipv6Addresses = ipv6Addresses
    }

    var id: String { name }

    /// "Xd Yh Zm", or "N/A" when the interface is down (uptime <= 0).
    var formattedUptime: String {
        if uptime <= 0 { return "N/A" }
        var seconds = uptime
        let days = seconds / (24 * 3600)
        seconds %= 24 * 3600
        let hours = seconds / 3600
        seconds %= 3600
        let minutes = seconds / 60

        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 || parts.isEmpty { parts.append("\(minutes)m") }
        return parts.joined(separator: " ")
    }

    /// Parses one entry of `network.interface dump`'s `interface[]` array.
    static func fromDump(_ iface: JSONValue) -> NetworkInterface {
        // First ipv4-address entry, if any.
        let ipv4 = iface["ipv4-address"][0]
        let ipAddress = ipv4["address"].coercedString
        // The mask can arrive as an integer; keep it as a string.
        let netmask = ipv4["mask"].coercedString

        // Gateway: prefer the default route (target 0.0.0.0), fall back to the
        // first route (mirrors the Dart, which reads route[0]); ignore a
        // nexthop of "0.0.0.0" which is not a real gateway.
        var gateway: String?
        if let routes = iface["route"].arrayValue {
            let defaultRoute = routes.first { $0["target"].coercedString == "0.0.0.0" }
            let route = defaultRoute ?? routes.first
            if let nexthop = route?["nexthop"].coercedString, nexthop != "0.0.0.0",
                !nexthop.isEmpty
            {
                gateway = nexthop
            }
        }

        let dnsServers = (iface["dns-server"].arrayValue ?? [])
            .compactMap { $0.coercedString }
            .filter { !$0.isEmpty }

        let ipv6Addresses = (iface["ipv6-address"].arrayValue ?? [])
            .compactMap { $0["address"].coercedString }
            .filter { !$0.isEmpty }

        let stats = iface["stats"]
        let rxBytes = Int64(stats["rx_bytes"].doubleValue ?? 0)
        let txBytes = Int64(stats["tx_bytes"].doubleValue ?? 0)

        return NetworkInterface(
            name: iface["interface"].coercedString ?? "Unknown",
            isUp: iface["up"].boolValue ?? false,
            protocolName: iface["proto"].coercedString ?? "N/A",
            uptime: iface["uptime"].intValue ?? 0,
            device: iface["device"].coercedString
                ?? iface["l3_device"].coercedString
                ?? "N/A",
            ipAddress: ipAddress,
            netmask: netmask,
            gateway: gateway,
            dnsServers: dnsServers,
            rxBytes: rxBytes,
            txBytes: txBytes,
            ipv6Addresses: ipv6Addresses
        )
    }
}

/// A WireGuard peer as reported by `luci.wireguard getWgInstances`.
struct WireGuardPeer: Sendable, Identifiable, Equatable {
    let publicKey: String
    let endpoint: String?
    /// Epoch seconds of the latest handshake; nil/0 means never.
    let latestHandshake: Int?
    let allowedIPs: [String]
    /// Optional friendly peer name (some builds include it).
    let name: String?

    init(
        publicKey: String,
        endpoint: String? = nil,
        latestHandshake: Int? = nil,
        allowedIPs: [String] = [],
        name: String? = nil
    ) {
        self.publicKey = publicKey
        self.endpoint = endpoint
        self.latestHandshake = latestHandshake
        self.allowedIPs = allowedIPs
        self.name = name
    }

    var id: String { publicKey }

    /// "first8...last8" for long keys, else the key unchanged.
    var truncatedKey: String {
        guard publicKey.count > 16 else { return publicKey }
        return "\(publicKey.prefix(8))...\(publicKey.suffix(8))"
    }

    /// Relative handshake description ("Never", "3d ago", "4h ago",
    /// "12m ago", "30s ago"). Pure arithmetic; pass `now` for testability.
    func handshakeDescription(now: Int = Int(Date().timeIntervalSince1970)) -> String {
        guard let latestHandshake, latestHandshake > 0 else { return "Never" }
        let difference = now - latestHandshake
        if difference < 0 { return "Never" }
        let days = difference / 86400
        if days > 0 { return "\(days)d ago" }
        let hours = difference / 3600
        if hours > 0 { return "\(hours)h ago" }
        let minutes = difference / 60
        if minutes > 0 { return "\(minutes)m ago" }
        return "\(difference)s ago"
    }

    /// Parses the payload of `luci.wireguard getWgInstances`: an object keyed
    /// by WireGuard interface name, each value holding a `peers` collection
    /// (either an array of peer objects or an object keyed by public key).
    /// Returns peers keyed by interface name.
    static func parse(fromWgInstances json: JSONValue) -> [String: [WireGuardPeer]] {
        guard let instances = json.objectValue else { return [:] }
        var result: [String: [WireGuardPeer]] = [:]

        for (interfaceName, instance) in instances {
            var peers: [WireGuardPeer] = []

            if let peerList = instance["peers"].arrayValue {
                for peer in peerList {
                    if let parsed = parsePeer(peer, fallbackKey: nil) {
                        peers.append(parsed)
                    }
                }
            } else if let peerMap = instance["peers"].objectValue {
                for (key, peer) in peerMap {
                    if let parsed = parsePeer(peer, fallbackKey: key) {
                        peers.append(parsed)
                    }
                }
            }

            if !peers.isEmpty {
                // Stable ordering for UI (dictionaries are unordered).
                peers.sort { $0.publicKey < $1.publicKey }
                result[interfaceName] = peers
            }
        }
        return result
    }

    private static func parsePeer(_ peer: JSONValue, fallbackKey: String?) -> WireGuardPeer? {
        let publicKey = peer["public_key"].coercedString ?? fallbackKey
        guard let publicKey, !publicKey.isEmpty else { return nil }

        let endpointRaw = peer["endpoint"].coercedString
        let endpoint = (endpointRaw?.isEmpty == false && endpointRaw != "(none)")
            ? endpointRaw : nil

        let handshake = peer["last_handshake"].intValue
            ?? peer["latest_handshake"].intValue

        var allowedIPs: [String] = []
        if let list = peer["allowed_ips"].arrayValue {
            allowedIPs = list.compactMap { $0.coercedString }.filter { !$0.isEmpty }
        } else if let single = peer["allowed_ips"].stringValue {
            allowedIPs = single
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        let nameRaw = peer["name"].coercedString
        let name = (nameRaw?.isEmpty == false) ? nameRaw : nil

        return WireGuardPeer(
            publicKey: publicKey,
            endpoint: endpoint,
            latestHandshake: handshake,
            allowedIPs: allowedIPs,
            name: name
        )
    }
}
