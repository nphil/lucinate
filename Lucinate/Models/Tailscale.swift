import Foundation

/// Models for the Tailscale management module, mirroring
/// `lib/models/tailscale.dart`.
///
/// These map the responses of the `tailscale` ubus object provided by
/// `luci-app-tailscale-community` on the router:
///   - `get_status`   -> `TailscaleStatus` (live daemon state + peers)
///   - `get_settings` -> `TailscaleSettings` (persisted/desired config)
///   - `set_settings` -> takes the *full* settings as `form_data` (see
///     `TailscaleSettings.toFormData`); the router reapplies every flag, so a
///     partial payload would silently turn things off.

struct TailscalePeer: Sendable, Identifiable, Equatable {
    /// Stable Tailscale node id (the key in the `peers` map).
    let id: String

    /// Primary Tailscale IPv4 (the router returns `"100.x<br>fd7a:..."`; we
    /// keep the first entry — the CLI's `--exit-node` wants an IP, not the
    /// node id).
    let ip: String
    let hostname: String
    let os: String
    let online: Bool

    /// This peer is the currently selected exit node.
    let isExitNode: Bool

    /// This peer advertises itself as an available exit node.
    let offersExitNode: Bool

    init(
        id: String,
        ip: String,
        hostname: String,
        os: String,
        online: Bool,
        isExitNode: Bool,
        offersExitNode: Bool
    ) {
        self.id = id
        self.ip = ip
        self.hostname = hostname
        self.os = os
        self.online = online
        self.isExitNode = isExitNode
        self.offersExitNode = offersExitNode
    }

    static func fromJSON(id: String, _ json: JSONValue) -> TailscalePeer {
        let rawIP = json["ip"].coercedString ?? ""
        let firstIP = rawIP.components(separatedBy: "<br>").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return TailscalePeer(
            id: id,
            ip: firstIP,
            hostname: json["hostname"].coercedString ?? "",
            os: json["ostype"].coercedString ?? "",
            online: json["online"].boolValue ?? false,
            isExitNode: json["exit_node"].boolValue ?? false,
            offersExitNode: json["exit_node_option"].boolValue ?? false
        )
    }
}

struct TailscaleStatus: Sendable, Equatable {
    /// What the router's Tailscale daemon is doing, from `get_status.status`.
    enum State: Sendable, Equatable {
        /// The plugin found no tailscale binary (`not_installed`).
        case notInstalled
        /// `logout`: tailscaled is up but this node is not signed in.
        case needsLogin
        case running
        /// The plugin answers with an empty status whenever `tailscale status
        /// --json` fails or the backend is neither Running nor NeedsLogin
        /// (Starting, NoState, Stopped, ...) — typical while the router sits
        /// behind a hotel portal with no internet. Never means "missing".
        case notConnected

        init(pluginStatus raw: String?) {
            let normalized = (raw ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            switch normalized {
            case "running": self = .running
            case "logout": self = .needsLogin
            case "not_installed": self = .notInstalled
            default: self = .notConnected
            }
        }
    }

    let state: State
    let version: String
    /// Tailnet addresses; nil while the plugin only has its placeholder text.
    let ipv4: String?
    let ipv6: String?
    let domainName: String
    let peers: [TailscalePeer]

    /// First daemon health warning (e.g. the control server is unreachable);
    /// nil when there is none.
    let health: String?

    /// tailscaled runs on a kernel TUN device (true) or in userspace
    /// networking (false); nil when the plugin does not report it.
    let tunMode: Bool?

    init(
        state: State,
        version: String,
        ipv4: String?,
        ipv6: String?,
        domainName: String,
        peers: [TailscalePeer],
        health: String? = nil,
        tunMode: Bool? = nil
    ) {
        self.state = state
        self.version = version
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.domainName = domainName
        self.peers = peers
        self.health = health
        self.tunMode = tunMode
    }

    var isRunning: Bool { state == .running }

