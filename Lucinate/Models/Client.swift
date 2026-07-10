import Foundation

/// A network client (DHCP lease / wireless station), mirroring
/// `lib/models/client.dart`.
struct Client: Sendable, Identifiable, Equatable {
    enum ConnectionType: String, Sendable {
        case wired
        case wireless
        case unknown
    }

    /// Display-only liveness derived from assoclist membership and the
    /// kernel neighbor (ARP/NDP) tables. Never persisted.
    enum Presence: String, Sendable {
        /// Associated to Wi-Fi, or a fresh (REACHABLE/DELAY/PROBE) neighbor.
        case online
        /// STALE neighbor entry — likely a sleeping device, not a departed one.
        case idle
        /// No liveness signal at all (e.g. only a lingering DHCP lease).
        case offline
    }

    let ipAddress: String
    let macAddress: String
    let hostname: String
    let hostId: String?
    /// Remaining lease time in seconds (from the `expires` field).
    let leaseTime: Int?
    let vendor: String?
    let dnsName: String?
    let clientId: String?
    /// Active time in seconds.
    let activeTime: Int?
    /// Absolute expiration timestamp in epoch seconds.
    let expiresAt: Int?
    let connectionType: ConnectionType
    let ipv6Addresses: [String]
    let presence: Presence

    init(
        ipAddress: String = "N/A",
        macAddress: String,
        hostname: String = "Unknown",
        hostId: String? = nil,
        leaseTime: Int? = nil,
        vendor: String? = nil,
        dnsName: String? = nil,
        clientId: String? = nil,
        activeTime: Int? = nil,
        expiresAt: Int? = nil,
        connectionType: ConnectionType = .unknown,
        ipv6Addresses: [String] = [],
        presence: Presence = .offline
    ) {
        self.ipAddress = ipAddress
        self.macAddress = macAddress
        self.hostname = hostname
        self.hostId = hostId
        self.leaseTime = leaseTime
        self.vendor = vendor
        self.dnsName = dnsName
        self.clientId = clientId
        self.activeTime = activeTime
        self.expiresAt = expiresAt
        self.connectionType = connectionType
        self.ipv6Addresses = ipv6Addresses
        self.presence = presence
    }

    var id: String { macAddress.uppercased() }

    // MARK: - Formatting

    /// "Unlimited" when nil/0, "Expired" when negative, else "Xd Yh Zm".
    var formattedLeaseTime: String {
        guard let leaseTime, leaseTime != 0 else { return "Unlimited" }
        if leaseTime < 0 { return "Expired" }
        return Client.formatDuration(leaseTime)
    }

    var isLeaseExpired: Bool {
        guard let leaseTime else { return false }
        return leaseTime < 0
    }

    var formattedActiveTime: String {
        guard let activeTime else { return "N/A" }
        return Client.formatDuration(activeTime)
    }

    /// Formats a duration in seconds as "Xd Yh Zm" (mirrors Dart formatDuration).
    static func formatDuration(_ totalSeconds: Int) -> String {
        if totalSeconds <= 0 { return "0m" }
        var seconds = totalSeconds
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

    // MARK: - Factories

    /// Parses one entry of a luci-rpc `getDHCPLeases` response.
    static func fromLease(_ lease: JSONValue) -> Client {
        func string(_ keys: String...) -> String? {
            for key in keys {
                if let value = lease[key].coercedString, !value.isEmpty { return value }
            }
            return nil
        }
        func int(_ keys: String...) -> Int? {
            for key in keys {
                if let value = lease[key].intValue { return value }
            }
            return nil
        }

        // `expires` is the remaining lease time in seconds; fall back to
        // `leasetime` when absent.
        let expires = int("expires", "leasetime")
        let activeTime = int("activetime")

        var expiresAtTimestamp: Int?
        if let expires, expires > 0 {
            expiresAtTimestamp = Int(Date().timeIntervalSince1970) + expires
        }

        let ipv6 = Client.ipv6Addresses(from: lease)

        return Client(
            ipAddress: string("ipaddr", "ip") ?? "N/A",
            macAddress: string("macaddr", "mac") ?? "N/A",
            hostname: sanitizedHostname(string("hostname", "name")) ?? "Unknown",
            hostId: string("hostid", "duid"),
            leaseTime: expires,
            vendor: string("vendor"),
            dnsName: string("dnsname"),
            clientId: string("clientid"),
            activeTime: activeTime,
            expiresAt: expiresAtTimestamp,
            connectionType: determineConnectionType(lease),
            ipv6Addresses: ipv6
        )
    }

    /// dnsmasq stores "*" (and some builds "?") for leases without a
    /// hostname — treat those, and empty strings, as missing.
    static func sanitizedHostname(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "*" || trimmed == "?" { return nil }
        return trimmed
    }

    /// Defensive IPv6 extraction across the shapes seen in the wild:
    /// "ipv6addrs"/"ip6addrs" lists, and "ipv6addr"/"ip6addr" as a single
    /// string, a comma-separated string, or a list.
    static func ipv6Addresses(from json: JSONValue) -> [String] {
        var found: [String] = []
        for key in ["ipv6addrs", "ip6addrs"] {
            if let list = json[key].arrayValue {
                found.append(contentsOf: list.compactMap { $0.coercedString })
            }
        }
        for key in ["ipv6addr", "ip6addr"] {
            let value = json[key]
            if let single = value.stringValue {
                found.append(
                    contentsOf: single
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) })
            } else if let list = value.arrayValue {
                found.append(contentsOf: list.compactMap { $0.coercedString })
            }
        }
        var seen = Set<String>()
        return found.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Creates a Client from a wireless association MAC address (no DHCP data).
    /// Used as a fallback for AP-mode routers where DHCP is handled upstream.
    static func fromWirelessStation(
        mac: String,
        ipAddress: String? = nil,
        hostname: String? = nil
    ) -> Client {
        Client(
            ipAddress: ipAddress ?? "N/A",
            macAddress: mac,
            hostname: hostname ?? "Unknown",
            connectionType: .wireless
        )
    }

