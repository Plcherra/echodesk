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
  /// Customers can buy Starter and Business only.
  static const List<Plan> publicPlans = [
    Plan(
      id: 'starter',
      name: 'Starter',
      priceCents: 6900,
      includedMinutes: 400,
    ),
    Plan(
      id: 'business',
      name: 'Business',
      priceCents: 14900,
      includedMinutes: 1200,
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

  /// Plans that may be purchased via API or deep link (includes hidden internal).
  static List<Plan> get checkoutablePlans => [
        ...publicPlans,
        internalDevPlan,
      ];
}
