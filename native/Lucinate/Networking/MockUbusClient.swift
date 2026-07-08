import Foundation

/// Canned ubus transport for App Review ("reviewer mode"), ported from the
/// Flutter `lib/services/mock_api_service.dart` + `assets/mock/*.json`.
///
/// Semantics match the real transport: `call` returns ONLY the data part of
/// the ubus `[status, data]` result pair (already unwrapped), and unknown
/// endpoints throw `UbusError.ubusStatus(4, "not found")` so optional-module
/// probing degrades gracefully.
///
/// Mutable state (traffic counters, uptime, uci configs, tailscale settings)
/// lives on the actor so throughput charts show life and toggles appear to
/// work across calls.
actor MockUbusClient: UbusCalling {

    // MARK: - Mutable state

    private struct TrafficCounter {
        var rxBytes: Int
        var txBytes: Int
        var rxPackets: Int
        var txPackets: Int

        mutating func advance(rx rxRange: ClosedRange<Int>, tx txRange: ClosedRange<Int>) {
            let rx = Int.random(in: rxRange)
            let tx = Int.random(in: txRange)
            rxBytes += rx
            txBytes += tx
            rxPackets += rx / 1500 + Int.random(in: 0...50)
            txPackets += tx / 1500 + Int.random(in: 0...20)
        }
    }

    /// Base uptime (seconds) at `bootReference`; mirrors the asset's 4 days.
    private var uptimeBase = 345_600
    private var bootReference = Date()

    /// Per-device byte/packet counters seeded from `network_devices.json`.
    private var traffic: [String: TrafficCounter] = [
        "eth0": TrafficCounter(
            rxBytes: 5_234_567_890, txBytes: 2_987_654_321,
            rxPackets: 4_234_567, txPackets: 2_987_654),
        "br-lan": TrafficCounter(
            rxBytes: 8_345_678_901, txBytes: 6_876_543_210,
            rxPackets: 7_234_567, txPackets: 5_876_543),
        "wlan0": TrafficCounter(
            rxBytes: 1_234_567_890, txBytes: 987_654_321,
            rxPackets: 1_234_567, txPackets: 987_654),
        "wlan1": TrafficCounter(
            rxBytes: 2_345_678_901, txBytes: 1_876_543_210,
            rxPackets: 2_234_567, txPackets: 1_876_543),
    ]

    /// In-memory uci store: config -> section name -> option -> value.
    /// uci set/add/delete mutate it so reviewer-mode edits appear to stick.
    private var uciConfigs: [String: [String: [String: JSONValue]]] = MockUbusClient.initialUciConfigs()
    private var uciAnonymousCounter = 0x06_00_00

    /// Persisted tailscale settings; set_settings merges form_data into this.
    private var tailscaleSettings: [String: JSONValue] = [
        "accept_routes": .string("1"),
        "advertise_exit_node": .string("0"),
        "exit_node": .string(""),
        "exit_node_allow_lan_access": .string("0"),
        "shields_up": .string("0"),
        "ssh": .string("0"),
        "runwebclient": .string("0"),
        "nosnat": .string("0"),
        "disable_magic_dns": .string("0"),
        "fw_mode": .string("nftables"),
        "advertise_routes": .array([.string("192.168.1.0/24")]),
    ]

    init() {}

    // MARK: - UbusCalling

    func call(_ object: String, _ procedure: String, _ params: JSONValue) async throws -> JSONValue {
        // Feel like a network.
        try? await Task.sleep(nanoseconds: 150_000_000)

        switch "\(object).\(procedure)" {
        case "system.board":
            return Self.board
        case "system.info":
            return systemInfo()
        case "system.reboot":
            // "Reboot": restart the uptime clock.
            uptimeBase = 45
            bootReference = Date()
            return .object([:])
        case "system.exec":
            return .object(["stdout": .string(""), "stderr": .string(""), "code": .number(0)])

        case "luci-rpc.getNetworkDevices":
            return networkDevices()
        case "luci-rpc.getWirelessDevices":
            return Self.wirelessDevices
        case "luci-rpc.getDHCPLeases":
            return dhcpLeases()

        case "network.interface.dump":
            return Self.interfaceDump

        case "iwinfo.assoclist":
            return assoclist(device: params["device"].stringValue ?? "")
        case "iwinfo.scan":
            return Self.scanResults(device: params["device"].stringValue ?? "")

        case "uci.get":
            return uciGet(params)
        case "uci.set":
            uciSet(params)
            return .object([:])
        case "uci.add":
            return uciAdd(params)
        case "uci.delete":
            uciDelete(params)
            return .object([:])
        case "uci.commit":
            return .object([:])

        case "file.read":
            return fileRead(path: params["path"].stringValue ?? "")
        case "file.exec":
            return .object(["stdout": .string(""), "stderr": .string(""), "code": .number(0)])

        case "luci.wireguard.getWgInstances":
            return Self.wireGuardInstances(now: Int(Date().timeIntervalSince1970))

        case "tailscale.get_status":
            return tailscaleStatus()
        case "tailscale.get_settings":
            return .object(tailscaleSettings)
        case "tailscale.set_settings":
            if let formData = params["form_data"].objectValue {
                for (key, value) in formData {
                    tailscaleSettings[key] = value
                }
            }
            return .object([:])

        default:
            throw UbusError.ubusStatus(4, "not found")
        }
    }

    // MARK: - system

    private func systemInfo() -> JSONValue {
        let now = Int(Date().timeIntervalSince1970)
        let uptime = uptimeBase + Int(Date().timeIntervalSince(bootReference))
        let free = 268_435_456 - Int.random(in: 0...20_971_520)
        return .object([
            "uptime": .number(Double(uptime)),
            "localtime": .number(Double(now)),
            "load": .array([
                .number(Double(Int.random(in: 1500...2500))),
                .number(Double(Int.random(in: 1200...2200))),
                .number(Double(Int.random(in: 900...1500))),
            ]),
            "memory": .object([
                "total": .number(536_870_912),
                "free": .number(Double(free)),
                "shared": .number(Double(2_097_152 + Int.random(in: 0...524_288))),
                "buffered": .number(Double(20_971_520 + Int.random(in: 0...2_097_152))),
                "cached": .number(Double(41_943_040 + Int.random(in: 0...5_242_880))),
                "available": .number(Double(free + 41_943_040 + Int.random(in: 0...10_485_760))),
            ]),
            "swap": .object(["total": .number(0), "free": .number(0)]),
        ])
    }

    // MARK: - luci-rpc.getNetworkDevices (increasing counters)

    private func networkDevices() -> JSONValue {
        // WAN sees the most traffic, LAN aggregates, radios split the rest.
        traffic["eth0"]?.advance(rx: 80_000...900_000, tx: 15_000...200_000)
        traffic["br-lan"]?.advance(rx: 30_000...260_000, tx: 25_000...220_000)
        traffic["wlan0"]?.advance(rx: 10_000...120_000, tx: 8_000...90_000)
        traffic["wlan1"]?.advance(rx: 20_000...220_000, tx: 15_000...160_000)

        return .object([
            "eth0": deviceEntry(
                name: "eth0", type: "Network device", mac: "e4:95:6e:40:00:01"),
            "br-lan": deviceEntry(
                name: "br-lan", type: "Bridge", mac: "e4:95:6e:40:00:02",
                bridgeMembers: ["eth1", "wlan0", "wlan1"]),
            "wlan0": deviceEntry(
                name: "wlan0", type: "Wireless", mac: "e4:95:6e:40:00:03"),
            "wlan1": deviceEntry(
                name: "wlan1", type: "Wireless", mac: "e4:95:6e:40:00:04"),
        ])
    }

    private func deviceEntry(
        name: String, type: String, mac: String, bridgeMembers: [String]? = nil
    ) -> JSONValue {
        let counter = traffic[name]
            ?? TrafficCounter(rxBytes: 0, txBytes: 0, rxPackets: 0, txPackets: 0)
        var entry: [String: JSONValue] = [
            "device": .string(name),
            "type": .string(type),
            "up": .bool(true),
            "carrier": .bool(true),
            "mac": .string(mac),
            "mtu": .number(1500),
            "stats": .object([
                "rx_bytes": .number(Double(counter.rxBytes)),
                "tx_bytes": .number(Double(counter.txBytes)),
                "rx_packets": .number(Double(counter.rxPackets)),
                "tx_packets": .number(Double(counter.txPackets)),
                "rx_dropped": .number(Double(Int.random(in: 0...2))),
                "tx_dropped": .number(Double(Int.random(in: 0...1))),
                "rx_errors": .number(0),
                "tx_errors": .number(0),
            ]),
        ]
        if let bridgeMembers {
            entry["bridge_members"] = .array(bridgeMembers.map { .string($0) })
        }
        return .object(entry)
    }

    // MARK: - DHCP leases / associated stations (shared client table)

    /// (hostname, mac, ipv4, wireless ifname or nil for wired) — MACs match
    /// `assets/mock/dhcp_leases.json` and `associated_stations.json`.
    private static let clients: [(host: String, mac: String, ip: String, wifi: String?)] = [
        ("iPhone-John", "aa:bb:cc:11:22:33", "192.168.1.100", "wlan0"),
        ("MacBook-Pro", "aa:bb:cc:44:55:66", "192.168.1.101", "wlan0"),
        ("Smart-TV-Living-Room", "aa:bb:cc:77:88:99", "192.168.1.102", "wlan0"),
        ("Gaming-PC", "aa:bb:cc:aa:bb:cc", "192.168.1.103", "wlan1"),
        ("Nest-Thermostat", "aa:bb:cc:dd:ee:ff", "192.168.1.104", "wlan1"),
        ("iPad-Sarah", "aa:bb:cc:12:34:56", "192.168.1.105", "wlan0"),
        ("Amazon-Echo", "aa:bb:cc:65:43:21", "192.168.1.106", "wlan1"),
        ("Printer-HP-Office", "aa:bb:cc:98:76:54", "192.168.1.107", "wlan0"),
        ("Samsung-Galaxy-S23", "bb:cc:dd:11:22:33", "192.168.1.108", "wlan0"),
        ("Dell-Laptop-Work", "bb:cc:dd:44:55:66", "192.168.1.109", "wlan1"),
        ("Ring-Doorbell", "bb:cc:dd:77:88:99", "192.168.1.110", "wlan0"),
        ("Nintendo-Switch", "bb:cc:dd:aa:bb:cc", "192.168.1.111", "wlan1"),
        ("Philips-Hue-Bridge", "bb:cc:dd:dd:ee:ff", "192.168.1.112", "wlan1"),
        ("iPad-Kids", "bb:cc:dd:12:34:56", "192.168.1.113", "wlan0"),
        ("Google-Home-Kitchen", "bb:cc:dd:65:43:21", "192.168.1.114", "wlan0"),
        ("Canon-Camera", "bb:cc:dd:98:76:54", "192.168.1.115", "wlan1"),
        ("Tesla-Model-3", "cc:dd:ee:11:22:33", "192.168.1.116", "wlan1"),
        ("Roku-Ultra", "cc:dd:ee:44:55:66", "192.168.1.117", "wlan0"),
        ("Sonos-Speaker", "cc:dd:ee:77:88:99", "192.168.1.118", "wlan1"),
        ("Security-Camera-Front", "cc:dd:ee:aa:bb:cc", "192.168.1.119", "wlan1"),
        ("Raspberry-Pi-Server", "cc:dd:ee:dd:ee:ff", "192.168.1.120", nil),
        ("Apple-Watch", "cc:dd:ee:12:34:56", "192.168.1.121", "wlan1"),
        ("Chromecast-Bedroom", "cc:dd:ee:65:43:21", "192.168.1.122", "wlan0"),
        ("Baby-Monitor", "cc:dd:ee:98:76:54", "192.168.1.123", "wlan0"),
    ]

    private func dhcpLeases() -> JSONValue {
        var leases: [JSONValue] = []
        for (index, client) in Self.clients.enumerated() {
            // Remaining lease time: spread deterministically across 12h.
            let expires = 3600 + (index * 1747) % 39_600
            leases.append(
                .object([
                    "hostname": .string(client.host),
                    "macaddr": .string(client.mac),
                    "ipaddr": .string(client.ip),
                    "duid": .string(""),
                    "expires": .number(Double(expires)),
                    "activetime": .number(Double(43_200 - expires)),
                ]))
        }
        return .object([
            "dhcp_leases": .array(leases),
            "dhcp6_leases": .array([]),
        ])
    }

    private func assoclist(device: String) -> JSONValue {
        let stations = Self.clients.filter { $0.wifi == device }
        var results: [JSONValue] = []
        for station in stations {
            let rxRate = Int.random(in: 72_000...866_700)
            let txRate = Int.random(in: 54_000...433_300)
            results.append(
                .object([
                    "mac": .string(station.mac),
                    "signal": .number(Double(-Int.random(in: 38...72))),
                    "noise": .number(Double(-Int.random(in: 92...100))),
                    "inactive": .number(Double(Int.random(in: 0...30_000))),
                    "rx": .object([
                        "rate": .number(Double(rxRate)),
                        "packets": .number(Double(Int.random(in: 1_000...200_000))),
                    ]),
                    "tx": .object([
                        "rate": .number(Double(txRate)),
                        "packets": .number(Double(Int.random(in: 1_000...150_000))),
                    ]),
                ]))
        }
        return .object(["results": .array(results)])
    }

    // MARK: - uci (mutable in-memory store)

    private func uciGet(_ params: JSONValue) -> JSONValue {
        let config = params["config"].stringValue ?? ""
        let sections = uciConfigs[config] ?? [:]
        var values: [String: JSONValue] = [:]
        for (name, options) in sections {
            values[name] = .object(options)
        }
        return .object(["values": .object(values)])
    }

    private func uciSet(_ params: JSONValue) {
        guard let config = params["config"].stringValue,
            let section = params["section"].stringValue,
            let values = params["values"].objectValue
        else { return }
        guard var sections = uciConfigs[config],
            var existing = sections[section]
        else { return }
        for (key, value) in values {
            existing[key] = value
        }
        sections[section] = existing
        uciConfigs[config] = sections
    }

    private func uciAdd(_ params: JSONValue) -> JSONValue {
        guard let config = params["config"].stringValue,
            let type = params["type"].stringValue
        else { return .object([:]) }

        uciAnonymousCounter += 1
        let name = params["name"].stringValue ?? String(format: "cfg%06x", uciAnonymousCounter)

        var section: [String: JSONValue] = [
            ".type": .string(type),
            ".name": .string(name),
            ".anonymous": .bool(params["name"].stringValue == nil),
        ]
        if let values = params["values"].objectValue {
            for (key, value) in values {
                section[key] = value
            }
        }
        var sections = uciConfigs[config] ?? [:]
        sections[name] = section
        uciConfigs[config] = sections
        return .object(["section": .string(name)])
    }

    private func uciDelete(_ params: JSONValue) {
        guard let config = params["config"].stringValue,
            let section = params["section"].stringValue
        else { return }
        uciConfigs[config]?.removeValue(forKey: section)
    }

    private static func initialUciConfigs() -> [String: [String: [String: JSONValue]]] {
        var configs: [String: [String: [String: JSONValue]]] = [:]

        // ---- wireless (mirrors assets/mock/uci_wireless.json + travelmate STA) ----
        configs["wireless"] = [
            "radio0": [
                ".anonymous": .bool(false),
                ".type": .string("wifi-device"),
                ".name": .string("radio0"),
                "type": .string("mac80211"),
                "path": .string("soc/40000000.pci/pci0000:00/0000:00:00.0/0000:01:00.0"),
                "channel": .string("6"),
                "band": .string("2g"),
                "htmode": .string("HT40"),
                "disabled": .string("0"),
                "country": .string("US"),
            ],
            "radio1": [
                ".anonymous": .bool(false),
                ".type": .string("wifi-device"),
                ".name": .string("radio1"),
                "type": .string("mac80211"),
                "path": .string("soc/40000000.pci/pci0001:00/0001:00:00.0/0001:01:00.0"),
                "channel": .string("36"),
                "band": .string("5g"),
                "htmode": .string("VHT80"),
                "disabled": .string("0"),
                "country": .string("US"),
            ],
            "default_radio0": [
                ".anonymous": .bool(false),
                ".type": .string("wifi-iface"),
                ".name": .string("default_radio0"),
                "device": .string("radio0"),
                "network": .string("lan"),
                "mode": .string("ap"),
                "ssid": .string("LuCI-WiFi"),
                "encryption": .string("psk2"),
                "key": .string("supersecretpassword"),
                "disabled": .string("0"),
            ],
            "default_radio1": [
                ".anonymous": .bool(false),
                ".type": .string("wifi-iface"),
                ".name": .string("default_radio1"),
                "device": .string("radio1"),
                "network": .string("lan"),
                "mode": .string("ap"),
                "ssid": .string("LuCI-WiFi-5G"),
                "encryption": .string("psk2"),
                "key": .string("supersecretpassword"),
                "disabled": .string("0"),
            ],
            "trm_uplink1": [
                ".anonymous": .bool(false),
                ".type": .string("wifi-iface"),
                ".name": .string("trm_uplink1"),
                "device": .string("radio0"),
                "mode": .string("sta"),
                "network": .string("travel_wan"),
                "ssid": .string("CoffeeHouse-Guest"),
                "encryption": .string("psk2"),
                "key": .string("espresso123"),
                "disabled": .string("0"),
            ],
            "trm_uplink2": [
                ".anonymous": .bool(false),
                ".type": .string("wifi-iface"),
                ".name": .string("trm_uplink2"),
                "device": .string("radio1"),
                "mode": .string("sta"),
                "network": .string("travel_wan"),
                "ssid": .string("Hotel-Aurora-Guest-5G"),
                "encryption": .string("psk2"),
                "key": .string("welcome2026"),
                "disabled": .string("1"),
            ],
        ]

        // ---- travelmate ----
        configs["travelmate"] = [
            "global": [
                ".anonymous": .bool(false),
                ".type": .string("travelmate"),
                ".name": .string("global"),
                "trm_enabled": .string("1"),
                "trm_debug": .string("0"),
                "trm_captive": .string("1"),
                "trm_proactive": .string("1"),
                "trm_netcheck": .string("0"),
                "trm_autoadd": .string("0"),
                "trm_randomize": .string("0"),
                "trm_maxretry": .string("3"),
                "trm_minquality": .string("35"),
                "trm_maxwait": .string("30"),
                "trm_timeout": .string("60"),
                "trm_captiveurl": .string("http://detectportal.firefox.com"),
            ],
            "cfg047f11": [
                ".anonymous": .bool(true),
                ".type": .string("uplink"),
                ".name": .string("cfg047f11"),
                "enabled": .string("1"),
                "device": .string("radio0"),
                "ssid": .string("CoffeeHouse-Guest"),
                "con_start": .string("2026-07-08 09:15:03"),
            ],
            "cfg05aa02": [
                ".anonymous": .bool(true),
                ".type": .string("uplink"),
                ".name": .string("cfg05aa02"),
                "enabled": .string("1"),
                "device": .string("radio1"),
                "ssid": .string("Hotel-Aurora-Guest-5G"),
            ],
        ]

        // ---- dhcp ----
        configs["dhcp"] = [
            "cfg01411c": [
                ".anonymous": .bool(true),
                ".type": .string("dnsmasq"),
                ".name": .string("cfg01411c"),
                "domainneeded": .string("1"),
                "localise_queries": .string("1"),
                "rebind_protection": .string("1"),
                "local": .string("/lan/"),
                "domain": .string("lan"),
                "expandhosts": .string("1"),
                "authoritative": .string("1"),
                "readethers": .string("1"),
                "leasefile": .string("/tmp/dhcp.leases"),
                "localservice": .string("1"),
                "ednspacket_max": .string("1232"),
            ],
            "lan": [
                ".anonymous": .bool(false),
                ".type": .string("dhcp"),
                ".name": .string("lan"),
                "interface": .string("lan"),
                "start": .string("100"),
                "limit": .string("150"),
                "leasetime": .string("12h"),
                "dhcpv4": .string("server"),
                "dhcpv6": .string("server"),
                "ra": .string("server"),
            ],
            "guest": [
                ".anonymous": .bool(false),
                ".type": .string("dhcp"),
                ".name": .string("guest"),
                "interface": .string("guest"),
                "start": .string("50"),
                "limit": .string("100"),
                "leasetime": .string("6h"),
            ],
            "wan": [
                ".anonymous": .bool(false),
                ".type": .string("dhcp"),
                ".name": .string("wan"),
                "interface": .string("wan"),
                "ignore": .string("1"),
            ],
            "odhcpd": [
                ".anonymous": .bool(false),
                ".type": .string("odhcpd"),
                ".name": .string("odhcpd"),
                "maindhcp": .string("0"),
                "leasefile": .string("/tmp/hosts/odhcpd"),
                "leasetrigger": .string("/usr/sbin/odhcpd-update"),
            ],
        ]

        // ---- firewall ----
        configs["firewall"] = [
            "cfg01e63d": [
                ".anonymous": .bool(true),
                ".type": .string("defaults"),
                ".name": .string("cfg01e63d"),
                "syn_flood": .string("1"),
                "input": .string("REJECT"),
                "output": .string("ACCEPT"),
                "forward": .string("REJECT"),
            ],
            "cfg02dc81": [
                ".anonymous": .bool(true),
                ".type": .string("zone"),
                ".name": .string("cfg02dc81"),
                "name": .string("lan"),
                "input": .string("ACCEPT"),
                "output": .string("ACCEPT"),
                "forward": .string("ACCEPT"),
                "network": .array([.string("lan"), .string("guest")]),
            ],
            "cfg03dc81": [
                ".anonymous": .bool(true),
                ".type": .string("zone"),
                ".name": .string("cfg03dc81"),
                "name": .string("wan"),
                "input": .string("REJECT"),
                "output": .string("ACCEPT"),
                "forward": .string("REJECT"),
                "masq": .string("1"),
                "mtu_fix": .string("1"),
                "network": .array([
                    .string("wan"), .string("wan6"), .string("wanb"), .string("travel_wan"),
                ]),
            ],
            "cfg04ad58": [
                ".anonymous": .bool(true),
                ".type": .string("forwarding"),
                ".name": .string("cfg04ad58"),
                "src": .string("lan"),
                "dest": .string("wan"),
            ],
        ]

        return configs
    }

    // MARK: - file

    /// Contents of /var/run/travelmate/travelmate.runtime.json — the active
    /// uplink matches the `travelmate`/`wireless` uci configs above.
    private static let travelmateRuntime = """
        {"data":{"travelmate_version":"2.1.2",\
        "station_id":"radio0/CoffeeHouse-Guest/DE:AD:BE:EF:10:01",\
        "station_mac":"de:ad:be:ef:10:01",\
        "station_interface":"trm_wwan",\
        "station_subnet":"10.11.12.97/24",\
        "travelmate_status":"connected, net ok/100",\
        "run_flags":"captive: \\u2714, proxy: \\u2716, autoadd: \\u2716, open: \\u2716",\
        "ext_hooks":"ntp: \\u2714, vpn: \\u2716, mail: \\u2716",\
        "last_run":"2026-07-08 09:15:03"}}
        """

    private func fileRead(path: String) -> JSONValue {
        if path.contains("travelmate") {
            return .object(["data": .string(Self.travelmateRuntime)])
        }
        return .object(["data": .string("")])
    }

    // MARK: - wireguard

    private static func wireGuardInstances(now: Int) -> JSONValue {
        .object([
            "wg0": .object([
                "interface": .string("wg0"),
                "public_key": .string("server_public_key_abcdef123456"),
                "listen_port": .number(51_820),
                "peers": .object([
                    "peer_public_key_laptop": .object([
                        "public_key": .string("peer_public_key_laptop"),
                        "endpoint": .string("192.168.1.150:51821"),
                        "last_handshake": .number(Double(now - Int.random(in: 20...90))),
                        "allowed_ips": .array([.string("10.0.0.2/32")]),
                        "persistent_keepalive": .number(25),
                        "rx_bytes": .number(1_234_567),
                        "tx_bytes": .number(987_654),
                    ]),
                    "peer_public_key_phone": .object([
                        "public_key": .string("peer_public_key_phone"),
                        "endpoint": .string("192.168.1.151:51822"),
                        "last_handshake": .number(Double(now - Int.random(in: 90...400))),
                        "allowed_ips": .array([.string("10.0.0.3/32")]),
                        "persistent_keepalive": .number(25),
                        "rx_bytes": .number(2_345_678),
                        "tx_bytes": .number(1_876_543),
                    ]),
                    "peer_public_key_tablet": .object([
                        "public_key": .string("peer_public_key_tablet"),
                        "endpoint": .string("(none)"),
                        "last_handshake": .number(Double(now - 2 * 86_400)),
                        "allowed_ips": .array([.string("10.0.0.4/32")]),
                        "persistent_keepalive": .number(0),
                        "rx_bytes": .number(345_678),
                        "tx_bytes": .number(234_567),
                    ]),
                ]),
            ])
        ])
    }

    // MARK: - tailscale

    /// (id, ipv4, hostname, ostype, online, offers exit node)
    private static let tailscalePeers:
        [(id: String, ip: String, host: String, os: String, online: Bool, offersExit: Bool)] = [
            ("nodekey-4f8a21", "100.101.102.110", "johns-macbook", "macOS", true, false),
            ("nodekey-7b3c92", "100.101.102.111", "home-server", "linux", true, true),
            ("nodekey-9d1e45", "100.101.102.112", "johns-iphone", "iOS", false, false),
            ("nodekey-2a6f77", "100.101.102.113", "cloud-vps-fra", "linux", true, true),
        ]

    private func tailscaleStatus() -> JSONValue {
        let exitNode = tailscaleSettings["exit_node"]?.coercedString ?? ""
        var peers: [String: JSONValue] = [:]
        for peer in Self.tailscalePeers {
            // set_settings sends the exit node by IP; get_settings historically
            // holds the id — match either so toggles appear to work.
            let isExit = !exitNode.isEmpty && (exitNode == peer.ip || exitNode == peer.id)
            peers[peer.id] = .object([
                "ip": .string("\(peer.ip)<br>fd7a:115c:a1e0::\(peer.ip.suffix(3))"),
                "hostname": .string(peer.host),
                "ostype": .string(peer.os),
                "online": .bool(peer.online),
                "exit_node": .bool(isExit),
                "exit_node_option": .bool(peer.offersExit),
            ])
        }
        return .object([
            "status": .string("running"),
            "version": .string("1.66.4"),
            "ipv4": .string("100.101.102.103"),
            "ipv6": .string("fd7a:115c:a1e0::103"),
            "domain_name": .string("tail1234.ts.net"),
            "peers": .object(peers),
        ])
    }

    // MARK: - Static payloads

    /// Mirrors assets/mock/system_board.json.
    private static let board: JSONValue = .object([
        "hostname": .string("LuCI-Router"),
        "model": .string("Netgear Nighthawk R7800"),
        "board_name": .string("netgear-r7800"),
        "kernel": .string("5.15.134"),
        "system": .string("ARMv7 Processor rev 0 (v7l)"),
        "release": .object([
            "distribution": .string("OpenWrt"),
            "version": .string("23.05.0"),
            "revision": .string("r23497-6637af95aa"),
            "target": .string("ipq806x/generic"),
            "description": .string("OpenWrt 23.05.0 r23497-6637af95aa"),
        ]),
    ])

    /// Mirrors assets/mock/wireless_devices.json.
    private static let wirelessDevices: JSONValue = .object([
        "radio0": radioPayload(
            channel: 6, frequency: 2437, txpower: 20, signal: -45, noise: -95,
            bitrate: 144_400,
            hwmodes: ["b", "g", "n"], htmodes: ["HT20", "HT40"],
            section: "wifinet0", ifname: "wlan0", ssid: "LuCI-WiFi",
            bssid: "E4:95:6E:40:00:03", associations: 12),
        "radio1": radioPayload(
            channel: 36, frequency: 5180, txpower: 23, signal: -50, noise: -100,
            bitrate: 866_700,
            hwmodes: ["a", "n", "ac"], htmodes: ["HT20", "HT40", "VHT20", "VHT40", "VHT80"],
            section: "wifinet1", ifname: "wlan1", ssid: "LuCI-WiFi-5G",
            bssid: "E4:95:6E:40:00:04", associations: 12),
    ])

    private static func radioPayload(
        channel: Int, frequency: Int, txpower: Int, signal: Int, noise: Int,
        bitrate: Int, hwmodes: [String], htmodes: [String],
        section: String, ifname: String, ssid: String, bssid: String, associations: Int
    ) -> JSONValue {
        let encryption: JSONValue = .object([
            "enabled": .bool(true),
            "auth_algs": .array([.string("open")]),
            "description": .string("WPA2 PSK (CCMP)"),
            "wep": .bool(false),
            "wpa": .number(2),
            "pair_ciphers": .array([.string("CCMP")]),
            "group_ciphers": .array([.string("CCMP")]),
            "auth_suites": .array([.string("PSK")]),
        ])
        return .object([
            "up": .bool(true),
            "pending": .bool(false),
            "disabled": .bool(false),
            "channel": .number(Double(channel)),
            "frequency": .number(Double(frequency)),
            "txpower": .number(Double(txpower)),
            "txpower_offset": .number(0),
            "quality": .number(70),
            "quality_max": .number(70),
            "signal": .number(Double(signal)),
            "noise": .number(Double(noise)),
            "bitrate": .number(Double(bitrate)),
            "country": .string("US"),
            "hwmodes": .array(hwmodes.map { .string($0) }),
            "htmodes": .array(htmodes.map { .string($0) }),
            "hardware": .object(["name": .string("Qualcomm Atheros QCA9984")]),
            "interfaces": .array([
                .object([
                    "section": .string(section),
                    "ifname": .string(ifname),
                    "config": .object([
                        "mode": .string("ap"),
                        "ssid": .string(ssid),
                        "channel": .string("auto"),
                        "disabled": .bool(false),
                        "encryption": .string("psk2"),
                        "key": .string("********"),
                    ]),
                    "iwinfo": .object([
                        "channel": .number(Double(channel)),
                        "frequency": .number(Double(frequency)),
                        "txpower": .number(Double(txpower)),
                        "bitrate": .number(Double(bitrate)),
                        "signal": .number(Double(signal)),
                        "noise": .number(Double(noise)),
                        "quality": .number(70),
                        "quality_max": .number(70),
                        "mode": .string("Master"),
                        "ssid": .string(ssid),
                        "bssid": .string(bssid),
                        "encryption": encryption,
                        "associations": .number(Double(associations)),
                    ]),
                ])
            ]),
        ])
    }

    /// Mirrors assets/mock/interface_dump.json (wan, wan6, wanb, lan, guest).
    private static let interfaceDump: JSONValue = .object([
        "interface": .array([
            interfaceEntry(
                name: "wan", up: true, available: true, proto: "dhcp", device: "eth0",
                ipv4: [("100.64.0.123", 24)], ipv6: [],
                routes: [("0.0.0.0", 0, "100.64.0.1")],
                dns: ["8.8.8.8", "8.8.4.4"]),
            interfaceEntry(
                name: "wan6", up: true, available: true, proto: "dhcpv6", device: "eth0",
                ipv4: [], ipv6: [("2001:db8::1", 64)],
                routes: [],
                dns: ["2001:4860:4860::8888"]),
            interfaceEntry(
                name: "wanb", up: false, available: false, proto: "pppoe", device: "eth1",
                ipv4: [], ipv6: [], routes: [], dns: []),
            interfaceEntry(
                name: "lan", up: true, available: true, proto: "static", device: "br-lan",
                ipv4: [("192.168.1.1", 24)], ipv6: [], routes: [], dns: []),
            interfaceEntry(
                name: "guest", up: true, available: true, proto: "static", device: "br-guest",
                ipv4: [("192.168.50.1", 24)], ipv6: [], routes: [], dns: []),
        ])
    ])

    private static func interfaceEntry(
        name: String, up: Bool, available: Bool, proto: String, device: String,
        ipv4: [(String, Int)], ipv6: [(String, Int)],
        routes: [(String, Int, String)], dns: [String]
    ) -> JSONValue {
        let emptyInactive: JSONValue = .object([
            "ipv4-address": .array([]),
            "ipv6-address": .array([]),
            "route": .array([]),
            "dns-server": .array([]),
            "dns-search": .array([]),
        ])
        return .object([
            "interface": .string(name),
            "up": .bool(up),
            "pending": .bool(false),
            "available": .bool(available),
            "autostart": .bool(true),
            "dynamic": .bool(false),
            "proto": .string(proto),
            "device": .string(device),
            "metric": .number(0),
            "dns_metric": .number(0),
            "delegation": .bool(true),
            "ipv4-address": .array(
                ipv4.map {
                    .object([
                        "address": .string($0.0),
                        "mask": .number(Double($0.1)),
                        "ptpaddress": .string(""),
                    ])
                }),
            "ipv6-address": .array(
                ipv6.map {
                    .object([
                        "address": .string($0.0),
                        "mask": .number(Double($0.1)),
                        "ptpaddress": .string(""),
                    ])
                }),
            "ipv6-prefix": .array([]),
            "ipv6-prefix-assignment": .array([]),
            "route": .array(
                routes.map {
                    .object([
                        "target": .string($0.0),
                        "mask": .number(Double($0.1)),
                        "nexthop": .string($0.2),
                        "source": .string(""),
                    ])
                }),
            "dns-server": .array(dns.map { .string($0) }),
            "dns-search": .array([]),
            "inactive": emptyInactive,
        ])
    }

    // MARK: - iwinfo scan

    private static func scanResults(device: String) -> JSONValue {
        let entries: [JSONValue]
        switch device {
        case "radio0":
            entries = [
                scanEntry(
                    ssid: "CoffeeHouse-Guest", bssid: "DE:AD:BE:EF:10:01", band: 2,
                    channel: 6, signal: -48, quality: 58, security: .psk2),
                scanEntry(
                    ssid: "Hotel-Aurora-Guest", bssid: "DE:AD:BE:EF:20:01", band: 2,
                    channel: 1, signal: -62, quality: 41, security: .psk2),
                scanEntry(
                    ssid: "xfinitywifi", bssid: "0A:1B:2C:3D:4E:01", band: 2,
                    channel: 11, signal: -74, quality: 24, security: .open),
                scanEntry(
                    ssid: "Neighbors-2G", bssid: "0A:1B:2C:3D:4E:02", band: 2,
                    channel: 6, signal: -80, quality: 15, security: .psk2),
                scanEntry(
                    ssid: "HP-Print-A1-Setup", bssid: "0A:1B:2C:3D:4E:03", band: 2,
                    channel: 3, signal: -68, quality: 33, security: .open),
            ]
        case "radio1":
            entries = [
                scanEntry(
                    ssid: "Hotel-Aurora-Guest-5G", bssid: "DE:AD:BE:EF:20:02", band: 5,
                    channel: 44, signal: -55, quality: 49, security: .psk2),
                scanEntry(
                    ssid: "CoffeeHouse-Guest", bssid: "DE:AD:BE:EF:10:02", band: 5,
                    channel: 36, signal: -52, quality: 53, security: .psk2),
                scanEntry(
                    ssid: "Neighbors-5G", bssid: "0A:1B:2C:3D:4E:04", band: 5,
                    channel: 149, signal: -71, quality: 27, security: .sae),
                scanEntry(
                    ssid: "Airport_Free_WiFi", bssid: "0A:1B:2C:3D:4E:05", band: 5,
                    channel: 100, signal: -78, quality: 18, security: .open),
            ]
        default:
            entries = []
        }
        return .object(["results": .array(entries)])
    }

    private enum ScanSecurity {
        case open
        case psk2
        case sae
    }

    private static func scanEntry(
        ssid: String, bssid: String, band: Int, channel: Int,
        signal: Int, quality: Int, security: ScanSecurity
    ) -> JSONValue {
        let encryption: JSONValue
        switch security {
        case .open:
            encryption = .object(["enabled": .bool(false)])
        case .psk2:
            encryption = .object([
                "enabled": .bool(true),
                "wpa": .array([.number(2)]),
                "authentication": .array([.string("psk")]),
                "description": .string("WPA2 PSK (CCMP)"),
            ])
        case .sae:
            encryption = .object([
                "enabled": .bool(true),
                "wpa": .array([.number(3)]),
                "authentication": .array([.string("sae")]),
                "description": .string("WPA3 SAE (CCMP)"),
            ])
        }
        return .object([
            "ssid": .string(ssid),
            "bssid": .string(bssid),
            "mode": .string("Master"),
            "band": .number(Double(band)),
            "channel": .number(Double(channel)),
            "signal": .number(Double(signal)),
            "quality": .number(Double(quality)),
            "quality_max": .number(70),
            "encryption": encryption,
        ])
    }
}
