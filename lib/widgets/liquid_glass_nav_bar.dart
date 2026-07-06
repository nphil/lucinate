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
/// iOS 26 / Apple Music: a fully-rounded (stadium) capsule that sits near the
/// bottom edge with content blurring beneath it. The selected item's highlight
/// pill is concentric with the dock (both fully rounded) and evenly inset on all
/// sides so the end items don't crowd the dock's corners.
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

  // Dock geometry. A full stadium (radius == height/2) reads as harmonious with
  // the phone's rounded screen corners. The selection pill is inset [_inset] on
  // every side so it's concentric and evenly spaced from the dock edge.
  static const double _height = 62;
  static const double _inset = 8;
  static const double _gap = 6; // total space between adjacent pills

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_height / 2),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Container(
              height: _height,
              decoration: BoxDecoration(
                color: scheme.surface.withValues(alpha: isDark ? 0.55 : 0.72),
                borderRadius: BorderRadius.circular(_height / 2),
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
    final isFirst = i == 0;
    final isLast = i == items.length - 1;

    // Pill height = dock height minus the top/bottom inset; a stadium radius on
    // it keeps it concentric with the dock.
    final pillRadius = (_height - _inset * 2) / 2;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? () => onDestinationSelected(i) : null,
      child: Padding(
        padding: EdgeInsets.only(
          top: _inset,
          bottom: _inset,
          left: isFirst ? _inset : _gap / 2,
          right: isLast ? _inset : _gap / 2,
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(pillRadius),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                selected ? item.selectedIcon : item.icon,
                color: color,
                size: 25,
              ),
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
      ),
    );
  }
}
