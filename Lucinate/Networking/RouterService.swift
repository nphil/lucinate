import Foundation

/// Typed facade over the ubus transport. Feature controllers call these
/// instead of hand-rolling RPC envelopes. Composed mutations follow the
/// OpenWrt pattern: uci set/add/delete → uci commit → reload/restart.
struct RouterService: Sendable {
    let transport: any UbusCalling

    init(transport: any UbusCalling) {
        self.transport = transport
    }

    // MARK: - system

    func board() async throws -> JSONValue {
        try await transport.call("system", "board", .object([:]))
    }

    func systemInfo() async throws -> JSONValue {
        try await transport.call("system", "info", .object([:]))
    }

    func reboot() async throws {
        _ = try await transport.call("system", "reboot", .object([:]))
    }

    func systemExec(_ command: String) async throws -> JSONValue {
        try await transport.call("system", "exec", .object(["command": .string(command)]))
    }

    // MARK: - luci-rpc

    func networkDevices() async throws -> JSONValue {
        try await transport.call("luci-rpc", "getNetworkDevices", .object([:]))
    }

    func wirelessDevices() async throws -> JSONValue {
        try await transport.call("luci-rpc", "getWirelessDevices", .object([:]))
    }

    func dhcpLeases() async throws -> JSONValue {
        try await transport.call("luci-rpc", "getDHCPLeases", .object([:]))
    }

    /// LuCI's aggregated hostname/IP hints (DHCP config + ARP/neighbor tables
    /// + mDNS), keyed by MAC. Used to name clients whose lease has no
    /// hostname (private Wi-Fi addresses, no DHCP option 12).
    func hostHints() async throws -> JSONValue {
        try await transport.call("luci-rpc", "getHostHints", .object([:]))
    }

    // MARK: - network.interface

    func interfaceDump() async throws -> JSONValue {
        try await transport.call("network.interface", "dump", .object([:]))
    }

    // MARK: - uci

    /// Returns the `values` object of `uci get {config}` keyed by section name.
    /// Each section carries ".type" and ".name" metadata keys.
    func uciGet(config: String) async throws -> JSONValue {
        let result = try await transport.call("uci", "get", .object(["config": .string(config)]))
        return result["values"]
    }

    func uciSet(config: String, section: String, values: [String: String]) async throws {
        var jsonValues: [String: JSONValue] = [:]
        for (key, value) in values { jsonValues[key] = .string(value) }
        _ = try await transport.call(
            "uci", "set",
            .object([
                "config": .string(config),
                "section": .string(section),
                "values": .object(jsonValues),
            ]))
    }

    func uciAdd(config: String, type: String, name: String? = nil, values: [String: String])
        async throws
    {
        var jsonValues: [String: JSONValue] = [:]
        for (key, value) in values { jsonValues[key] = .string(value) }
        var params: [String: JSONValue] = [
            "config": .string(config),
            "type": .string(type),
            "values": .object(jsonValues),
        ]
        if let name { params["name"] = .string(name) }
        _ = try await transport.call("uci", "add", .object(params))
    }

    func uciDelete(config: String, section: String) async throws {
        _ = try await transport.call(
            "uci", "delete",
            .object(["config": .string(config), "section": .string(section)]))
    }

    func uciCommit(config: String) async throws {
        _ = try await transport.call("uci", "commit", .object(["config": .string(config)]))
    }

    // MARK: - iwinfo

    /// MAC addresses of stations associated to a wireless ifname.
    func associatedStations(device: String) async throws -> [String] {
        let result = try await transport.call(
            "iwinfo", "assoclist", .object(["device": .string(device)]))
        var macs: [String] = []
        for entry in result["results"].arrayValue ?? [] {
            if let mac = entry["mac"].stringValue { macs.append(mac.uppercased()) }
        }
        return macs
    }

    /// Raw assoclist payload ({"results": [...]}) including per-station
    /// counters, for live per-client rate estimation.
    func stationList(device: String) async throws -> JSONValue {
        try await transport.call("iwinfo", "assoclist", .object(["device": .string(device)]))
    }

    func wifiScan(radio: String) async throws -> JSONValue {
        try await transport.call("iwinfo", "scan", .object(["device": .string(radio)]))
    }

    // MARK: - file

    func fileRead(path: String) async throws -> String {
        let result = try await transport.call("file", "read", .object(["path": .string(path)]))
        return result["data"].stringValue ?? ""
    }

