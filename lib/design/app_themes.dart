import 'package:flutter/material.dart';

/// A selectable color palette. Each maps to a Material 3 [ColorScheme] generated
/// from a signature accent (seed) colour, so choosing one recolours the whole
/// app cohesively. Names reference well-known developer palettes.
class AppTheme {
  final String id;
  final String name;
  final Brightness brightness;
  final Color seed;

  const AppTheme({
    required this.id,
    required this.name,
    required this.brightness,
    required this.seed,
  });

  ColorScheme get colorScheme =>
      ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
}

class AppThemes {
  const AppThemes._();

  /// 10 light palettes.
  static const List<AppTheme> light = [
    AppTheme(id: 'tokyo_day', name: 'Tokyo Day', brightness: Brightness.light, seed: Color(0xFF2E7DE9)),
    AppTheme(id: 'latte', name: 'Catppuccin Latte', brightness: Brightness.light, seed: Color(0xFF8839EF)),
    AppTheme(id: 'rose_pine_dawn', name: 'Rosé Pine Dawn', brightness: Brightness.light, seed: Color(0xFFB4637A)),
    AppTheme(id: 'gruvbox_light', name: 'Gruvbox Light', brightness: Brightness.light, seed: Color(0xFFD65D0E)),
    AppTheme(id: 'nord_light', name: 'Nord Frost', brightness: Brightness.light, seed: Color(0xFF5E81AC)),
    AppTheme(id: 'everforest_light', name: 'Everforest Light', brightness: Brightness.light, seed: Color(0xFF8DA101)),
    AppTheme(id: 'solarized_light', name: 'Solarized Light', brightness: Brightness.light, seed: Color(0xFF268BD2)),
    AppTheme(id: 'ayu_light', name: 'Ayu Light', brightness: Brightness.light, seed: Color(0xFFFF9940)),
    AppTheme(id: 'one_light', name: 'One Light', brightness: Brightness.light, seed: Color(0xFF4078F2)),
    AppTheme(id: 'sakura_light', name: 'Sakura', brightness: Brightness.light, seed: Color(0xFFEA76CB)),
  ];

  /// 10 dark palettes.
  static const List<AppTheme> dark = [
    AppTheme(id: 'mocha', name: 'Catppuccin Mocha', brightness: Brightness.dark, seed: Color(0xFFCBA6F7)),
    AppTheme(id: 'dracula', name: 'Dracula', brightness: Brightness.dark, seed: Color(0xFFBD93F9)),
    AppTheme(id: 'nord', name: 'Nord', brightness: Brightness.dark, seed: Color(0xFF88C0D0)),
    AppTheme(id: 'tokyo_night', name: 'Tokyo Night', brightness: Brightness.dark, seed: Color(0xFF7AA2F7)),
    AppTheme(id: 'gruvbox_dark', name: 'Gruvbox Dark', brightness: Brightness.dark, seed: Color(0xFFFE8019)),
    AppTheme(id: 'rose_pine', name: 'Rosé Pine', brightness: Brightness.dark, seed: Color(0xFFEBBCBA)),
    AppTheme(id: 'one_dark', name: 'One Dark', brightness: Brightness.dark, seed: Color(0xFF61AFEF)),
    AppTheme(id: 'solarized_dark', name: 'Solarized Dark', brightness: Brightness.dark, seed: Color(0xFF2AA198)),
    AppTheme(id: 'everforest_dark', name: 'Everforest Dark', brightness: Brightness.dark, seed: Color(0xFFA7C080)),
    AppTheme(id: 'monokai', name: 'Monokai', brightness: Brightness.dark, seed: Color(0xFFFF6188)),
  ];

  static const String defaultLightId = 'tokyo_day';
  static const String defaultDarkId = 'mocha';

  static AppTheme lightById(String? id) => light.firstWhere(
        (t) => t.id == id,
        orElse: () => light.firstWhere((t) => t.id == defaultLightId),
      );

  static AppTheme darkById(String? id) => dark.firstWhere(
        (t) => t.id == id,
        orElse: () => dark.firstWhere((t) => t.id == defaultDarkId),
      );
}
