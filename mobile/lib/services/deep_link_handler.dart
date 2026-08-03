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
    Future<void> Function()? onGoogleCalendarConnected,
  }) {
    _subscription = _appLinks.uriLinkStream.listen((uri) {
      _handleUri(uri, onMessage, onGoogleCalendarConnected);
    });

    // Handle cold start (app launched from link)
    _appLinks.getInitialLink().then((uri) {
      if (uri != null) _handleUri(uri, onMessage, onGoogleCalendarConnected);
    });
  }

  void dispose() {
    _subscription?.cancel();
  }

  Future<void> _handleUri(
    Uri uri,
    void Function(String) onMessage,
    Future<void> Function()? onGoogleCalendarConnected,
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
      if (success == '1') {
        await onGoogleCalendarConnected?.call();
        onMessage('Google Calendar connected!');
      } else {
        final err = uri.queryParameters['error'] ?? 'Connection failed';
        onMessage('Calendar: $err');
      }
    } else if (uri.host == 'auth-callback') {
      // Recover session from confirmation / OAuth / recovery links.
      try {
        await Supabase.instance.client.auth.getSessionFromUrl(uri);
      } catch (_) {
        // PKCE email confirm often arrives as ?code=...
        final code = uri.queryParameters['code'];
        if (code != null && code.isNotEmpty) {
          try {
            await Supabase.instance.client.auth.exchangeCodeForSession(code);
          } catch (_) {
            // Session may already be present or link may be a bare open-app handoff.
          }
        }
      }
      if (uri.queryParameters['type'] != 'recovery') {
        onMessage('Signed in successfully');
      }
    } else if (uri.host == 'settings') {
      onMessage('Billing updated');
    }
  }
}
