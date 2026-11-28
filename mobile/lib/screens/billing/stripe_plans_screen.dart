import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/plan.dart';
import '../../theme/echodesk_theme.dart';
import '../../widgets/legal_links.dart';
import 'apple_plans_screen.dart';

/// Android and web plan list. Prices are the Stripe catalog amounts.
/// Checkout uses the configured Stripe price id, not a hard-coded charge.
class StripePlansScreen extends StatefulWidget {
  const StripePlansScreen({super.key, this.billing});

  final PlanBillingSnapshot? billing;

  @override
  State<StripePlansScreen> createState() => _StripePlansScreenState();
}

class _StripePlansScreenState extends State<StripePlansScreen> {
  PlanBillingSnapshot _billing = const PlanBillingSnapshot();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _billing = widget.billing ?? const PlanBillingSnapshot();
    _load();
  }

  Future<void> _load() async {
    if (widget.billing == null) {
      _billing = await loadPlanBilling();
    }
    if (mounted) setState(() => _loading = false);
  }

  String? _label(Plan plan) {
    if (_billing.entitled && plan.id == _billing.planId) return 'Current';
    if (!_billing.entitled || (_billing.planId ?? '').isEmpty) return 'Subscribe';
    if (Plan.rankOf(plan.id) > Plan.rankOf(_billing.planId)) return 'Upgrade';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Choose a plan')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                Text(
                  _billing.entitled
                      ? 'Your current plan is marked below. Upgrade takes effect on your next Stripe checkout.'
                      : 'Every plan starts with 14 days free and 50 call minutes. A card is required. You are not charged until the trial ends.',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: EchoDeskColors.muted,
                      ),
                ),
                const SizedBox(height: 16),
                for (final plan in Plan.publicPlans) ...[
                  _StripePlanCard(
                    plan: plan,
                    label: _label(plan),
                    showTrial: !_billing.entitled,
                    onPressed: () {
                      final label = _label(plan);
                      if (label == 'Subscribe' || label == 'Upgrade') {
                        context.push('/checkout/pay?plan=${plan.id}');
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                ],
                const LegalLinks(),
                ],
              ),
            ),
    );
  }
}

class _StripePlanCard extends StatelessWidget {
  const _StripePlanCard({
    required this.plan,
    required this.label,
    required this.showTrial,
    required this.onPressed,
  });

  final Plan plan;
  final String? label;
  final bool showTrial;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final price = '\$${(plan.priceCents / 100).toStringAsFixed(0)}';
    final overage = switch (plan.id) {
      'starter' => '\$0.25',
      'growth' => '\$0.20',
      'business' => '\$0.18',
      _ => null,
    };
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(plan.name, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              '1 month',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: EchoDeskColors.brand,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '$price/month',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            if (showTrial) ...[
              const SizedBox(height: 8),
              Text(
                '14 days free, then $price/month',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
            const SizedBox(height: 8),
            Text('${plan.includedMinutes} minutes per month'),
            if (overage != null) ...[
              const SizedBox(height: 8),
              Text('$overage / extra minute'),
            ],
            if (label != null) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: label == 'Current' ? null : onPressed,
                  child: Text(label!),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