    // Convenience aliases used by the UI layer.
    var tailnetIP: String? { ipv4 }
    var tailnetName: String? { domainName.isEmpty ? nil : domainName }
    var exitNodeName: String? { currentExitNode?.hostname }
    var peersOnline: Int { onlinePeerCount }

    var currentExitNode: TailscalePeer? {
        peers.first { $0.isExitNode }
    }

    var exitNodeCandidates: [TailscalePeer] {
        peers.filter { $0.offersExitNode }
            .sorted { $0.hostname.lowercased() < $1.hostname.lowercased() }
    }

    var onlinePeerCount: Int {
        peers.filter { $0.online }.count
    }

    /// Parses the payload of `tailscale get_status`.
    static func fromJSON(_ json: JSONValue) -> TailscaleStatus {
        var peers: [TailscalePeer] = []
        if let rawPeers = json["peers"].objectValue {
            for (key, value) in rawPeers where value.objectValue != nil {
                peers.append(TailscalePeer.fromJSON(id: key, value))
            }
        }
        // Stable ordering (the peers map is unordered).
        peers.sort { $0.hostname.lowercased() < $1.hostname.lowercased() }
        return TailscaleStatus(
            state: State(pluginStatus: json["status"].coercedString),
            version: json["version"].coercedString ?? "",
            ipv4: address(from: json["ipv4"].coercedString),
            ipv6: address(from: json["ipv6"].coercedString),
            domainName: json["domain_name"].coercedString ?? "",
            peers: peers,
            health: trimmedOrNil(json["health"].coercedString),
            tunMode: json["TUNMode"].boolValue
        )
    }

    /// The plugin fills `ipv4` with prose ("Not running", "No IP assigned")
    /// when it has no address, so only address-shaped text counts.
    private static func address(from raw: String?) -> String? {
        guard let candidate = trimmedOrNil(raw),
            candidate.contains(where: { $0 == "." || $0 == ":" }),
            candidate.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == ":" })
        else { return nil }
        return candidate
    }

    private static func trimmedOrNil(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// Placeholder before the first reply; callers check the controller's
    /// `loaded` flag instead of reading this as a state.
    static let empty = TailscaleStatus(
        state: .notConnected,
        version: "",
        ipv4: nil,
        ipv6: nil,
        domainName: "",
        peers: []
    )

    /// The `tailscale` ubus object is not registered on the router.
    static let notInstalled = TailscaleStatus(
        state: .notInstalled,
        version: "",
        ipv4: nil,
        ipv6: nil,
        domainName: "",
        peers: []
    )
}

struct TailscaleSettings: Sendable, Equatable {
    let acceptRoutes: Bool
    let advertiseExitNode: Bool

    /// From `get_settings` this is the exit node's stable *id* (or ""). To
    /// *set* the exit node we must send an IP instead — see `toFormData`.
    let exitNodeId: String
    let exitNodeAllowLanAccess: Bool
    let shieldsUp: Bool
    let ssh: Bool
    let runWebClient: Bool
    let noSnat: Bool
    let disableMagicDns: Bool
    let fwMode: String
    let advertiseRoutes: [String]

    /// Raw passthrough of every scalar field returned by `get_settings`, so
    /// writes can send the FULL form_data even for flags this model does not
    /// explicitly know about.
    let raw: [String: String]

    init(
        acceptRoutes: Bool,
        advertiseExitNode: Bool,
        exitNodeId: String,
        exitNodeAllowLanAccess: Bool,
        shieldsUp: Bool,
        ssh: Bool,
        runWebClient: Bool,
        noSnat: Bool,
        disableMagicDns: Bool,
        fwMode: String,
        advertiseRoutes: [String],
        raw: [String: String] = [:]
    ) {
        self.acceptRoutes = acceptRoutes
        self.advertiseExitNode = advertiseExitNode
        self.exitNodeId = exitNodeId
        self.exitNodeAllowLanAccess = exitNodeAllowLanAccess
        self.shieldsUp = shieldsUp
        self.ssh = ssh
        self.runWebClient = runWebClient
        self.noSnat = noSnat
        self.disableMagicDns = disableMagicDns
        self.fwMode = fwMode
        self.advertiseRoutes = advertiseRoutes
        self.raw = raw
    }

