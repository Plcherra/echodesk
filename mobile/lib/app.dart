import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'app_router.dart';
import 'services/account_bootstrap_service.dart';
import 'services/api_client.dart';
import 'services/call_service.dart';
import 'services/deep_link_handler.dart';
import 'services/pending_plan_service.dart';

class EchodeskApp extends StatefulWidget {
  const EchodeskApp({super.key});

  @override
  State<EchodeskApp> createState() => _EchodeskAppState();
}

class _EchodeskAppState extends State<EchodeskApp> {
  final DeepLinkHandler _deepLinkHandler = DeepLinkHandler();
  late final AccountBootstrapService _accountBootstrapService;
  final GlobalKey<ScaffoldMessengerState> _scaffoldKey =
      GlobalKey<ScaffoldMessengerState>();
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _router = createAppRouter();
    ApiClient.onUnauthorized = () => _router.go('/login');
    _accountBootstrapService = AccountBootstrapService(
      onProfileReady: _routePendingPlanIfNeeded,
    );
    _accountBootstrapService.init();
    CallService().onCallAccepted = (callSid, receptionistId, caller) {
      final q = <String, String>{};
      if (receptionistId.isNotEmpty) q['receptionist_id'] = receptionistId;
      if (caller.isNotEmpty) q['caller'] = caller;
      final path = q.isEmpty
          ? '/call/$callSid'
          : '/call/$callSid?${Uri(queryParameters: q).query}';
      _router.go(path);
    };
    _deepLinkHandler.init(
      (msg) {
        _scaffoldKey.currentState?.showSnackBar(SnackBar(content: Text(msg)));
      },
      onGoogleCalendarConnected: _refreshAfterCalendarConnect,
    );
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
    _deepLinkHandler.dispose();
    _accountBootstrapService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      scaffoldMessengerKey: _scaffoldKey,
      title: 'Echodesk',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      routerConfig: _router,
    );
  }
}
