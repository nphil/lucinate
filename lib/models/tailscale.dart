/// Models for the Tailscale management module.
///
/// These map the responses of the `tailscale` ubus object provided by
/// `luci-app-tailscale-community` on the router:
///   - `get_status`   -> [TailscaleStatus] (live daemon state + peers)
///   - `get_settings` -> [TailscaleSettings] (persisted/desired config)
///   - `set_settings` -> takes the *full* settings as `form_data` (see
///     [TailscaleSettings.toFormData]); the router reapplies every flag, so a
///     partial payload would silently turn things off.
library;

class TailscalePeer {
  /// Stable Tailscale node id (the key in the `peers` map).
  final String id;

  /// Primary Tailscale IPv4 (the router returns `"100.x<br>fd7a:..."`, we keep
  /// the first entry — the CLI's `--exit-node` wants an IP, not the node id).
  final String ip;
  final String hostname;
  final String os;
  final bool online;

  /// This peer is the currently selected exit node.
  final bool isExitNode;

  /// This peer advertises itself as an available exit node.
  final bool offersExitNode;

  const TailscalePeer({
    required this.id,
    required this.ip,
    required this.hostname,
    required this.os,
    required this.online,
    required this.isExitNode,
    required this.offersExitNode,
  });

  factory TailscalePeer.fromJson(String id, Map<String, dynamic> json) {
    final rawIp = (json['ip'] ?? '').toString();
    return TailscalePeer(
      id: id,
      ip: rawIp.split('<br>').first.trim(),
      hostname: (json['hostname'] ?? '').toString(),
      os: (json['ostype'] ?? '').toString(),
      online: json['online'] == true,
      isExitNode: json['exit_node'] == true,
      offersExitNode: json['exit_node_option'] == true,
    );
  }
}

class TailscaleStatus {
  /// `running` | `logout` (needs login) | `not_installed` | `` (unknown).
  final String state;
  final String version;
  final String ipv4;
  final String? ipv6;
  final String domainName;
  final List<TailscalePeer> peers;

  const TailscaleStatus({
    required this.state,
    required this.version,
    required this.ipv4,
    required this.ipv6,
    required this.domainName,
    required this.peers,
  });

  bool get isRunning => state == 'running';
  bool get needsLogin => state == 'logout';
  bool get isInstalled => state.isNotEmpty && state != 'not_installed';

  TailscalePeer? get currentExitNode {
    for (final p in peers) {
      if (p.isExitNode) return p;
    }
    return null;
  }

  List<TailscalePeer> get exitNodeCandidates =>
      peers.where((p) => p.offersExitNode).toList()
        ..sort(
          (a, b) => a.hostname.toLowerCase().compareTo(b.hostname.toLowerCase()),
        );

  int get onlinePeerCount => peers.where((p) => p.online).length;

  factory TailscaleStatus.fromJson(Map<String, dynamic> json) {
    final peers = <TailscalePeer>[];
    final rawPeers = json['peers'];
    if (rawPeers is Map) {
      rawPeers.forEach((key, value) {
        if (value is Map) {
          peers.add(
            TailscalePeer.fromJson(
              key.toString(),
              Map<String, dynamic>.from(value),
            ),
          );
        }
      });
    }
    return TailscaleStatus(
      state: (json['status'] ?? '').toString(),
      version: (json['version'] ?? '').toString(),
      ipv4: (json['ipv4'] ?? '').toString(),
      ipv6: json['ipv6']?.toString(),
      domainName: (json['domain_name'] ?? '').toString(),
      peers: peers,
    );
  }

  static const empty = TailscaleStatus(
    state: '',
    version: '',
    ipv4: '',
    ipv6: null,
    domainName: '',
    peers: [],
  );
}

class TailscaleSettings {
  final bool acceptRoutes;
  final bool advertiseExitNode;

  /// From `get_settings` this is the exit node's stable *id* (or ''). To *set*
  /// the exit node we must send an IP instead — see [toFormData].
  final String exitNodeId;
  final bool exitNodeAllowLanAccess;
  final bool shieldsUp;
  final bool ssh;
  final bool runWebClient;
  final bool noSnat;
  final bool disableMagicDns;
  final String fwMode;
  final List<String> advertiseRoutes;

  const TailscaleSettings({
    required this.acceptRoutes,
    required this.advertiseExitNode,
    required this.exitNodeId,
    required this.exitNodeAllowLanAccess,
    required this.shieldsUp,
    required this.ssh,
    required this.runWebClient,
    required this.noSnat,
    required this.disableMagicDns,
    required this.fwMode,
    required this.advertiseRoutes,
  });

  /// User-facing "Accept DNS / MagicDNS" is the inverse of `disable_magic_dns`.
  bool get acceptDns => !disableMagicDns;

  factory TailscaleSettings.fromJson(Map<String, dynamic> json) {
    bool b(dynamic v) => v == true || v == 1 || v == '1';
    final routes = <String>[];
    final ar = json['advertise_routes'];
    if (ar is List) {
      for (final r in ar) {
        routes.add(r.toString());
      }
    }
    return TailscaleSettings(
      acceptRoutes: b(json['accept_routes']),
      advertiseExitNode: b(json['advertise_exit_node']),
      exitNodeId: (json['exit_node'] ?? '').toString(),
      exitNodeAllowLanAccess: b(json['exit_node_allow_lan_access']),
      shieldsUp: b(json['shields_up']),
      ssh: b(json['ssh']),
      runWebClient: b(json['runwebclient']),
      noSnat: b(json['nosnat']),
      disableMagicDns: b(json['disable_magic_dns']),
      fwMode: (json['fw_mode'] ?? 'nftables').toString(),
      advertiseRoutes: routes,
    );
  }

  /// Builds the complete `form_data` for `set_settings`, mirroring the LuCI web
  /// UI: every flag is sent as a `'1'`/`'0'` string so the router doesn't turn
  /// unspecified settings off. `hostname` is intentionally omitted (the web UI
  /// omits it too, which preserves the node's Tailscale name).
  ///
  /// [exitNodeIp] preserves or sets the exit node *by IP*; [overrides] carries
  /// the single field being changed.
  Map<String, dynamic> toFormData({
    required String exitNodeIp,
    Map<String, dynamic>? overrides,
  }) {
    final data = <String, dynamic>{
      'fw_mode': fwMode,
      'accept_routes': acceptRoutes ? '1' : '0',
      'advertise_exit_node': advertiseExitNode ? '1' : '0',
      'exit_node_allow_lan_access': exitNodeAllowLanAccess ? '1' : '0',
      'runwebclient': runWebClient ? '1' : '0',
      'nosnat': noSnat ? '1' : '0',
      'shields_up': shieldsUp ? '1' : '0',
      'ssh': ssh ? '1' : '0',
      'disable_magic_dns': disableMagicDns ? '1' : '0',
      'advertise_routes': advertiseRoutes,
      'exit_node': exitNodeIp,
    };
    if (overrides != null) data.addAll(overrides);
    // A node can't both advertise an exit node and use one; the router enforces
    // this too, but keep our payload internally consistent.
    if ((data['exit_node'] as String).isNotEmpty) {
      data['advertise_exit_node'] = '0';
    }
    return data;
  }

  static const empty = TailscaleSettings(
    acceptRoutes: false,
    advertiseExitNode: false,
    exitNodeId: '',
    exitNodeAllowLanAccess: false,
    shieldsUp: false,
    ssh: false,
    runWebClient: false,
    noSnat: false,
    disableMagicDns: true,
    fwMode: 'nftables',
    advertiseRoutes: [],
  );
}
