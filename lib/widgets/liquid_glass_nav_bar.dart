import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

class GlassNavItem {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  const GlassNavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });
}

/// A floating, translucent "liquid glass" bottom navigation bar, styled after
/// iOS 26 / Apple Music: a rounded capsule that sits near the bottom edge with
/// content blurring beneath it, larger tap targets, and the selected item
/// highlighted with the theme's accent colour.
class LiquidGlassNavBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<GlassNavItem> items;

  /// Return false to disable a tab (e.g. while the router is rebooting).
  final bool Function(int index)? isEnabled;

  const LiquidGlassNavBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.items,
    this.isEnabled,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(30),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Container(
              height: 66,
              decoration: BoxDecoration(
                color: scheme.surface.withValues(alpha: isDark ? 0.55 : 0.72),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(
                  color: (isDark ? Colors.white : Colors.black)
                      .withValues(alpha: 0.12),
                  width: 0.8,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Row(
                children: [
                  for (int i = 0; i < items.length; i++)
                    Expanded(child: _item(context, i, scheme)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _item(BuildContext context, int i, ColorScheme scheme) {
    final selected = i == selectedIndex;
    final enabled = isEnabled?.call(i) ?? true;
    final color = !enabled
        ? scheme.onSurfaceVariant.withValues(alpha: 0.35)
        : (selected ? scheme.primary : scheme.onSurfaceVariant);
    final item = items[i];

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? () => onDestinationSelected(i) : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        margin: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(selected ? item.selectedIcon : item.icon, color: color, size: 26),
            const SizedBox(height: 2),
            Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
