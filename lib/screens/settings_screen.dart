import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:luci_mobile/design/app_themes.dart';
import 'package:luci_mobile/main.dart';
import 'package:luci_mobile/widgets/luci_app_bar.dart';
import 'package:luci_mobile/screens/dashboard_settings_list_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  void _showReviewerModeResetDialog(BuildContext context, WidgetRef ref) {
    final appState = ref.read(appStateProvider);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Exit Reviewer Mode?'),
        content: const Text(
          'This will disable reviewer mode and return to normal authentication. '
          'You will need to log in with real router credentials.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await appState.setReviewerMode(false);
              appState.logout();
              if (context.mounted) {
                unawaited(
                  Navigator.of(
                    context,
                  ).pushNamedAndRemoveUntil('/login', (route) => false),
                );
              }
            },
            child: const Text('Exit'),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _paletteGrid(
    BuildContext context, {
    required List<AppTheme> themes,
    required String selectedId,
    required ValueChanged<String> onSelect,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: themes
            .map(
              (t) => _PaletteSwatch(
                theme: t,
                selected: t.id == selectedId,
                onTap: () => onSelect(t.id),
              ),
            )
            .toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appState = ref.watch(appStateProvider);
    return Scaffold(
      appBar: const LuciAppBar(title: 'App Customization', showBack: true),
      body: ListView(
        padding: const EdgeInsets.only(top: 4, bottom: 120),
        children: [
          _sectionHeader(context, 'Appearance'),
          RadioGroup<ThemeMode>(
            groupValue: appState.themeMode,
            onChanged: (mode) {
              if (mode != null) appState.setThemeMode(mode);
            },
            child: Column(
              children: [
                RadioListTile<ThemeMode>(
                  title: const Text('System Default'),
                  value: ThemeMode.system,
                ),
                RadioListTile<ThemeMode>(
                  title: const Text('Light'),
                  value: ThemeMode.light,
                ),
                RadioListTile<ThemeMode>(
                  title: const Text('Dark'),
                  value: ThemeMode.dark,
                ),
              ],
            ),
          ),

          _sectionHeader(context, 'Light Palette'),
          _paletteGrid(
            context,
            themes: AppThemes.light,
            selectedId: appState.lightThemeId,
            onSelect: appState.setLightTheme,
          ),

          _sectionHeader(context, 'Dark Palette'),
          _paletteGrid(
            context,
            themes: AppThemes.dark,
            selectedId: appState.darkThemeId,
            onSelect: appState.setDarkTheme,
          ),

          const Divider(height: 40),
          _sectionHeader(context, 'Dashboard'),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.dashboard_customize,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                  size: 24,
                ),
              ),
              title: const Text(
                'Customize Dashboard',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: const Text(
                'Configure interface visibility and throughput monitoring',
              ),
              trailing: Icon(
                Icons.arrow_forward_ios,
                size: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const DashboardSettingsListScreen(),
                  ),
                );
              },
            ),
          ),

          if (appState.reviewerModeEnabled) ...[
            const Divider(height: 40),
            _sectionHeader(context, 'Reviewer Mode'),
            const ListTile(
              leading: Icon(Icons.info_outline, color: Colors.orange),
              title: Text('Reviewer Mode Active'),
              subtitle: Text('Mock data is being used for demonstration'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: FilledButton.icon(
                onPressed: () => _showReviewerModeResetDialog(context, ref),
                icon: const Icon(Icons.exit_to_app),
                label: const Text('Exit Reviewer Mode'),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A tappable palette preview: the theme's surface with primary/secondary/
/// tertiary dots, ringed and check-badged when selected.
class _PaletteSwatch extends StatelessWidget {
  final AppTheme theme;
  final bool selected;
  final VoidCallback onTap;

  const _PaletteSwatch({
    required this.theme,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    final activeScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 96,
      child: Column(
        children: [
          GestureDetector(
            onTap: onTap,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 96,
                  height: 58,
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: selected
                          ? activeScheme.primary
                          : activeScheme.outlineVariant,
                      width: selected ? 3 : 1.5,
                    ),
                  ),
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _dot(scheme.primary),
                        _dot(scheme.secondary),
                        _dot(scheme.tertiary),
                      ],
                    ),
                  ),
                ),
                if (selected)
                  Positioned(
                    top: -6,
                    right: -6,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: activeScheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: activeScheme.surface, width: 2),
                      ),
                      child: Icon(
                        Icons.check,
                        size: 12,
                        color: activeScheme.onPrimary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            theme.name,
            maxLines: 2,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              color: selected
                  ? activeScheme.primary
                  : activeScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _dot(Color color) {
    return Container(
      width: 15,
      height: 15,
      margin: const EdgeInsets.symmetric(horizontal: 2.5),
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
