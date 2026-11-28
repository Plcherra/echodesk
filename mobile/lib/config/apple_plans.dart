/// Apple auto-renewable subscriptions.
///
/// Product ids default to the App Store Connect ids and can be overridden at
/// build time. Prices are never stored here; the paywall shows the localized
/// price returned by StoreKit. Included minutes match the backend catalog.
const String appleProductStarter = String.fromEnvironment(
  'APPLE_IAP_PRODUCT_STARTER',
  defaultValue: 'com.echodesk.sub.starter.monthly',
);

const String appleProductGrowth = String.fromEnvironment(
  'APPLE_IAP_PRODUCT_GROWTH',
  defaultValue: 'com.echodesk.sub.growth.monthly',
);

const String appleProductBusiness = String.fromEnvironment(
  'APPLE_IAP_PRODUCT_BUSINESS',
  defaultValue: 'com.echodesk.sub.business.monthly',
);

/// Apple's subscription management page. This is not an EchoDesk checkout.
const String appleManageSubscriptionsUrl =
    'https://apps.apple.com/account/subscriptions';

const String appleSubscriptionDuration = '1 month';

class ApplePlanDefinition {
  final String id;
  final String name;
  final String productId;
  final int includedMinutes;

  const ApplePlanDefinition({
    required this.id,
    required this.name,
    required this.productId,
    required this.includedMinutes,
  });

  String get includedLabel {
    final text = includedMinutes.toString();
    final formatted = text.replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
      (match) => '${match[1]},',
    );
    return '$formatted minutes per month';
  }
}

/// Customer-facing Apple plans. The debug `dev_test` plan is not here.
const List<ApplePlanDefinition> applePlanCatalog = [
  ApplePlanDefinition(
    id: 'starter',
    name: 'Starter',
    productId: appleProductStarter,
    includedMinutes: 250,
  ),
  ApplePlanDefinition(
    id: 'growth',
    name: 'Growth',
    productId: appleProductGrowth,
    includedMinutes: 750,
  ),
  ApplePlanDefinition(
    id: 'business',
    name: 'Business',
    productId: appleProductBusiness,
    includedMinutes: 1500,
  ),
];

class ApplePlanOffer {
  final String planId;
  final String productId;
  final String name;
  final int includedMinutes;
  final String durationLabel;
  final String? localizedPrice;
  final String? storeDescription;
  final bool canPurchase;

  const ApplePlanOffer({
    required this.planId,
    required this.productId,
    required this.name,
    required this.includedMinutes,
    required this.durationLabel,
    required this.localizedPrice,
    required this.storeDescription,
    required this.canPurchase,
  });

  String get includedLabel {
    final text = includedMinutes.toString();
    final formatted = text.replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
      (match) => '${match[1]},',
    );
    return '$formatted minutes per month';
  }
}

/// Disclosure required beside the StoreKit price. [price] is the localized
/// string from StoreKit, never a price typed into the app.
String appleRenewalDisclosure(String planName, String? price) {
  final priceText = (price == null || price.trim().isEmpty)
      ? 'the price shown by the App Store'
      : price.trim();
  return '$planName is a $appleSubscriptionDuration auto-renewable subscription at $priceText. '
      'Payment is charged to your Apple ID at confirmation of purchase. '
      'The subscription renews automatically unless you cancel at least 24 hours before the end of the current period. '
      'Your account is charged for renewal within 24 hours before the period ends. '
      'You can manage or cancel the subscription in your App Store account settings. '
      'Any unused portion of a free trial, if one is offered, is forfeited when you buy a subscription.';
}

abstract class ApplePlansController {
  Future<List<ApplePlanOffer>> loadOffers();
  Future<String?> purchase(ApplePlanOffer offer);
  Future<String?> restore();
}
