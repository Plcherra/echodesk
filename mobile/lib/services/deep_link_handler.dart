import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'api_client.dart';

/// Handles incoming deep links (echodesk://checkout, echodesk://auth-callback).
class DeepLinkHandler {
  final AppLinks _appLinks = AppLinks();

  StreamSubscription<Uri>? _subscription;

  void init(
    void Function(String message) onMessage, {
    Future<void> Function(String? returnTo)? onGoogleCalendarConnected,
    Future<void> Function()? onAuthSuccess,
  }) {
    _subscription = _appLinks.uriLinkStream.listen((uri) {
      _handleUri(uri, onMessage, onGoogleCalendarConnected, onAuthSuccess);
    });

    // Handle cold start (app launched from link)
    _appLinks.getInitialLink().then((uri) {
      if (uri != null) {
        _handleUri(uri, onMessage, onGoogleCalendarConnected, onAuthSuccess);
      }
    });
  }

  void dispose() {
    _subscription?.cancel();
  }

  Future<void> _handleUri(
    Uri uri,
    void Function(String) onMessage,
    Future<void> Function(String? returnTo)? onGoogleCalendarConnected,
    Future<void> Function()? onAuthSuccess,
  ) async {
    if (uri.host == 'checkout') {
      final sessionId = uri.queryParameters['session_id'];
      if (sessionId != null && sessionId.isNotEmpty) {
        if (uri.queryParameters['cancelled'] == '1') {
          onMessage('Checkout cancelled');
          return;
        }
        try {
          final res = await ApiClient.post(
            '/api/mobile/sync-session',
            body: {'session_id': sessionId},
          );
          if (res.statusCode >= 200 && res.statusCode < 300) {
            onMessage('Subscription activated!');
          } else {
            onMessage('Could not sync subscription. Please try again.');
          }
        } catch (_) {
          onMessage('Could not sync subscription. Please try again.');
        }
      }
    } else if (uri.host == 'google-callback') {
      final success = uri.queryParameters['success'];
      final returnTo = uri.queryParameters['return_to'];
      if (success == '1') {
        await onGoogleCalendarConnected?.call(returnTo);
        onMessage('Google Calendar connected!');
      } else {
        final err = uri.queryParameters['error'] ?? 'Connection failed';
        onMessage('Calendar: $err');
      }
    } else if (uri.host == 'auth-callback') {
      // Recover session from confirmation / OAuth / recovery links.
      var recovered = false;
      try {
        await Supabase.instance.client.auth.getSessionFromUrl(uri);
        recovered = Supabase.instance.client.auth.currentSession != null;
      } catch (_) {
        // PKCE email confirm often arrives as ?code=...
        final code = uri.queryParameters['code'];
        if (code != null && code.isNotEmpty) {
          try {
            await Supabase.instance.client.auth.exchangeCodeForSession(code);
            recovered = true;
          } catch (_) {
            // Session may already be present or link may be a bare open-app handoff.
          }
        }
      }
      if (!recovered &&
          Supabase.instance.client.auth.currentSession != null) {
        recovered = true;
      }
      if (uri.queryParameters['type'] == 'recovery') {
        return;
      }
      if (recovered) {
        onMessage('Signed in successfully');
        await onAuthSuccess?.call();
      } else {
        onMessage('Open EchoDesk and sign in with the same email');
      }
    } else if (uri.host == 'settings') {
      onMessage('Billing updated');
    }
  }
}
