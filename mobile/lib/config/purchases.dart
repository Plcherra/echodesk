import 'purchases_platform_stub.dart'
    if (dart.library.io) 'purchases_platform_io.dart';

export 'purchases_platform_stub.dart'
    if (dart.library.io) 'purchases_platform_io.dart'
    show isIosPlatform;

/// Compile-time kill switch for in-app purchasing.
///
/// Defaults to true. Android and web use Stripe. iOS uses Apple In-App
/// Purchase. Pass `--dart-define=PURCHASES_ENABLED=false` only to strip every
/// purchase surface. Callers must test [kPurchasesEnabled] before building a
/// purchase widget so that branch can be tree-shaken.
const bool kPurchasesEnabled = bool.fromEnvironment(
  'PURCHASES_ENABLED',
  defaultValue: true,
);

/// Android and web Stripe checkout. iOS never uses this.
bool get stripePurchasesEnabled {
  if (!kPurchasesEnabled) return false;
  return !isIosPlatform;
}

/// iOS App Store auto-renewable subscriptions.
bool get applePurchasesEnabled {
  if (!kPurchasesEnabled) return false;
  return isIosPlatform;
}

/// True when this build may offer a purchase flow on the current platform.
bool get purchasesEnabled => stripePurchasesEnabled || applePurchasesEnabled;
