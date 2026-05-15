import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../models/plan.dart';
import '../../services/pending_plan_service.dart';
import '../../widgets/constrained_scaffold_body.dart';

Future<void> _startSignup(BuildContext context, {String? planId}) async {
  final validPlanId =
      PendingPlanService.isValidPlanId(planId) ? planId?.trim() : null;
  if (validPlanId == null) {
    await PendingPlanService.clear();
  } else {
    await PendingPlanService.save(validPlanId);
  }
  if (!context.mounted) return;
  final query = validPlanId == null ? '' : '?plan=$validPlanId';
  context.go('/signup$query');
}

class LandingScreen extends StatelessWidget {
  const LandingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: constrainedScaffoldBody(
        child: CustomScrollView(
          slivers: [
            _LandingHeader(),
            const SliverToBoxAdapter(child: _HeroSection()),
            const SliverToBoxAdapter(child: _PricingTeaser()),
            const SliverToBoxAdapter(child: _DemoVideoSection()),
            const SliverToBoxAdapter(child: _PricingSection()),
            const SliverToBoxAdapter(child: _TestimonialsSection()),
          ],
        ),
      ),
    );
  }
}

class _LandingHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SliverAppBar(
      floating: true,
      backgroundColor:
          Theme.of(context).colorScheme.surface.withValues(alpha: 0.95),
      title: const Text('AI Receptionist'),
      actions: [
        TextButton(
          onPressed: () => context.go('/login'),
          child: const Text('Log in'),
        ),
        FilledButton(
          onPressed: () => _startSignup(context),
          child: const Text('Get Started'),
        ),
        const SizedBox(width: 16),
      ],
    );
  }
}

class _HeroSection extends StatelessWidget {
  const _HeroSection();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.deepPurple.shade700,
            Colors.purple.shade600,
            Colors.indigo.shade700,
          ],
        ),
      ),
      child: Column(
        children: [
          Text(
            'AI Receptionist – Never Miss a Booking',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Text(
            'Your AI answers calls, books appointments, and syncs with Google Calendar. '
            'For individuals and small businesses—salons, barbers, spas, handymen, and more.',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Colors.white.withValues(alpha: 0.9),
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(
            'From \$69/mo',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 40),
          Wrap(
            spacing: 16,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: [
              FilledButton(
                onPressed: () => _startSignup(context),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.purple.shade700,
                ),
                child: const Text('Get Started'),
              ),
              OutlinedButton(
                onPressed: () => _startSignup(context, planId: 'starter'),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.white54),
                  foregroundColor: Colors.white,
                ),
                child: const Text('Start free trial'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PricingTeaser extends StatelessWidget {
  const _PricingTeaser();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 16,
            alignment: WrapAlignment.center,
            children: Plan.publicPlans.map((plan) {
              return SizedBox(
                width: 180,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          plan.name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          plan.includedMinutes > 0
                              ? '${plan.includedMinutes} min included'
                              : 'Try free',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          plan.priceLabel,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        if (plan.includedMinutes > 0) ...[
                          const SizedBox(height: 12),
                          _checkItem('AI answers 24/7'),
                          _checkItem('Google Calendar'),
                          _checkItem('Your phone number'),
                        ],
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: () =>
                              _startSignup(context, planId: plan.id),
                          child: Text(
                            plan.priceCents == 0
                                ? 'Start free trial'
                                : 'Get Started',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () {},
            child: const Text('See all plans →'),
          ),
        ],
      ),
    );
  }

  Widget _checkItem(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: [
            const Icon(Icons.check, size: 16),
            const SizedBox(width: 8),
            Text(text, style: const TextStyle(fontSize: 12)),
          ],
        ),
      );
}

class _DemoVideoSection extends StatelessWidget {
  const _DemoVideoSection();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
      child: Column(
        children: [
          Text(
            'See it in action',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 24),
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Center(
                child: Icon(Icons.play_circle_outline, size: 64),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PricingSection extends StatelessWidget {
  const _PricingSection();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
      child: Column(
        children: [
          Text(
            'Simple pricing',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'Choose a plan with included minutes. No hidden fees.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 32),
          Wrap(
            spacing: 24,
            runSpacing: 24,
            alignment: WrapAlignment.center,
            children: Plan.subscriptionPlans.map((plan) {
              return SizedBox(
                width: 220,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(plan.name,
                            style: Theme.of(context).textTheme.titleMedium),
                        Text(
                          '${plan.includedMinutes} minutes included',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '\$${(plan.priceCents / 100).toStringAsFixed(0)}/month',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 24),
                        _checkItem('AI answers 24/7'),
                        _checkItem('Books into Google Calendar'),
                        _checkItem('Your business phone number'),
                        _checkItem('Cancel anytime'),
                        const SizedBox(height: 24),
                        FilledButton(
                          onPressed: () =>
                              _startSignup(context, planId: plan.id),
                          child: const Text('Get Started'),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _checkItem(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            const Icon(Icons.check, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(text)),
          ],
        ),
      );
}

class _TestimonialsSection extends StatelessWidget {
  const _TestimonialsSection();

  static const _testimonials = [
    (
      'We went from missing half our after-hours calls to zero. The assistant books directly into our calendar.',
      'Maria L.',
      'Salon owner',
    ),
    (
      "Set up in 10 minutes. Our clients think they're talking to a real person. Game changer.",
      'James T.',
      'Barbershop',
    ),
    (
      'Finally something that works for individuals and small businesses. Worth every penny.',
      'Sarah K.',
      'Spa & wellness',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
      child: Column(
        children: [
          Text(
            'What owners are saying',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 32),
          Wrap(
            spacing: 24,
            runSpacing: 24,
            children: _testimonials.map((t) {
              return SizedBox(
                width: 280,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('"${t.$1}"',
                            style: Theme.of(context).textTheme.bodyMedium),
                        const SizedBox(height: 16),
                        Text(t.$2,
                            style: Theme.of(context).textTheme.titleSmall),
                        Text(t.$3,
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
