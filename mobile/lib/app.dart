import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_router.dart';
import 'config/purchases.dart';
import 'services/apple_iap_service.dart';
import 'services/account_bootstrap_service.dart';
import 'services/api_client.dart';
import 'services/deep_link_handler.dart';
import 'services/pending_plan_service.dart';
import 'services/push_service.dart';
import 'theme/echodesk_theme.dart';
import 'utils/go_router_refresh.dart';

class EchodeskApp extends StatefulWidget {
  const EchodeskApp({super.key});

  @override
  State<EchodeskApp> createState() => _EchodeskAppState();
}

class _EchodeskAppState extends State<EchodeskApp> {
  final DeepLinkHandler _deepLinkHandler = DeepLinkHandler();
  late final AccountBootstrapService _accountBootstrapService;
  late final GoRouterRefreshStream _authRefresh;
  StreamSubscription<AuthState>? _authSubscription;
  final GlobalKey<ScaffoldMessengerState> _scaffoldKey =
      GlobalKey<ScaffoldMessengerState>();
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _authRefresh = GoRouterRefreshStream(
      Supabase.instance.client.auth.onAuthStateChange,
    );
    _router = createAppRouter(refreshListenable: _authRefresh);
    ApiClient.onUnauthorized = () => _router.go('/login');
    _accountBootstrapService = AccountBootstrapService(
      onProfileReady: _routePendingPlanIfNeeded,
    );
    _accountBootstrapService.init();
    _authSubscription =
        Supabase.instance.client.auth.onAuthStateChange.listen((data) async {
      if (data.event == AuthChangeEvent.passwordRecovery) {
        _router.go('/reset-password');
        return;
      }
      // After email confirm / OAuth deep link, leave welcome and continue setup.
      if (data.session != null &&
          (data.event == AuthChangeEvent.signedIn ||
              data.event == AuthChangeEvent.tokenRefreshed ||
              data.event == AuthChangeEvent.initialSession)) {
        final path = _router.routerDelegate.currentConfiguration.uri.path;
        if (_isAuthEntryPath(path)) {
          final home = await _homeAfterAuth();
          if (!mounted) return;
          // A notification may have opened a call while this lookup ran.
          final now = _router.routerDelegate.currentConfiguration.uri.path;
          if (_isAuthEntryPath(now)) {
            _router.go(home);
          }
        }
      }
    });
    PushService().onNavigate = (route) {
      if (route.isEmpty) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _router.go(route);
      });
    };
    if (applePurchasesEnabled) {
      AppleIapService.instance.ensureListening();
    }
    _deepLinkHandler.init(
      (msg) {
        _scaffoldKey.currentState?.showSnackBar(SnackBar(content: Text(msg)));
      },
      onGoogleCalendarConnected: _refreshAfterCalendarConnect,
      onAuthSuccess: _afterAuthDeepLink,
    );
  }

  bool _isAuthEntryPath(String path) {
    return path == '/' ||
        path.startsWith('/learn-more') ||
        path.startsWith('/login') ||
        path.startsWith('/signup');
  }

  Future<bool> _isOnboardingComplete() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return false;
    try {
      final res = await Supabase.instance.client
          .from('users')
          .select('onboarding_completed_at')
          .eq('id', user.id)
          .maybeSingle();
      return ((res?['onboarding_completed_at'] as String?) ?? '')
          .trim()
          .isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<String> _homeAfterAuth() async {
    if (await _isOnboardingComplete()) return '/dashboard';
    return '/onboarding';
  }

  Future<void> _afterAuthDeepLink() async {
    await _accountBootstrapService.ensureCurrentProfile(force: true);
    if (!mounted) return;
    _router.go(await _homeAfterAuth());
  }

  Future<void> _routePendingPlanIfNeeded() async {
    if (stripePurchasesEnabled) {
      final pendingPlanId = await PendingPlanService.peekValid();
      if (!mounted || pendingPlanId == null) return;

      final currentPath = _router.routerDelegate.currentConfiguration.uri.path;
      if (currentPath.startsWith('/checkout')) return;

      _router.go('/checkout?plan=${Uri.encodeComponent(pendingPlanId)}');
      return;
    }
    await PendingPlanService.clear();
  }

  Future<void> _refreshAfterCalendarConnect(String? returnTo) async {
    if (!mounted) return;
    final path = _router.routerDelegate.currentConfiguration.uri.path;

    if (returnTo == 'settings' || path.startsWith('/settings')) {
      _router.go('/settings?calendar=connected');
      return;
    }

    // First-run calendar OAuth often resumes from Safari onto `/` or `/dashboard`.
    // Always send incomplete accounts back into onboarding (assistant step).
    final onboardingDone = await _isOnboardingComplete();
    if (!onboardingDone ||
        returnTo == 'onboarding' ||
        path == '/onboarding') {
      _router.go('/onboarding?calendar=connected');
      return;
    }

    _router.refresh();
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _authRefresh.dispose();
    _deepLinkHandler.dispose();
    _accountBootstrapService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      scaffoldMessengerKey: _scaffoldKey,
      title: 'EchoDesk',
      theme: EchoDeskTheme.light(),
      routerConfig: _router,
    );
  }
}
