import 'package:flutter/foundation.dart' show kIsWeb, kReleaseMode;

import 'local_env_loader_stub.dart'
    if (dart.library.io) 'local_env_loader_io.dart' as local_env_loader;

/// App configuration. Uses dart-define in production, or defaults for local dev.
/// Debug: http://localhost:8000 | Release: https://echodesk.us (or pass API_BASE_URL)
/// Run: flutter run --dart-define=API_BASE_URL=https://echodesk.us
/// Build: flutter build apk --dart-define=API_BASE_URL=https://echodesk.us ...
class Env {
  static Map<String, String> _localOverrides = const {};

  static Future<void> loadLocalOverrides() async {
    if (kReleaseMode || kIsWeb) return;
    _localOverrides = await local_env_loader.loadLocalEnv();
  }

  static String get apiBaseUrl {
    const env = String.fromEnvironment('API_BASE_URL', defaultValue: '');
    if (env.isNotEmpty) return env;
    final local = _localOverrides['NEXT_PUBLIC_APP_URL'] ??
        _localOverrides['APP_API_BASE_URL'];
    if (local != null && local.isNotEmpty) return local;
    return kReleaseMode ? 'https://echodesk.us' : 'http://localhost:8000';
  }

  static String get supabaseUrl {
    const env = String.fromEnvironment('SUPABASE_URL', defaultValue: '');
    if (env.isNotEmpty) return env;
    return _localOverrides['NEXT_PUBLIC_SUPABASE_URL'] ??
        _localOverrides['SUPABASE_URL'] ??
        '';
  }

  static String get supabaseAnonKey {
    const env = String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');
    if (env.isNotEmpty) return env;
    return _localOverrides['NEXT_PUBLIC_SUPABASE_ANON_KEY'] ??
        _localOverrides['SUPABASE_ANON_KEY'] ??
        '';
  }

  static const String deepLinkScheme =
      String.fromEnvironment('DEEP_LINK_SCHEME', defaultValue: 'echodesk');

  /// Where Supabase sends the browser after email confirmation.
  /// Must be allowlisted in Supabase Auth → URL Configuration:
  ///   - https://echodesk.us/auth/callback
  ///   - echodesk://auth-callback  (must match [deepLinkScheme])
  /// HTTPS handoff page then opens the app via deep link (iOS-friendly).
  static String get authEmailRedirectUrl {
    const env = String.fromEnvironment('AUTH_EMAIL_REDIRECT', defaultValue: '');
    if (env.isNotEmpty) return env;
    return 'https://echodesk.us/auth/callback';
  }

  static bool get googleAuthEnabled {
    const env = String.fromEnvironment(
      'GOOGLE_AUTH_ENABLED',
      defaultValue: '',
    );
    final value = env.isNotEmpty
        ? env
        : (_localOverrides['GOOGLE_AUTH_ENABLED'] ??
            _localOverrides['NEXT_PUBLIC_GOOGLE_AUTH_ENABLED'] ??
            '');
    return value.toLowerCase() == 'true' || value == '1';
  }

  /// Voice backend WebSocket base URL (for listen-in on active call screen).
  /// Defaults to wss://echodesk.us in release; override with VOICE_WS_BASE_URL.
  static String get voiceWsBaseUrl {
    const env = String.fromEnvironment('VOICE_WS_BASE_URL', defaultValue: '');
    if (env.isNotEmpty) return env;
    return kReleaseMode ? 'wss://echodesk.us' : '';
  }

  /// Customer-facing support inbox. Override with SUPPORT_EMAIL dart-define.
  static String get supportEmail {
    const env = String.fromEnvironment('SUPPORT_EMAIL', defaultValue: '');
    if (env.isNotEmpty) return env;
    final local = _localOverrides['SUPPORT_EMAIL'];
    if (local != null && local.isNotEmpty) return local;
    return 'echodesk2@gmail.com';
  }
}
