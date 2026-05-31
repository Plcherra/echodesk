/// Subscription plan definitions (matches app/lib/plans.ts)
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

  /// Public paid tiers shown in app surfaces.
  /// Keep ids in sync with backend stripe_plans / Stripe prices.
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

  static List<Plan> get subscriptionPlans => publicPlans;
}
