import 'package:flutter/cupertino.dart' show CupertinoScrollBehavior;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:luci_mobile/state/app_state.dart';
import 'package:luci_mobile/screens/login_screen.dart';
import 'package:luci_mobile/screens/main_screen.dart';
import 'package:luci_mobile/screens/settings_screen.dart';
import 'package:luci_mobile/screens/splash_screen.dart';

void main() {
  runApp(ProviderScope(child: const LuCIApp()));
}

final appStateProvider = ChangeNotifierProvider<AppState>(
  (ref) => AppState.instance,
);

class LuCIApp extends ConsumerWidget {
  const LuCIApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appState = ref.watch(appStateProvider);
    return MaterialApp(
      title: 'Lucinate',
      // iOS-native scroll feel everywhere: rubber-band bounce, no Android
      // overscroll glow, Cupertino scrollbar behaviour.
      scrollBehavior: const _IOSScrollBehavior(),
      theme: _buildTheme(appState.lightColorScheme),
      darkTheme: _buildTheme(appState.darkColorScheme),
      themeMode: appState.themeMode,
      initialRoute: '/splash',
      routes: {
        '/splash': (context) => const SplashScreen(),
        '/login': (context) => const LoginScreen(),
        '/': (context) => const MainScreen(),
        '/settings': (context) => const SettingsScreen(),
      },
    );
  }
}

ThemeData _buildTheme(ColorScheme scheme) {
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    // Force iOS behaviours (Cupertino page transitions, adaptive controls) and
    // drop the Material ink ripple — the biggest "this isn't iOS" tell on taps.
    platform: TargetPlatform.iOS,
    splashFactory: NoSplash.splashFactory,
    // Edge-to-edge display handled natively in MainActivity
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
  );
}

/// iOS-style scrolling on every platform: bouncing physics, no overscroll glow,
/// and the Cupertino scrollbar. Widens drag devices so it also works under a
/// desktop debugger.
class _IOSScrollBehavior extends CupertinoScrollBehavior {
  const _IOSScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };
}
