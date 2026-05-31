import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../services/pending_plan_service.dart';
import '../../theme/echodesk_theme.dart';
import '../../widgets/brand_lockup.dart';
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
        maxWidth: 1120,
        child: CustomScrollView(
          slivers: [
            const _LandingHeader(),
            const SliverToBoxAdapter(child: _HeroSection()),
            const SliverToBoxAdapter(child: _ProductPreview()),
            const SliverToBoxAdapter(child: _PricingSection()),
            const SliverToBoxAdapter(child: _FeatureSection()),
            const SliverToBoxAdapter(child: _TestimonialsSection()),
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),
    );
  }
}

class _LandingHeader extends StatelessWidget {
  const _LandingHeader();

  @override
  Widget build(BuildContext context) {
    return SliverAppBar(
      floating: true,
      pinned: true,
      toolbarHeight: 72,
      backgroundColor: EchoDeskColors.background.withValues(alpha: 0.94),
      surfaceTintColor: Colors.transparent,
      titleSpacing: 16,
      title: const BrandLockup(centered: true),
      actions: [
        TextButton(
          onPressed: () => context.go('/login'),
          child: const Text('Log in'),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: FilledButton(
            onPressed: () => _startSignup(context),
            child: const Text('Start free'),
          ),
        ),
      ],
    );
  }
}

class _HeroSection extends StatelessWidget {
  const _HeroSection();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 72, 24, 40),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: EchoDeskColors.brandSoft,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: EchoDeskColors.line),
            ),
            child: Text(
              'AI receptionist for appointment-based businesses',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: EchoDeskColors.brand,
                    fontWeight: FontWeight.w800,
                  ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 22),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 780),
            child: Text(
              'Turn missed calls into booked appointments.',
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    fontSize: 46,
                  ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 18),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 700),
            child: Text(
              'EchoDesk answers calls with a calm voice, checks real calendar availability, books the right slot, and keeps every call organized.',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    fontSize: 18,
                  ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 30),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: [
              FilledButton(
                onPressed: () => _startSignup(context, planId: 'starter'),
                child: const Text('Start with Starter'),
              ),
              OutlinedButton(
                onPressed: () => _scrollToPricing(context),
                child: const Text('View pricing'),
              ),
            ],
          ),
          const SizedBox(height: 36),
          const _HeroMockup(),
        ],
      ),
    );
  }

  void _scrollToPricing(BuildContext context) {
    final pricingContext = _PricingSection.anchorKey.currentContext;
    if (pricingContext == null) return;
    Scrollable.ensureVisible(
      pricingContext,
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
    );
  }
}

class _HeroMockup extends StatelessWidget {
  const _HeroMockup();

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 920),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: EchoDeskColors.surface,
        border: Border.all(color: EchoDeskColors.line),
        borderRadius: BorderRadius.circular(EchoDeskRadii.lg),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 36,
            offset: const Offset(0, 20),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 720;
          return Flex(
            direction: compact ? Axis.vertical : Axis.horizontal,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: compact ? 0 : 3,
                child: const _CallPanel(),
              ),
              SizedBox(width: compact ? 0 : 18, height: compact ? 18 : 0),
              Expanded(
                flex: compact ? 0 : 2,
                child: const _BookingPanel(),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _CallPanel extends StatelessWidget {
  const _CallPanel();

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _StatusDot(),
              const SizedBox(width: 10),
              Text('Call in progress',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Text('Sarah\'s Salon',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            '“I can do tomorrow at 3:00 PM. Would you like me to book that?”',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontSize: 24,
                  height: 1.25,
                ),
          ),
          const SizedBox(height: 24),
          const _TranscriptLine(
              label: 'Caller',
              text: 'Do you have anything tomorrow afternoon?'),
          const _TranscriptLine(
              label: 'EchoDesk',
              text: 'I have 2:30 PM, 3:00 PM, and 4:00 PM available.'),
          const _TranscriptLine(label: 'Caller', text: 'Let’s do 3.'),
        ],
      ),
    );
  }
}

