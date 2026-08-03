import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_router.dart';
import 'services/account_bootstrap_service.dart';
import 'services/api_client.dart';
import 'services/call_service.dart';
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
        Supabase.instance.client.auth.onAuthStateChange.listen((data) {
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
        if (path == '/' ||
            path.startsWith('/learn-more') ||
            path.startsWith('/login') ||
            path.startsWith('/signup')) {
          _router.go('/dashboard');
        }
      }
    });
    CallService().onCallAccepted = (callSid, receptionistId, caller) {
      final q = <String, String>{};
      if (receptionistId.isNotEmpty) q['receptionist_id'] = receptionistId;
      if (caller.isNotEmpty) q['caller'] = caller;
      final path = q.isEmpty
          ? '/call/$callSid'
          : '/call/$callSid?${Uri(queryParameters: q).query}';
      _router.go(path);
    };
    PushService().onNavigate = (route) {
      if (route.isEmpty) return;
      _router.go(route);
    };
    _deepLinkHandler.init(
      (msg) {
        _scaffoldKey.currentState?.showSnackBar(SnackBar(content: Text(msg)));
      },
      onGoogleCalendarConnected: _refreshAfterCalendarConnect,
      onAuthSuccess: _afterAuthDeepLink,
    );
  }

  Future<void> _afterAuthDeepLink() async {
    await _accountBootstrapService.ensureCurrentProfile(force: true);
    if (!mounted) return;
    _router.go('/dashboard');
  }

  Future<void> _routePendingPlanIfNeeded() async {
    final pendingPlanId = await PendingPlanService.peekValid();
    if (!mounted || pendingPlanId == null) return;

    final currentPath = _router.routerDelegate.currentConfiguration.uri.path;
    if (currentPath.startsWith('/checkout')) return;

    _router.go('/checkout?plan=${Uri.encodeComponent(pendingPlanId)}');
  }

  Future<void> _refreshAfterCalendarConnect() async {
    if (!mounted) return;
    final uri = _router.routerDelegate.currentConfiguration.uri;
    final path = uri.path;
    if (path == '/onboarding') {
      _router.go('/onboarding?calendar=connected');
    } else if (path.startsWith('/settings')) {
      _router.go('/settings?calendar=connected');
    } else {
      _router.refresh();
    }
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
