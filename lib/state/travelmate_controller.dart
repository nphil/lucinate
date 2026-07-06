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

  TravelmateStatus _status = TravelmateStatus.empty;
  List<TravelmateUplink> _uplinks = const [];
  List<WifiScanResult> _scanResults = const [];
  bool _loaded = false;
  bool _isLoading = false;
  bool _isBusy = false;
  bool _isScanning = false;
  String? _error;

  TravelmateStatus get status => _status;
  List<TravelmateUplink> get uplinks => _uplinks;
  List<WifiScanResult> get scanResults => _scanResults;
  bool get loaded => _loaded;
  bool get isLoading => _isLoading;
  bool get isBusy => _isBusy;
  bool get isScanning => _isScanning;
  String? get error => _error;

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
      ]);

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
      final byName = <String, WifiScanResult>{};
      for (final device in const ['radio0', 'radio1']) {
        try {
          final res = await _rpc('iwinfo', 'scan', {'device': device});
          final list = (res is Map) ? res['results'] : null;
          if (list is List) {
            for (final entry in list) {
              if (entry is! Map) continue;
              final scan = WifiScanResult.fromIwinfo(
                Map<String, dynamic>.from(entry),
                device,
              );
              if (scan.ssid.isEmpty) continue; // skip hidden networks
              final existing = byName[scan.ssid];
              if (existing == null || scan.signal > existing.signal) {
                byName[scan.ssid] = scan;
              }
            }
          }
        } catch (_) {
          // one radio failing (e.g. busy) shouldn't abort the whole scan
        }
      }
      final merged = byName.values.toList()
        ..sort((a, b) => b.signal.compareTo(a.signal));
      _scanResults = merged;
    } catch (e) {
      _error = e.toString();
    } finally {
      _isScanning = false;
      notifyListeners();
    }
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