class _BookingPanel extends StatelessWidget {
  const _BookingPanel();

  @override
  Widget build(BuildContext context) {
    return _Panel(
      backgroundColor: EchoDeskColors.brand,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Booking created',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                ),
          ),
          const SizedBox(height: 18),
          _DarkMetric(label: 'Customer', value: 'Jordan Lee'),
          _DarkMetric(label: 'Service', value: 'Haircut'),
          _DarkMetric(label: 'Time', value: 'Tomorrow, 3:00 PM'),
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(EchoDeskRadii.sm),
              border: Border.all(color: Colors.white24),
            ),
            child: Row(
              children: [
                const Icon(Icons.event_available, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Synced to Google Calendar',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProductPreview extends StatelessWidget {
  const _ProductPreview();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 36, 24, 48),
      child: Column(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 700),
            child: Text(
              'A calm workspace for calls, bookings, and customer context.',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 18,
            runSpacing: 18,
            alignment: WrapAlignment.center,
            children: const [
              _PreviewCard(
                icon: Icons.phone_in_talk_outlined,
                title: 'AI call handling',
                text:
                    'Live transcription, fast responses, and clear outcomes for every call.',
              ),
              _PreviewCard(
                icon: Icons.calendar_month_outlined,
                title: 'Calendar booking',
                text:
                    'Availability is checked before slots are offered or confirmed.',
              ),
              _PreviewCard(
                icon: Icons.person_search_outlined,
                title: 'Customer summary',
                text:
                    'Call history, recordings, appointments, and follow-up status stay together.',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PricingSection extends StatelessWidget {
  const _PricingSection();

  static final anchorKey = GlobalKey();

  static const _plans = [
    _MarketingPlan(
      name: 'Free',
      price: '\$0',
      minutes: 'Trial workspace',
      description: 'Explore the app, setup flow, and voice presets.',
      cta: 'Start free',
    ),
    _MarketingPlan(
      name: 'Starter',
      price: '\$69',
      minutes: '400 minutes included',
      description: 'For independent operators and small service teams.',
      cta: 'Choose Starter',
      planId: 'starter',
      featured: true,
      overage: '\$0.29 / extra minute',
    ),
    _MarketingPlan(
      name: 'Business',
      price: '\$149',
      minutes: '1,200 minutes included',
      description: 'For busier teams with higher weekly call volume.',
      cta: 'Choose Business',
      planId: 'business',
      overage: '\$0.29 / extra minute',
    ),
    _MarketingPlan(
      name: 'Enterprise',
      price: 'Custom',
      minutes: 'Custom minutes',
      description: 'For multi-location teams and custom workflows.',
      cta: 'Contact us',
      overage: 'Volume pricing',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: anchorKey,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 54),
      child: Column(
        children: [
          Text(
            'Clear pricing for real call coverage.',
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          Text(
            'Simple tiers, included minutes, and transparent overage.',
            style: Theme.of(context).textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          Wrap(
            spacing: 16,
            runSpacing: 16,
            alignment: WrapAlignment.center,
            children: _plans.map((plan) => _PricingCard(plan: plan)).toList(),
          ),
        ],
      ),
    );
  }
}

class _PricingCard extends StatelessWidget {
  const _PricingCard({required this.plan});

  final _MarketingPlan plan;

  @override
  Widget build(BuildContext context) {
    final borderColor =
        plan.featured ? EchoDeskColors.brand : EchoDeskColors.line;
    return SizedBox(
      width: 248,
      child: Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: EchoDeskColors.surface,
          borderRadius: BorderRadius.circular(EchoDeskRadii.md),
          border: Border.all(color: borderColor),
          boxShadow: plan.featured
              ? [
                  BoxShadow(
                    color: EchoDeskColors.brand.withValues(alpha: 0.12),
                    blurRadius: 28,
                    offset: const Offset(0, 18),
                  ),
                ]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (plan.featured) ...[
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: EchoDeskColors.brandSoft,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'Most useful',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: EchoDeskColors.brand,
                        fontWeight: FontWeight.w800,
                      ),
                ),
              ),
              const SizedBox(height: 14),
            ],
            Text(plan.name, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  plan.price,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                if (plan.price.startsWith('\$'))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5, left: 2),
                    child: Text('/mo',
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              plan.minutes,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: EchoDeskColors.brand,
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 10),
            Text(plan.description,
                style: Theme.of(context).textTheme.bodySmall),
            if (plan.overage != null) ...[
              const SizedBox(height: 12),
              Text(plan.overage!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: EchoDeskColors.muted,
                        fontWeight: FontWeight.w700,
                      )),
            ],
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: plan.featured
                  ? FilledButton(
                      onPressed: () =>
                          _startSignup(context, planId: plan.planId),
                      child: Text(plan.cta),
                    )
                  : OutlinedButton(
                      onPressed: () =>
                          _startSignup(context, planId: plan.planId),
                      child: Text(plan.cta),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeatureSection extends StatelessWidget {
  const _FeatureSection();

  static const _features = [
    (
      'Answers professionally',
      'A calm AI receptionist picks up when your team is busy, closed, or with a customer.'
    ),
    (
      'Books from availability',
      'EchoDesk checks Google Calendar before offering times and creating appointments.'
    ),
    (
      'Organizes follow-up',
      'Call summaries, recordings, appointment status, and customer details stay easy to scan.'
    ),
    (
      'Fits service teams',
      'Built for salons, clinics, studios, home services, consultants, and local operators.'
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 54),
      child: Wrap(
        spacing: 16,
        runSpacing: 16,
        alignment: WrapAlignment.center,
        children: _features
            .map(
              (feature) => SizedBox(
                width: 248,
                child: _Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(feature.$1,
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 10),
                      Text(feature.$2,
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _TestimonialsSection extends StatelessWidget {
  const _TestimonialsSection();

  static const _testimonials = [
    (
      'Customers get an answer, and bookings land in the calendar without us stopping a service.',
      'Salon owner',
    ),
    (
      'It feels calm and practical. We can see what happened on each call and what needs attention.',
      'Wellness studio operator',
    ),
    (
      'The pricing is easy to understand, and the app makes call handling feel less chaotic.',
      'Local service provider',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      color: EchoDeskColors.surfaceSoft,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 54),
      child: Column(
        children: [
          Text(
            'Built for quiet, reliable operations.',
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          Wrap(
            spacing: 16,
            runSpacing: 16,
            alignment: WrapAlignment.center,
            children: _testimonials.map((t) {
              return SizedBox(
                width: 300,
                child: _Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('"${t.$1}"',
                          style: Theme.of(context).textTheme.bodyMedium),
                      const SizedBox(height: 16),
                      Text(t.$2, style: Theme.of(context).textTheme.titleSmall),
                    ],
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

class _Panel extends StatelessWidget {
  const _Panel({
    required this.child,
    this.backgroundColor = EchoDeskColors.surface,
  });

  final Widget child;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(EchoDeskRadii.md),
        border: Border.all(
          color: backgroundColor == EchoDeskColors.brand
              ? Colors.white.withValues(alpha: 0.12)
              : EchoDeskColors.line,
        ),
      ),
      child: child,
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.icon,
    required this.title,
    required this.text,
  });

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 300,
      child: _Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: EchoDeskColors.brand, size: 30),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(text, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _TranscriptLine extends StatelessWidget {
  const _TranscriptLine({required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
          ),
          Expanded(
              child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

class _DarkMetric extends StatelessWidget {
  const _DarkMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.58),
                ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                ),
          ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: const BoxDecoration(
        color: EchoDeskColors.success,
        shape: BoxShape.circle,
      ),
    );
  }
}

class _MarketingPlan {
  const _MarketingPlan({
    required this.name,
    required this.price,
    required this.minutes,
    required this.description,
    required this.cta,
    this.planId,
    this.featured = false,
    this.overage,
  });

  final String name;
  final String price;
  final String minutes;
  final String description;
  final String cta;
  final String? planId;
  final bool featured;
  final String? overage;
}
