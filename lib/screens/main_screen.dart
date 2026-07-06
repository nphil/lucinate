import 'package:flutter/material.dart';
import 'package:luci_mobile/screens/dashboard_screen.dart';
import 'package:luci_mobile/screens/clients_screen.dart';
import 'package:luci_mobile/screens/interfaces_screen.dart';
import 'package:luci_mobile/screens/more_screen.dart';
import 'package:luci_mobile/main.dart';
import 'package:luci_mobile/widgets/luci_navigation_enhancements.dart';
import 'package:luci_mobile/widgets/liquid_glass_nav_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class MainScreen extends ConsumerStatefulWidget {
  final int? initialTab;
  final String? interfaceToScroll;

  const MainScreen({super.key, this.initialTab, this.interfaceToScroll});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> {
  int _selectedIndex = 0;
  String? _currentInterfaceToScroll;

  @override
  void initState() {
    super.initState();
    if (widget.initialTab != null) {
      _selectedIndex = widget.initialTab!;
    }
    _currentInterfaceToScroll = widget.interfaceToScroll;
  }

  @override
  void didUpdateWidget(MainScreen oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Handle parameter changes (important for iOS navigation)
    if (widget.interfaceToScroll != oldWidget.interfaceToScroll) {
      _currentInterfaceToScroll = widget.interfaceToScroll;
    }

    // Handle initial tab changes
    if (widget.initialTab != oldWidget.initialTab &&
        widget.initialTab != null) {
      _selectedIndex = widget.initialTab!;
    }
  }

  void _clearInterfaceToScroll() {
    if (_currentInterfaceToScroll != null) {
      setState(() {
        _currentInterfaceToScroll = null;
      });
    }
  }

  List<Widget> get _widgetOptions => [
    const DashboardScreen(),
    const ClientsScreen(),
    InterfacesScreen(
      scrollToInterface: _currentInterfaceToScroll,
      onScrollComplete: _clearInterfaceToScroll,
    ),
    const MoreScreen(),
  ];

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });

    // Clear interface scroll state when navigating away from Interfaces tab
    if (_selectedIndex != 2 && _currentInterfaceToScroll != null) {
      _clearInterfaceToScroll();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Listen for requestedTab in AppState
    final appState = ref.watch(appStateProvider);
    if (appState.requestedTab != null &&
        appState.requestedTab != _selectedIndex) {
      // Store the values before the callback to avoid null reference issues
      final requestedTab = appState.requestedTab!;
      final requestedInterface = appState.requestedInterfaceToScroll;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() {
          _selectedIndex = requestedTab;
          // Update interface to scroll if provided
          if (requestedInterface != null) {
            _currentInterfaceToScroll = requestedInterface;
          }
        });
        appState.requestedTab = null;
        appState.requestedInterfaceToScroll = null;
      });
    }
    return Scaffold(
      extendBody: true,
      body: Center(
        child: LuciTabTransition(
          transitionKey: 'tab_$_selectedIndex',
          child: _widgetOptions.elementAt(_selectedIndex),
        ),
      ),
      bottomNavigationBar: Builder(
        builder: (context) {
          final isRebooting = ref.watch(
            appStateProvider.select((state) => state.isRebooting),
          );
          return LiquidGlassNavBar(
            selectedIndex: _selectedIndex,
            isEnabled: (index) => !isRebooting || index == 3,
            onDestinationSelected: (index) {
              if (isRebooting && index != 3) return; // Only 'Settings' allowed
              _onItemTapped(index);
            },
            items: const [
              GlassNavItem(
                icon: Icons.dashboard_outlined,
                selectedIcon: Icons.dashboard,
                label: 'Dashboard',
              ),
              GlassNavItem(
                icon: Icons.people_outline,
                selectedIcon: Icons.people,
                label: 'Clients',
              ),
              GlassNavItem(
                icon: Icons.lan_outlined,
                selectedIcon: Icons.lan,
                label: 'Interfaces',
              ),
              GlassNavItem(
                icon: Icons.settings_outlined,
                selectedIcon: Icons.settings,
                label: 'Settings',
              ),
            ],
          );
        },
      ),
    );
  }
}