    func fileExec(command: String, params: [String] = []) async throws -> JSONValue {
        try await transport.call(
            "file", "exec",
            .object([
                "command": .string(command),
                "params": .array(params.map { .string($0) }),
            ]))
    }

    // MARK: - wireguard (optional package)

    func wireGuardInstances() async throws -> JSONValue {
        try await transport.call("luci.wireguard", "getWgInstances", .object([:]))
    }

    // MARK: - tailscale (optional rpcd plugin)

    func tailscaleStatus() async throws -> JSONValue {
        try await transport.call("tailscale", "get_status", .object([:]))
    }

    func tailscaleSettings() async throws -> JSONValue {
        try await transport.call("tailscale", "get_settings", .object([:]))
    }

    /// `formData` must contain the FULL settings form ('1'/'0' strings for
    /// every flag) — the rpcd plugin clears anything unspecified.
    func tailscaleApply(formData: [String: JSONValue]) async throws -> JSONValue {
        try await transport.call(
            "tailscale", "set_settings", .object(["form_data": .object(formData)]))
    }

    // MARK: - composed operations

    func wifiReload() async throws {
        _ = try await fileExec(command: "/sbin/wifi", params: ["reload"])
    }

    func travelmateRestart() async throws {
        _ = try await fileExec(command: "/etc/init.d/travelmate", params: ["restart"])
    }

    /// Toggle a wifi-iface or wifi-device section on/off, then reload wifi.
    func setWirelessSectionDisabled(section: String, disabled: Bool) async throws {
        try await uciSet(
            config: "wireless", section: section, values: ["disabled": disabled ? "1" : "0"])
        try await uciCommit(config: "wireless")
        try await systemExec("wifi reload")
    }

    func setTravelmateEnabled(_ enabled: Bool) async throws {
        try await uciSet(
            config: "travelmate", section: "global",
            values: ["trm_enabled": enabled ? "1" : "0"])
        try await uciCommit(config: "travelmate")
        try await travelmateRestart()
    }

    /// Creates the `wireless.trm_uplinkN` STA iface + matching travelmate
    /// uplink, commits both, restarts travelmate.
    func addTravelmateUplink(
        ssid: String, password: String, device: String, encryption: String
    ) async throws {
        let wireless = try await uciGet(config: "wireless")
        var maxIndex = 0
        for name in (wireless.objectValue ?? [:]).keys {
            if name.hasPrefix("trm_uplink"), let n = Int(name.dropFirst("trm_uplink".count)) {
                maxIndex = max(maxIndex, n)
            }
        }
        let section = "trm_uplink\(maxIndex + 1)"

        var ifaceValues: [String: String] = [
            "device": device,
            "mode": "sta",
            "network": "travel_wan",
            "ssid": ssid,
            "encryption": encryption,
            "disabled": "0",
        ]
        if encryption != "none" { ifaceValues["key"] = password }

        try await uciAdd(config: "wireless", type: "wifi-iface", name: section, values: ifaceValues)
        try await uciAdd(
            config: "travelmate", type: "uplink",
            values: ["enabled": "1", "device": device, "ssid": ssid])
        try await uciCommit(config: "wireless")
        try await uciCommit(config: "travelmate")
        try await travelmateRestart()
    }

    /// Removes the STA iface matching (ssid, device) and the travelmate uplink
    /// section, commits both, restarts travelmate.
    func removeTravelmateUplink(ssid: String, device: String, uplinkSection: String) async throws {
        let wireless = try await uciGet(config: "wireless")
        var ifaceSection: String?
        for (name, section) in wireless.objectValue ?? [:] {
            guard section[".type"].stringValue == "wifi-iface",
                section["mode"].stringValue == "sta",
                section["ssid"].stringValue == ssid,
                section["device"].stringValue == device
            else { continue }
            ifaceSection = name
        }
        if let ifaceSection {
            try await uciDelete(config: "wireless", section: ifaceSection)
            try await uciCommit(config: "wireless")
        }
        try await uciDelete(config: "travelmate", section: uplinkSection)
        try await uciCommit(config: "travelmate")
        try await travelmateRestart()
    }

    /// Sets a radio's channel ("auto" or a number), commits, reloads wifi.
    func setRadioChannel(radio: String, channel: String) async throws {
        try await uciSet(config: "wireless", section: radio, values: ["channel": channel])
        try await uciCommit(config: "wireless")
        try await wifiReload()
    }

    // MARK: - Tier A: Wi-Fi AP editing

