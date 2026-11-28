import 'package:flutter/foundation.dart' show kDebugMode;

/// Subscription plan definitions (matches backend stripe_plans / Stripe prices).
class Plan {
  final String id;
  final String name;
  final int priceCents;
  final int includedMinutes;

  const Plan({
    required this.id,
    required this.name,
    required this.priceCents,
    required this.includedMinutes,
  });

  String get priceLabel => priceCents == 0
      ? 'Try free'
      : '\$${(priceCents / 100).toStringAsFixed(0)}/mo';

  /// Public paid tiers shown in Settings, checkout, and marketing.
  /// Customers can buy Starter, Growth, and Business.
  static const List<Plan> publicPlans = [
    Plan(
      id: 'starter',
      name: 'Starter',
      priceCents: 6900,
      includedMinutes: 250,
    ),
    Plan(
      id: 'growth',
      name: 'Growth',
      priceCents: 14900,
      includedMinutes: 750,
    ),
    Plan(
      id: 'business',
      name: 'Business',
      priceCents: 24900,
      includedMinutes: 1500,
    ),
  ];

  /// Owner testing plan — never list in Settings, checkout UI, or marketing.
  /// Reachable only via deep link / code (e.g. `/checkout?plan=dev_test`).
  static const Plan internalDevPlan = Plan(
    id: 'dev_test',
    name: 'DEV test',
    priceCents: 100,
    includedMinutes: 50,
  );

  /// Plans shown in customer-facing plan pickers.
  static List<Plan> get subscriptionPlans => publicPlans;

  static const Map<String, int> _rank = {
    'starter': 0,
    'growth': 1,
    'business': 2,
  };

  static int rankOf(String? id) => _rank[id ?? ''] ?? -1;

  /// `subscription_growth` -> `growth`.
  static String? idFromBillingPlan(String? billingPlan) {
    final raw = (billingPlan ?? '').trim();
    if (raw.isEmpty) return null;
    const prefix = 'subscription_';
    if (raw.startsWith(prefix)) return raw.substring(prefix.length);
    return raw;
  }

  /// Plans that may be purchased via API or deep link.
  ///
  /// The hidden $1 `dev_test` plan is included in debug builds only.
  /// Release and profile builds cannot reach it, including by deep link.
  static List<Plan> get checkoutablePlans {
    if (kDebugMode) {
      return const [...publicPlans, internalDevPlan];
    }
    return publicPlans;
  }
}
