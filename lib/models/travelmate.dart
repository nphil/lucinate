/// Models for the Travelmate module.
///
/// Data sources on the router:
///   - `uci get travelmate`  -> global settings + `@uplink` (saved uplinks)
///   - `file read /var/run/travelmate/travelmate.runtime.json` -> live status
///   - `iwinfo scan {device}` -> nearby networks
library;

import 'dart:convert';

/// Maps a numeric Wi-Fi band (2/5/6) to a human-friendly label.
String bandLabelFor(int band) {
  switch (band) {
    case 2:
      return '2.4 GHz';
    case 5:
      return '5 GHz';
    case 6:
      return '6 GHz';
    default:
      return band > 0 ? '$band GHz' : '';
  }
}

class TravelmateStatus {
  /// From `travelmate.global.trm_enabled`.
  final bool enabled;

  /// Raw status text, e.g. `"connected, net ok/72"` or `"error"`/``.
  final String statusText;

  /// SSID of the currently active uplink (parsed from `station_id`).
  final String activeSsid;

  /// Radio backing the active uplink (e.g. `radio0`).
  final String activeDevice;

  /// A captive portal was detected on the active uplink.
  final bool captive;

  final String subnet;

  const TravelmateStatus({
    required this.enabled,
    required this.statusText,
    required this.activeSsid,
    required this.activeDevice,
    required this.captive,
    required this.subnet,
  });

  bool get isConnected => statusText.toLowerCase().startsWith('connected');

  /// Builds status from the raw string held in `file.read`'s `data` field.
  factory TravelmateStatus.fromRuntime(
    String rawData, {
    required bool enabled,
  }) {
    try {
      final outer = jsonDecode(rawData);
      final d = (outer is Map) ? outer['data'] : null;
      if (d is Map) {
        final station = (d['station_id'] ?? '').toString(); // radio0/SSID/bssid
        final parts = station.split('/');
        final device = parts.isNotEmpty ? parts[0].trim() : '';
        var ssid = parts.length > 1 ? parts[1].trim() : '';
        if (ssid == '-') ssid = '';
        final statusText = (d['travelmate_status'] ?? '').toString();
        final lowerStatus = statusText.toLowerCase();
        final connected = lowerStatus.startsWith('connected');
        // A captive portal shows up as the connectivity check failing
        // ("net nok") or an explicit "captive" state — NOT the run_flags
        // "captive: ✔", which only means captive DETECTION is enabled. When the
        // status reports "net ok", the internet works and there is no portal.
        final captive = connected &&
            (lowerStatus.contains('captive') || lowerStatus.contains('nok'));
        return TravelmateStatus(
          enabled: enabled,
          statusText: statusText,
          activeSsid: ssid,
          activeDevice: device == '-' ? '' : device,
          captive: captive,
          subnet: (d['station_subnet'] ?? '').toString(),
        );
      }
    } catch (_) {
      // fall through to a minimal status
    }
    return TravelmateStatus(
      enabled: enabled,
      statusText: '',
      activeSsid: '',
      activeDevice: '',
      captive: false,
      subnet: '',
    );
  }

  static const empty = TravelmateStatus(
    enabled: false,
    statusText: '',
    activeSsid: '',
    activeDevice: '',
    captive: false,
    subnet: '',
  );
}

class TravelmateUplink {
  /// The travelmate uci section id (anonymous, e.g. `cfg0254f8`).
  final String sectionId;
  final String ssid;
  final String device;
  final bool enabled;

  const TravelmateUplink({
    required this.sectionId,
    required this.ssid,
    required this.device,
    required this.enabled,
  });

  factory TravelmateUplink.fromUci(String sectionId, Map<String, dynamic> s) {
    return TravelmateUplink(
      sectionId: sectionId,
      ssid: (s['ssid'] ?? '').toString(),
      device: (s['device'] ?? '').toString(),
      enabled: (s['enabled'] ?? '1').toString() == '1',
    );
  }
}

class WifiScanResult {
  final String ssid;
  final String bssid;

  /// The radio we scanned on (`radio0`/`radio1`).
  final String device;
  final int signal; // dBm
  final int quality;
  final int qualityMax;
  final bool encrypted;

  /// uci `encryption` value to use when adding this as an uplink.
  final String encryption;
  final int band; // 2 or 5

  const WifiScanResult({
    required this.ssid,
    required this.bssid,
    required this.device,
    required this.signal,
    required this.quality,
    required this.qualityMax,
    required this.encrypted,
    required this.encryption,
    required this.band,
  });

  int get qualityPercent =>
      qualityMax > 0 ? ((quality * 100) / qualityMax).round() : 0;

  /// Human-friendly band, e.g. `2.4 GHz` / `5 GHz`.
  String get bandLabel => bandLabelFor(band);

  factory WifiScanResult.fromIwinfo(Map<String, dynamic> j, String device) {
    int asInt(dynamic v) => v is num ? v.toInt() : 0;
    final enc = j['encryption'];
    return WifiScanResult(
      ssid: (j['ssid'] ?? '').toString(),
      bssid: (j['bssid'] ?? '').toString(),
      device: device,
      signal: asInt(j['signal']),
      quality: asInt(j['quality']),
      qualityMax: j['quality_max'] is num ? asInt(j['quality_max']) : 70,
      encrypted: enc is Map && enc['enabled'] == true,
      encryption: _mapEncryption(enc),
      band: asInt(j['band']),
    );
  }

  /// Maps an iwinfo `encryption` object to a uci `encryption` option value.
  static String _mapEncryption(dynamic enc) {
    if (enc is! Map || enc['enabled'] != true) return 'none';
    final auth = enc['authentication'];
    final hasSae = auth is List && auth.contains('sae');
    final hasPsk = auth is List && auth.contains('psk');
    if (hasSae && hasPsk) return 'sae-mixed';
    if (hasSae) return 'sae';
    if (hasPsk) return 'psk2';
    final wpa = enc['wpa'];
    if (wpa is List && wpa.contains(1)) return 'psk';
    return 'psk2';
  }
}