    /// Copy helper that fills ONLY missing fields (used by host-hint /
    /// DHCPv6 enrichment): "Unknown" hostname → replace, "N/A" IP → replace,
    /// append IPv6 addresses not already present. Everything else is kept.
    func enriched(hostname: String?, ipAddress: String?, ipv6: [String]) -> Client {
        var newHostname = self.hostname
        if newHostname == "Unknown", let candidate = Client.sanitizedHostname(hostname) {
            newHostname = candidate
        }
        var newIP = self.ipAddress
        if newIP == "N/A", let ipAddress, !ipAddress.isEmpty {
            newIP = ipAddress
        }
        var newIPv6 = ipv6Addresses
        for address in ipv6 where !address.isEmpty && !newIPv6.contains(address) {
            newIPv6.append(address)
        }
        return Client(
            ipAddress: newIP,
            macAddress: macAddress,
            hostname: newHostname,
            hostId: hostId,
            leaseTime: leaseTime,
            vendor: vendor,
            dnsName: dnsName,
            clientId: clientId,
            activeTime: activeTime,
            expiresAt: expiresAt,
            connectionType: connectionType,
            ipv6Addresses: newIPv6,
            presence: presence
        )
    }

    /// Copy helper: same client with a different connection type.
    func with(connectionType: ConnectionType) -> Client {
        Client(
            ipAddress: ipAddress,
            macAddress: macAddress,
            hostname: hostname,
            hostId: hostId,
            leaseTime: leaseTime,
            vendor: vendor,
            dnsName: dnsName,
            clientId: clientId,
            activeTime: activeTime,
            expiresAt: expiresAt,
            connectionType: connectionType,
            ipv6Addresses: ipv6Addresses,
            presence: presence
        )
    }

    /// Copy helper: same client with a different presence.
    func with(presence: Presence) -> Client {
        Client(
            ipAddress: ipAddress,
            macAddress: macAddress,
            hostname: hostname,
            hostId: hostId,
            leaseTime: leaseTime,
            vendor: vendor,
            dnsName: dnsName,
            clientId: clientId,
            activeTime: activeTime,
            expiresAt: expiresAt,
            connectionType: connectionType,
            ipv6Addresses: ipv6Addresses,
            presence: presence
        )
    }

    // MARK: - Connection type inference (mirrors Dart heuristics)

    static func determineConnectionType(_ lease: JSONValue) -> ConnectionType {
        // Wireless-specific fields first.
        if !lease["signal"].isNull || !lease["noise"].isNull {
            return .wireless
        }

        // Wired-specific fields.
        if !lease["port"].isNull {
            return .wired
        }
        if let ifname = lease["ifname"].coercedString, ifname.hasPrefix("eth") {
            return .wired
        }

        // Hostname keywords that commonly indicate wireless devices.
        let hostname = (lease["hostname"].coercedString ?? "").lowercased()
        let wirelessKeywords = ["android", "iphone", "ipad", "wireless", "wifi", "wl"]
        if wirelessKeywords.contains(where: { hostname.contains($0) }) {
            return .wireless
        }

        // MAC OUI heuristics (mirrors the Dart prefix lists).
        let mac = (lease["macaddr"].coercedString ?? "").lowercased()
        if !mac.isEmpty {
            let wirelessOUIs = [
                "00:1e:2a", "00:23:69", "00:26:5e", "00:26:5f", "00:26:ab",
                "00:26:b8", "00:26:f2", "00:1d:0f", "00:21:29", "00:22:3f",
                "00:22:5f", "00:23:08", "00:23:15",
                "a4:4c:c8", "a4:4c:c9", "a4:4c:ca", "a4:4c:cb", "a4:83:e7",
                "90:72:40", "f8:0f:f9", "f8:95:ea",
                "4c:57:ca",
                "a0:14:3d", "00:1a:11", "00:1d:60", "00:25:9e", "00:26:5a",
                "00:50:43",
                "34:ab:37",
            ]
            let oui = mac.count > 8 ? String(mac.prefix(8)) : ""
            if !oui.isEmpty, wirelessOUIs.contains(where: { oui.hasPrefix($0) }) {
                return .wireless
            }

            let wiredOUIs = [
                "00:1d:60", "00:25:9e", "00:26:5a", "00:50:43",
                "00:1a:4d", "00:1a:4e", "00:1a:4f",
                "00:1b:21", "00:1b:fc", "00:24:8c", "00:26:18",
                "00:26:5e", "00:26:5f", "00:26:ab", "00:26:b8", "00:26:f2",
            ]
            if !oui.isEmpty, wiredOUIs.contains(where: { oui.hasPrefix($0) }) {
                return .wired
            }
        }

        return .unknown
    }
}
