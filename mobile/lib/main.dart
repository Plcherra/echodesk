import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart'
    show
        FlutterError,
        PlatformDispatcher,
        TargetPlatform,
        debugPrint,
        defaultTargetPlatform,
        kDebugMode;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config/env.dart';
import 'app.dart';
import 'firebase_options.dart';
import 'services/push_service.dart';
import 'services/call_service.dart';

void main() async {
  var firebaseReady = false;

  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await Env.loadLocalOverrides();
    if (Env.supabaseUrl.isEmpty || Env.supabaseAnonKey.isEmpty) {
      throw StateError(
        'SUPABASE_URL and SUPABASE_ANON_KEY must be set via --dart-define. '
        'For local desktop dev, add NEXT_PUBLIC_SUPABASE_URL and '
        'NEXT_PUBLIC_SUPABASE_ANON_KEY to ../.env.local or run ./run.sh macos.',
      );
    }
    final supabaseHost = Env.supabaseUrl.toLowerCase();
    if (supabaseHost.contains('your-project.supabase.co') ||
        Env.supabaseAnonKey.toLowerCase().contains('your_anon')) {
      throw StateError(
        'Supabase is still set to placeholder values (your-project.supabase.co). '
        'Put the real NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY '
        'in ../.env.local, then rebuild with ./run_prod.sh <device>.',
      );
    }
    try {
      await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform);
      firebaseReady = true;
    } catch (error, stack) {
      firebaseReady = false;
      if (kDebugMode) {
        debugPrint('[Firebase] init skipped: $error');
      }
      FlutterError.dumpErrorToConsole(
        FlutterErrorDetails(exception: error, stack: stack),
      );
    }

    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      if (firebaseReady) {
        FirebaseCrashlytics.instance.recordFlutterFatalError(details);
      }
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      if (firebaseReady) {
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      }
      return true;
    };
    await Supabase.initialize(
      url: Env.supabaseUrl,
      anonKey: Env.supabaseAnonKey,
    );
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android) {
      await PushService().initialize();
      await CallService().initialize();
    }
    runApp(const EchodeskApp());
  }, (error, stack) {
    if (firebaseReady) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: false);
    } else {
      FlutterError.dumpErrorToConsole(
        FlutterErrorDetails(exception: error, stack: stack),
      );
    }
  });
}
