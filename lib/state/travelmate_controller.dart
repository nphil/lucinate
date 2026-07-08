import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:luci_mobile/main.dart';
import 'package:luci_mobile/models/travelmate.dart';

/// Owns the Travelmate module's state. Borrows the authenticated RPC channel
/// via [AppState.rpcCall].
final travelmateControllerProvider =
    ChangeNotifierProvider<TravelmateController>(
  (ref) => TravelmateController(ref),
);

class TravelmateController extends ChangeNotifier {
  TravelmateController(this._ref);

  final Ref _ref;

  static const _statusFile = '/var/run/travelmate/travelmate.runtime.json';

  /// Networks weaker than this are too flaky to repeat, so we hide them.
  static const _minSignalDbm = -80;

  TravelmateStatus _status = TravelmateStatus.empty;
  List<TravelmateUplink> _uplinks = const [];
  List<WifiScanResult> _scanResults = const [];
  Map<String, int> _radioBands = const {}; // radio0 -> 2, radio1 -> 5, ...
  List<BroadcastRadio> _broadcast = const [];
  bool _loaded = false;
  bool _isLoading = false;
  bool _isBusy = false;
  bool _isScanning = false;
  String? _error;

  TravelmateStatus get status => _status;
  List<TravelmateUplink> get uplinks => _uplinks;
  List<WifiScanResult> get scanResults => _scanResults;
  Map<String, int> get radioBands => _radioBands;
  List<BroadcastRadio> get broadcast => _broadcast;
  bool get loaded => _loaded;
  bool get isLoading => _isLoading;
  bool get isBusy => _isBusy;
  bool get isScanning => _isScanning;
  String? get error => _error;

  /// Friendly band label for a wifi device (`radio0` -> `2.4 GHz`), falling
  /// back to the raw device name when the band can't be determined.
  String deviceLabel(String device) {
    final label = bandLabelFor(_radioBands[device] ?? 0);
    return label.isEmpty ? device : label;
  }

  /// Best-effort band (2/5/6) for a `wifi-device` uci section.
  static int _bandOf(Map<String, dynamic> dev) {
    switch ((dev['band'] ?? '').toString()) {
      case '2g':
        return 2;
      case '5g':
        return 5;
      case '6g':
        return 6;
    }
    final hw = (dev['hwmode'] ?? '').toString(); // legacy 11a/11g/11b/11n
    if (hw.contains('a')) return 5;
    if (hw.contains('g') || hw.contains('b')) return 2;
    final ch = int.tryParse((dev['channel'] ?? '').toString());
    if (ch != null && ch > 0) return ch <= 14 ? 2 : 5;
    return 0;
  }

  Future<dynamic> _rpc(
    String object,
    String method, [
    Map<String, dynamic>? params,
  ]) {
    return _ref
        .read(appStateProvider)
        .rpcCall(object: object, method: method, params: params);
  }

  Future<void> load() async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final results = await Future.wait([
        _rpc('uci', 'get', {'config': 'travelmate'}),
        _rpc('file', 'read', {'path': _statusFile}).catchError((_) => null),
        _rpc('uci', 'get', {'config': 'wireless'}).catchError((_) => null),
      ]);

      // --- radio -> band map (so we can show 2.4/5 GHz, not radio0/radio1) ---
      final bands = <String, int>{};
      final wl = results[2];
      final wlValues = (wl is Map) ? wl['values'] : null;
      if (wlValues is Map) {
        wlValues.forEach((key, section) {
          if (section is Map && section['.type'] == 'wifi-device') {
            bands[key.toString()] =
                _bandOf(Map<String, dynamic>.from(section));
          }
        });
      }
      _radioBands = bands;

