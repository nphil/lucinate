import 'package:flutter/material.dart';
import 'package:luci_mobile/services/interfaces/api_service_interface.dart';
import 'package:luci_mobile/services/api_service.dart';
import 'package:luci_mobile/services/secure_storage_service.dart';
import 'package:luci_mobile/services/interfaces/auth_service_interface.dart';
import 'package:luci_mobile/utils/logger.dart';

class RealAuthService implements IAuthService {
  final SecureStorageService _secureStorageService = SecureStorageService();
  final IApiService _apiService;

  String? _sysauth;
  String? _ipAddress;
  bool _useHttps = false;

  RealAuthService(this._apiService);

  @override
  String? get sysauth => _sysauth;
  @override
  String? get ipAddress => _ipAddress;
  @override
  bool get useHttps => _useHttps;
  @override
  bool get isAuthenticated => _sysauth != null;

  @override
  Future<void> login(
    String ipAddress,
    String username,
    String password,
    bool useHttps, {
    BuildContext? context,
  }) async {
    await _login(ipAddress, username, password, useHttps, context: context);
  }

  Future<bool> _login(
    String ip,
    String user,
    String pass,
    bool useHttps, {
    BuildContext? context,
  }) async {
    // Retry transient network failures (common on flaky hotel Wi-Fi / Tailscale
    // links) so auto-login on resume doesn't drop to the login screen for a
    // momentary blip. Credential rejection (server reached, no token) is NOT
    // retried, so a wrong password still fails fast.
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future.delayed(Duration(milliseconds: 500 * attempt));
      }
      try {
        // Check if the API service is RealApiService to use protocol detection
        if (_apiService is RealApiService) {
          final realApiService = _apiService;
          final loginResult = await realApiService.loginWithProtocolDetection(
            ip,
            user,
            pass,
            useHttps,
            // ignore: use_build_context_synchronously
            context: context,
          );

          if (loginResult.token != null) {
            _sysauth = loginResult.token;
            _ipAddress = ip;
            _useHttps = loginResult.actualUseHttps; // Use the detected protocol

            await _secureStorageService.saveCredentials(
              ipAddress: ip,
              username: user,
              password: pass,
              useHttps: loginResult.actualUseHttps, // Save the detected protocol
            );

            if (loginResult.actualUseHttps != useHttps) {
              Logger.info(
                'Protocol changed from ${useHttps ? "HTTPS" : "HTTP"} to ${loginResult.actualUseHttps ? "HTTPS" : "HTTP"} due to redirect',
              );
            }

            return true;
          }
          // Reached the server but got no token -> credentials rejected.
          return false;
        } else {
          // Fallback for mock service
          final token = await _apiService.login(
            ip,
            user,
            pass,
            useHttps,
            // ignore: use_build_context_synchronously
            context: context,
          );
          _sysauth = token;
          _ipAddress = ip;
          _useHttps = useHttps;

          await _secureStorageService.saveCredentials(
            ipAddress: ip,
            username: user,
            password: pass,
            useHttps: useHttps,
          );

          return true;
        }
      } catch (e) {
        // Network/transient error -> back off and retry before giving up.
        Logger.warning('Login attempt ${attempt + 1}/3 failed: $e');
        if (attempt == 2) return false;
      }
    }
    return false;
  }

  @override
  Future<bool> tryAutoLogin(
    String? ipAddress,
    String? username,
    String? password,
    bool? useHttps, {
    BuildContext? context,
  }) async {
    if (ipAddress != null &&
        username != null &&
        password != null &&
        useHttps != null) {
      return await _login(
        ipAddress,
        username,
        password,
        useHttps,
        context: context,
      );
    }
    return await _tryAutoLoginFromStorage(context: context);
  }

  Future<bool> _tryAutoLoginFromStorage({BuildContext? context}) async {
    final credentials = await _secureStorageService.getCredentials();
    final ip = credentials['ipAddress'];
    final user = credentials['username'];
    final pass = credentials['password'];
    final useHttps = credentials['useHttps'] == 'true';

    if (ip != null && user != null && pass != null) {
      return await _login(
        ip,
        user,
        pass,
        useHttps,
        context: context?.mounted == true ? context : null,
      );
    }

    return false;
  }

  @override
  Future<void> logout() async {
    _sysauth = null;
    _ipAddress = null;
    _useHttps = false;
    await _secureStorageService.clearCredentials();
  }

  @override
  Future<bool> checkRouterAvailability(
    String ipAddress,
    bool useHttps, {
    BuildContext? context,
  }) async {
    if (ipAddress.isEmpty) return false;

    try {
      final result = await _apiService.call(
        ipAddress,
        '',
        useHttps,
        object: 'system',
        method: 'board',
        params: {},
        context: context,
      );
      return result != null;
    } catch (e) {
      return false;
    }
  }
}
