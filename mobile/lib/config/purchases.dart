import 'purchases_platform_stub.dart'
    if (dart.library.io) 'purchases_platform_io.dart';

export 'purchases_platform_stub.dart'
    if (dart.library.io) 'purchases_platform_io.dart'
    show isIosPlatform;

/// Compile-time kill switch for in-app purchasing.
///
/// Defaults to true so Android and web keep checkout. App Store builds pass
/// `--dart-define=PURCHASES_ENABLED=false`, which lets the compiler strip
/// purchase UI from the binary. Callers must test this const before any
/// purchase widget so that branch can be tree-shaken:
///
/// ```dart
/// if (kPurchasesEnabled) {
///   if (!isIosPlatform) return purchaseUi;
/// }
/// return companionUi;
/// ```
///
/// [isIosPlatform] is the runtime guard for an iOS build that forgot the define.
const bool kPurchasesEnabled = bool.fromEnvironment(
  'PURCHASES_ENABLED',
  defaultValue: true,
);

/// True only when this build may offer purchases and the device is not iOS.
bool get purchasesEnabled {
  if (kPurchasesEnabled) {
    if (!isIosPlatform) return true;
  }
  return false;
}