      // --- travelmate config: global + uplinks ---
      bool enabled = false;
      final uplinks = <TravelmateUplink>[];
      final tmData = results[0];
      final values = (tmData is Map) ? tmData['values'] : null;
      if (values is Map) {
        values.forEach((key, section) {
          if (section is! Map) return;
          final type = section['.type'];
          if (type == 'travelmate') {
            enabled = (section['trm_enabled'] ?? '0').toString() == '1';
          } else if (type == 'uplink') {
            uplinks.add(
              TravelmateUplink.fromUci(
                key.toString(),
                Map<String, dynamic>.from(section),
              ),
            );
          }
        });
      }
      _uplinks = uplinks;

      // --- live status from runtime.json ---
      final fileData = results[1];
      final rawData = (fileData is Map) ? (fileData['data'] ?? '') : '';
      _status = TravelmateStatus.fromRuntime(
        rawData.toString(),
        enabled: enabled,
      );

      // --- broadcast radios (the router's own AP that devices join) ---
      _broadcast = _parseBroadcast(wlValues, _radioBands, _status.activeDevice);

      _loaded = true;
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Restart travelmate so config changes take effect immediately.
  Future<void> _restart() async {
    await _rpc('file', 'exec', {
      'command': '/etc/init.d/travelmate',
      'params': ['restart'],
    });
  }

