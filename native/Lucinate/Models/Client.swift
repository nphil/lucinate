import Foundation

/// A network client (DHCP lease / wireless station), mirroring
/// `lib/models/client.dart`.
struct Client: Sendable, Identifiable, Equatable {
    enum ConnectionType: String, Sendable {
        case wired
        case wireless
        case unknown
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
        ipv6Addresses: [String] = []
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

        var ipv6Addresses: [String] = []
        if let list = lease["ipv6addrs"].arrayValue {
            ipv6Addresses = list.compactMap { $0.coercedString }.filter { !$0.isEmpty }
        } else if !lease["ipv6addr"].isNull {
            // Some APIs use a single string, a comma-separated string, or a list.
            if let single = lease["ipv6addr"].stringValue {
                ipv6Addresses = single
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            } else if let list = lease["ipv6addr"].arrayValue {
                ipv6Addresses = list.compactMap { $0.coercedString }.filter { !$0.isEmpty }
            }
        }

        return Client(
            ipAddress: string("ipaddr", "ip") ?? "N/A",
            macAddress: string("macaddr", "mac") ?? "N/A",
            hostname: string("hostname", "name") ?? "Unknown",
            hostId: string("hostid", "duid"),
            leaseTime: expires,
            vendor: string("vendor"),
            dnsName: string("dnsname"),
            clientId: string("clientid"),
            activeTime: activeTime,
            expiresAt: expiresAtTimestamp,
            connectionType: determineConnectionType(lease),
            ipv6Addresses: ipv6Addresses
        )
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
            ipv6Addresses: ipv6Addresses
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
