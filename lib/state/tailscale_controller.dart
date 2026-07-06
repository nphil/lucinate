import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:luci_mobile/main.dart';
import 'package:luci_mobile/models/tailscale.dart';

/// Owns the Tailscale module's state. Kept separate from the large [AppState]
/// so the feature is self-contained; it borrows the authenticated RPC channel
/// via [AppState.rpcCall].
final tailscaleControllerProvider = ChangeNotifierProvider<TailscaleController>(
  (ref) => TailscaleController(ref),
);

class TailscaleController extends ChangeNotifier {
  TailscaleController(this._ref);

  final Ref _ref;

  TailscaleStatus _status = TailscaleStatus.empty;
  TailscaleSettings _settings = TailscaleSettings.empty;
  bool _loaded = false;
  bool _isLoading = false;
  bool _isBusy = false;
  String? _error;

  TailscaleStatus get status => _status;
  TailscaleSettings get settings => _settings;
  bool get loaded => _loaded;
  bool get isLoading => _isLoading;

  /// A write (set_settings) is in flight — used to disable toggles.
  bool get isBusy => _isBusy;
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
        _rpc('tailscale', 'get_status'),
        _rpc('tailscale', 'get_settings'),
      ]);
      final statusData = results[0];
      final settingsData = results[1];
      if (statusData is Map) {
        _status = TailscaleStatus.fromJson(
          Map<String, dynamic>.from(statusData),
        );
      }
      if (settingsData is Map) {
        _settings = TailscaleSettings.fromJson(
          Map<String, dynamic>.from(settingsData),
        );
      }
      _loaded = true;
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  String get _currentExitNodeIp => _status.currentExitNode?.ip ?? '';

  Future<bool> _apply(Map<String, dynamic> formData) async {
    _isBusy = true;
    _error = null;
    notifyListeners();
    try {
      final res = await _rpc('tailscale', 'set_settings', {
        'form_data': formData,
      });
      if (res is Map && res['error'] != null) {
        _error = res['error'].toString();
        notifyListeners();
        return false;
      }
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

  /// Flip a single boolean setting (e.g. `accept_routes`, `shields_up`,
  /// `disable_magic_dns`, `advertise_exit_node`), preserving everything else.
  Future<bool> setFlag(String key, bool value) {
    final data = _settings.toFormData(
      exitNodeIp: _currentExitNodeIp,
      overrides: {key: value ? '1' : '0'},
    );
    return _apply(data);
  }

  /// Select an exit node by IP, or pass null/'' to clear it.
  Future<bool> setExitNode(String? ip) {
    final target = ip ?? '';
    final data = _settings.toFormData(
      exitNodeIp: target,
      overrides: {'exit_node': target},
    );
    return _apply(data);
  }
}