    /// Applies option changes to any wireless section (wifi-iface or
    /// wifi-device), commits, and reloads wifi.
    func updateWireless(section: String, values: [String: String]) async throws {
        try await uciSet(config: "wireless", section: section, values: values)
        try await uciCommit(config: "wireless")
        try await wifiReload()
    }

    // MARK: - Tier A: DHCP static leases

    /// `uci get dhcp` values filtered to `host` sections (section name → options).
    func staticLeases() async throws -> [(section: String, values: JSONValue)] {
        let dhcp = try await uciGet(config: "dhcp")
        var hosts: [(String, JSONValue)] = []
        for (name, section) in dhcp.objectValue ?? [:] {
            if section[".type"].stringValue == "host" {
                hosts.append((name, section))
            }
        }
        hosts.sort { $0.0 < $1.0 }
        return hosts
    }

    private func restartDnsmasq() async throws {
        _ = try await fileExec(command: "/etc/init.d/dnsmasq", params: ["restart"])
    }

    func addStaticLease(mac: String, ip: String, name: String?) async throws {
        var values = ["mac": mac, "ip": ip]
        if let name, !name.isEmpty { values["name"] = name }
        try await uciAdd(config: "dhcp", type: "host", values: values)
        try await uciCommit(config: "dhcp")
        try await restartDnsmasq()
    }

    func updateStaticLease(section: String, mac: String, ip: String, name: String?) async throws {
        var values = ["mac": mac, "ip": ip]
        if let name, !name.isEmpty { values["name"] = name }
        try await uciSet(config: "dhcp", section: section, values: values)
        try await uciCommit(config: "dhcp")
        try await restartDnsmasq()
    }

    func deleteStaticLease(section: String) async throws {
        try await uciDelete(config: "dhcp", section: section)
        try await uciCommit(config: "dhcp")
        try await restartDnsmasq()
    }

    // MARK: - Tier A: client actions (WoL + firewall block)

    /// True when a binary is present on the router (`which` exits 0 and
    /// prints a path).
    func isToolAvailable(_ tool: String) async -> Bool {
        guard let result = try? await fileExec(command: "/bin/sh", params: ["-c", "which \(tool)"])
        else { return false }
        let stdout = result["stdout"].stringValue ?? ""
        let code = result["code"].intValue ?? 1
        return code == 0 && !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func wakeOnLan(mac: String) async throws {
        _ = try await systemExec("etherwake -b \(mac)")
    }

    private static let blockRulePrefix = "lucinate_block_"

    /// MACs currently blocked by rules this app created (name-prefixed).
    func blockedClientMACs() async throws -> Set<String> {
        let firewall = try await uciGet(config: "firewall")
        var macs: Set<String> = []
        for (_, section) in firewall.objectValue ?? [:] {
            guard section[".type"].stringValue == "rule",
                (section["name"].stringValue ?? "").hasPrefix(Self.blockRulePrefix),
                let mac = section["src_mac"].stringValue
            else { continue }
            macs.insert(mac.uppercased())
        }
        return macs
    }

    private func reloadFirewall() async throws {
        _ = try await fileExec(command: "/etc/init.d/firewall", params: ["reload"])
    }

    /// Drops all forwarded traffic from a MAC (internet block).
    func blockClient(mac: String) async throws {
        let sanitized = mac.uppercased()
        try await uciAdd(
            config: "firewall", type: "rule",
            values: [
                "name": Self.blockRulePrefix + sanitized.replacingOccurrences(of: ":", with: ""),
                "src": "lan",
                "dest": "wan",
                "src_mac": sanitized,
                "proto": "all",
                "target": "REJECT",
                "enabled": "1",
            ])
        try await uciCommit(config: "firewall")
        try await reloadFirewall()
    }

    func unblockClient(mac: String) async throws {
        let firewall = try await uciGet(config: "firewall")
        let target = mac.uppercased()
        var sections: [String] = []
        for (name, section) in firewall.objectValue ?? [:] {
            guard section[".type"].stringValue == "rule",
                (section["name"].stringValue ?? "").hasPrefix(Self.blockRulePrefix),
                section["src_mac"].stringValue?.uppercased() == target
            else { continue }
            sections.append(name)
        }
        guard !sections.isEmpty else { return }
        for section in sections {
            try await uciDelete(config: "firewall", section: section)
        }
        try await uciCommit(config: "firewall")
        try await reloadFirewall()
    }
}