    /// User-facing "Accept DNS / MagicDNS" is the inverse of
    /// `disable_magic_dns`.
    var acceptDns: Bool { !disableMagicDns }

    /// Parses the payload of `tailscale get_settings`.
    static func fromJSON(_ json: JSONValue) -> TailscaleSettings {
        func flag(_ key: String) -> Bool {
            json[key].boolValue ?? false
        }

        var routes: [String] = []
        if let list = json["advertise_routes"].arrayValue {
            routes = list.compactMap { $0.coercedString }.filter { !$0.isEmpty }
        }

        var raw: [String: String] = [:]
        if let object = json.objectValue {
            for (key, value) in object {
                if let scalar = value.coercedString {
                    raw[key] = scalar
                }
            }
        }

        return TailscaleSettings(
            acceptRoutes: flag("accept_routes"),
            advertiseExitNode: flag("advertise_exit_node"),
            exitNodeId: json["exit_node"].coercedString ?? "",
            exitNodeAllowLanAccess: flag("exit_node_allow_lan_access"),
            shieldsUp: flag("shields_up"),
            ssh: flag("ssh"),
            runWebClient: flag("runwebclient"),
            noSnat: flag("nosnat"),
            disableMagicDns: flag("disable_magic_dns"),
            fwMode: json["fw_mode"].coercedString ?? "nftables",
            advertiseRoutes: routes,
            raw: raw
        )
    }

    /// Builds the complete `form_data` for `set_settings`, mirroring the LuCI
    /// web UI: every flag is sent as a "1"/"0" string so the router doesn't
    /// turn unspecified settings off. `hostname` is intentionally omitted
    /// (the web UI omits it too, which preserves the node's Tailscale name).
    ///
    /// - Parameters:
    ///   - exitNodeIp: preserves or sets the exit node *by IP*.
    ///   - overrides: carries the single field being changed.
    func toFormData(
        exitNodeIp: String,
        overrides: [String: JSONValue]? = nil
    ) -> [String: JSONValue] {
        var data: [String: JSONValue] = [
            "fw_mode": .string(fwMode),
            "accept_routes": .string(acceptRoutes ? "1" : "0"),
            "advertise_exit_node": .string(advertiseExitNode ? "1" : "0"),
            "exit_node_allow_lan_access": .string(exitNodeAllowLanAccess ? "1" : "0"),
            "runwebclient": .string(runWebClient ? "1" : "0"),
            "nosnat": .string(noSnat ? "1" : "0"),
            "shields_up": .string(shieldsUp ? "1" : "0"),
            "ssh": .string(ssh ? "1" : "0"),
            "disable_magic_dns": .string(disableMagicDns ? "1" : "0"),
            "advertise_routes": .array(advertiseRoutes.map { .string($0) }),
            "exit_node": .string(exitNodeIp),
        ]
        if let overrides {
            for (key, value) in overrides {
                data[key] = value
            }
        }
        // A node can't both advertise an exit node and use one; the router
        // enforces this too, but keep our payload internally consistent.
        if let exitNode = data["exit_node"]?.coercedString, !exitNode.isEmpty {
            data["advertise_exit_node"] = .string("0")
        }
        return data
    }

    static let empty = TailscaleSettings(
        acceptRoutes: false,
        advertiseExitNode: false,
        exitNodeId: "",
        exitNodeAllowLanAccess: false,
        shieldsUp: false,
        ssh: false,
        runWebClient: false,
        noSnat: false,
        disableMagicDns: true,
        fwMode: "nftables",
        advertiseRoutes: [],
        raw: [:]
    )
}
