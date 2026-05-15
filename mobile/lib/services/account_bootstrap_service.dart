import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'api_client.dart';

class AccountBootstrapService {
  AccountBootstrapService({this.onProfileReady});

  final Future<void> Function()? onProfileReady;
  StreamSubscription<AuthState>? _subscription;
  String? _lastEnsuredUserId;
  Future<void>? _inFlight;

  void init() {
    final session = Supabase.instance.client.auth.currentSession;
    if (session != null) {
      ensureCurrentProfile();
    }

    _subscription =
        Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      final userId = data.session?.user.id;
      if (userId == null || userId.isEmpty) {
        _lastEnsuredUserId = null;
        return;
      }
      ensureCurrentProfile();
    });
  }

  Future<void> ensureCurrentProfile() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;
    if (_lastEnsuredUserId == user.id) return;

    final existing = _inFlight;
    if (existing != null) {
      await existing;
      if (_lastEnsuredUserId == user.id) return;
    }

    final future = _ensure(user.id);
    _inFlight = future;
    try {
      await future;
    } finally {
      if (identical(_inFlight, future)) {
        _inFlight = null;
      }
    }
  }

  Future<void> _ensure(String userId) async {
    try {
      final res = await ApiClient.post('/api/mobile/profile/ensure');
      if (res.statusCode >= 200 && res.statusCode < 300) {
        _lastEnsuredUserId = userId;
        await onProfileReady?.call();
      } else if (kDebugMode) {
        debugPrint(
          '[AccountBootstrap] profile ensure failed: ${res.statusCode} ${res.body}',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AccountBootstrap] profile ensure failed: $e');
      }
    }
  }

  void dispose() {
    _subscription?.cancel();
  }
}
