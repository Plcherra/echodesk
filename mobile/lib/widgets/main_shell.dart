import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Exposes the active bottom-nav tab index so tab screens can refresh on focus.
class MainShellTabIndex extends InheritedWidget {
  final int index;

  const MainShellTabIndex({
    super.key,
    required this.index,
    required super.child,
  });

  static int of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<MainShellTabIndex>();
    assert(scope != null, 'MainShellTabIndex not found in context');
    return scope!.index;
  }

  static int? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<MainShellTabIndex>()
        ?.index;
  }

  @override
  bool updateShouldNotify(MainShellTabIndex oldWidget) =>
      index != oldWidget.index;
}

/// Shell scaffold with bottom navigation bar for the main app tabs.
/// Wraps Dashboard, Receptionists, Appointments, and Settings.
class MainShell extends StatelessWidget {
  const MainShell({
    super.key,
    required this.navigationShell,
  });

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return MainShellTabIndex(
      index: navigationShell.currentIndex,
      child: Scaffold(
        body: navigationShell,
        bottomNavigationBar: NavigationBar(
          selectedIndex: navigationShell.currentIndex,
          onDestinationSelected: (int index) => navigationShell.goBranch(
            index,
            initialLocation: index == navigationShell.currentIndex,
          ),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard),
              label: 'Dashboard',
            ),
            NavigationDestination(
              icon: Icon(Icons.support_agent_outlined),
              selectedIcon: Icon(Icons.support_agent),
              label: 'Receptionists',
            ),
            NavigationDestination(
              icon: Icon(Icons.event_outlined),
              selectedIcon: Icon(Icons.event),
              label: 'Appointments',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}