  Future<bool> setEnabled(bool value) async {
    _isBusy = true;
    _error = null;
    notifyListeners();
    try {
      await _rpc('uci', 'set', {
        'config': 'travelmate',
        'section': 'global',
        'values': {'trm_enabled': value ? '1' : '0'},
      });
      await _rpc('uci', 'commit', {'config': 'travelmate'});
      await _restart();
      await load();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }

  /// Scan both radios for nearby networks and merge, keeping the strongest
  /// signal per SSID.
  Future<void> scan() async {
    _isScanning = true;
    _error = null;
    notifyListeners();
    try {
      // Key by SSID + band so 2.4GHz and 5GHz of the same network both appear
      // as distinct, selectable entries — the router repeats one specific radio,
      // so the band choice matters for a travel uplink.
      final byNameBand = <String, WifiScanResult>{};
      // Scan both radios in parallel — halves the wait vs. one-after-the-other.
      final perRadio = await Future.wait(
        const ['radio0', 'radio1'].map((device) async {
          try {
            final res = await _rpc('iwinfo', 'scan', {'device': device});
            final list = (res is Map) ? res['results'] : null;
            return MapEntry(device, list is List ? list : const <dynamic>[]);
          } catch (_) {
            // one radio failing (e.g. busy) shouldn't abort the whole scan
            return MapEntry(device, const <dynamic>[]);
          }
        }),
      );
      for (final radio in perRadio) {
        for (final entry in radio.value) {
          if (entry is! Map) continue;
          final scan = WifiScanResult.fromIwinfo(
            Map<String, dynamic>.from(entry),
            radio.key,
          );
          if (scan.ssid.isEmpty) continue; // skip hidden networks
          // Skip networks too weak to repeat reliably (0 == unknown, keep it).
          if (scan.signal != 0 && scan.signal < _minSignalDbm) continue;
          final key = '${scan.ssid} ${scan.band}';
          final existing = byNameBand[key];
          if (existing == null || scan.signal > existing.signal) {
            byNameBand[key] = scan;
          }
        }
      }
      // Strongest networks first, so the best uplinks surface at the top.
      final merged = byNameBand.values.toList()
        ..sort((a, b) => b.signal.compareTo(a.signal));
      _scanResults = merged;
    } catch (e) {
      _error = e.toString();
    } finally {
      _isScanning = false;
      notifyListeners();
    }
  }

  /// Forget a saved uplink: removes both its `wireless` STA interface and the
  /// matching `travelmate.@uplink`, then restarts travelmate.
  Future<bool> deleteUplink(TravelmateUplink u) async {
    // Optimistically drop it so the swiped row doesn't linger in the list.
    _uplinks = _uplinks.where((x) => x.sectionId != u.sectionId).toList();
    _isBusy = true;
    _error = null;
    notifyListeners();
    try {
      // Find and remove the matching wireless STA interface.
      final wireless = await _rpc('uci', 'get', {'config': 'wireless'});
      final values = (wireless is Map) ? wireless['values'] : null;
      String? ifaceSection;
      if (values is Map) {
        values.forEach((key, section) {
          if (section is! Map) return;
          if (section['.type'] != 'wifi-iface') return;
          if ((section['mode'] ?? '').toString() != 'sta') return;
          if ((section['ssid'] ?? '').toString() != u.ssid) return;
          if ((section['device'] ?? '').toString() != u.device) return;
          ifaceSection = key.toString();
        });
      }
      if (ifaceSection != null) {
        await _rpc('uci', 'delete', {
          'config': 'wireless',
          'section': ifaceSection,
        });
        await _rpc('uci', 'commit', {'config': 'wireless'});
      }
      // Remove the travelmate uplink record.
      await _rpc('uci', 'delete', {
        'config': 'travelmate',
        'section': u.sectionId,
      });
      await _rpc('uci', 'commit', {'config': 'travelmate'});
      await _restart();
      await load();
      return true;
    } catch (e) {
      _error = e.toString();
      await load(); // restore the true list if the delete failed
      return false;
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }

  /// Build the broadcast-radio view from wireless config. The primary AP per
  /// radio is the `mode=ap` iface (preferring `network=lan`).
  List<BroadcastRadio> _parseBroadcast(
    dynamic wlValues,
    Map<String, int> bands,
    String activeDevice,
  ) {
    if (wlValues is! Map) return const [];
    final channels = <String, String>{};
    final apByDevice = <String, Map<String, dynamic>>{};
    final apSectionByDevice = <String, String>{};
    final apIsLan = <String, bool>{};
    wlValues.forEach((key, section) {
      if (section is! Map) return;
      final type = section['.type'];
      if (type == 'wifi-device') {
        channels[key.toString()] = (section['channel'] ?? 'auto').toString();
      } else if (type == 'wifi-iface') {
        if ((section['mode'] ?? '').toString() != 'ap') return;
        final dev = (section['device'] ?? '').toString();
        if (dev.isEmpty) return;
        final isLan = (section['network'] ?? '').toString() == 'lan';
        // Prefer the LAN AP; otherwise keep the first AP seen on this radio.
        if (!apByDevice.containsKey(dev) || (isLan && apIsLan[dev] != true)) {
          apByDevice[dev] = Map<String, dynamic>.from(section);
          apSectionByDevice[dev] = key.toString();
          apIsLan[dev] = isLan;
        }
      }
    });
    final devices = bands.keys.toList()
      ..sort((a, b) => (bands[a] ?? 0).compareTo(bands[b] ?? 0));
    final radios = <BroadcastRadio>[];
    for (final dev in devices) {
      final ap = apByDevice[dev];
      if (ap == null) continue; // radio without an AP isn't a broadcast radio
      radios.add(BroadcastRadio(
        device: dev,
        band: bands[dev] ?? 0,
        apSection: apSectionByDevice[dev] ?? '',
        ssid: (ap['ssid'] ?? '').toString(),
        apEnabled: (ap['disabled'] ?? '0').toString() != '1',
        channel: channels[dev] ?? 'auto',
        uplinkLocked: activeDevice.isNotEmpty && dev == activeDevice,
      ));
    }
    return radios;
  }

  Future<void> _wifiReload() async {
    await _rpc('file', 'exec', {
      'command': '/sbin/wifi',
      'params': ['reload'],
    });
  }

  /// Enable exactly the broadcast radios in [enabledDevices] (by device id).
  /// Refuses to disable every radio, so the user can't lock themselves out.
  Future<bool> setBroadcastBand(Set<String> enabledDevices) async {
    if (enabledDevices.isEmpty) {
      _error = 'At least one band must stay on.';
      notifyListeners();
      return false;
    }
    _isBusy = true;
    _error = null;
    notifyListeners();
    try {
      for (final r in _broadcast) {
        if (r.apSection.isEmpty) continue;
        await _rpc('uci', 'set', {
          'config': 'wireless',
          'section': r.apSection,
          'values': {'disabled': enabledDevices.contains(r.device) ? '0' : '1'},
        });
      }
      await _rpc('uci', 'commit', {'config': 'wireless'});
      await _wifiReload();
      await load();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }

  /// Set a radio's broadcast channel (`'auto'` or a number). No effect on a
  /// radio locked to the hotel uplink — the UI blocks that case.
  Future<bool> setChannel(String device, String channel) async {
    _isBusy = true;
    _error = null;
    notifyListeners();
    try {
      await _rpc('uci', 'set', {
        'config': 'wireless',
        'section': device, // wifi-device sections are named radio0/radio1
        'values': {'channel': channel},
      });
      await _rpc('uci', 'commit', {'config': 'wireless'});
      await _wifiReload();
      await load();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }

  /// Least-congested channels for a band, ranked best-first, from the last
  /// scan. 2.4 GHz favors non-overlapping 1/6/11; 5 GHz favors empty channels.
  /// Returns an empty list when there's no scan data to reason about.
  List<int> suggestedChannels(int band) {
    final counts = <int, int>{};
    for (final r in _scanResults) {
      if (r.band != band || r.channel <= 0) continue;
      counts[r.channel] = (counts[r.channel] ?? 0) + 1;
    }
    if (counts.isEmpty) return const [];
    if (band == 2) {
      int overlap(int ch) {
        var n = 0;
        counts.forEach((c, k) {
          if ((c - ch).abs() <= 2) n += k; // 2.4GHz channels overlap ±2
        });
        return n;
      }
      return [1, 6, 11]..sort((a, b) => overlap(a).compareTo(overlap(b)));
    }
    return [36, 40, 44, 48, 149, 153, 157, 161]
      ..sort((a, b) => (counts[a] ?? 0).compareTo(counts[b] ?? 0));
  }

  int _nextUplinkIndex(Map<String, dynamic> wirelessValues) {
    var max = 0;
    for (final name in wirelessValues.keys) {
      final m = RegExp(r'^trm_uplink(\d+)$').firstMatch(name);
      if (m != null) {
        final n = int.tryParse(m.group(1)!) ?? 0;
        if (n > max) max = n;
      }
    }
    return max + 1;
  }

  /// Add a new uplink: creates the `wireless.trm_uplinkN` STA interface and a
  /// matching `travelmate.@uplink`, then restarts travelmate to try it.
  Future<bool> addUplink({
    required String ssid,
    required String password,
    required String device,
    required String encryption,
  }) async {
    _isBusy = true;
    _error = null;
    notifyListeners();
    try {
      final wireless = await _rpc('uci', 'get', {'config': 'wireless'});
      final values = (wireless is Map) ? wireless['values'] : null;
      final n = _nextUplinkIndex(
        values is Map ? Map<String, dynamic>.from(values) : const {},
      );
      final section = 'trm_uplink$n';

      final ifaceValues = <String, dynamic>{
        'device': device,
        'mode': 'sta',
        'network': 'travel_wan',
        'ssid': ssid,
        'encryption': encryption,
        'disabled': '0',
      };
      if (encryption != 'none') ifaceValues['key'] = password;

      await _rpc('uci', 'add', {
        'config': 'wireless',
        'type': 'wifi-iface',
        'name': section,
        'values': ifaceValues,
      });
      await _rpc('uci', 'add', {
        'config': 'travelmate',
        'type': 'uplink',
        'values': {'enabled': '1', 'device': device, 'ssid': ssid},
      });
      await _rpc('uci', 'commit', {'config': 'wireless'});
      await _rpc('uci', 'commit', {'config': 'travelmate'});
      await _restart();
      await load();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }
}
