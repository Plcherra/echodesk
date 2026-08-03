import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../config/trial_offer.dart';
import '../../services/pending_plan_service.dart';
import '../../theme/echodesk_theme.dart';
import '../../widgets/brand_lockup.dart';

/// First screen before login: trial offer + clear Create account / Log in.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _plansKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _refreshTrialSpots();
  }

  Future<void> _refreshTrialSpots() async {
    await TrialOffer.refreshFromApi();
    if (mounted) setState(() {});
  }

  Future<void> _createAccount({String? planId}) async {
    if (PendingPlanService.isValidPlanId(planId)) {
      await PendingPlanService.save(planId!.trim());
    } else {
      await PendingPlanService.clear();
    }
    if (!mounted) return;
    final query =
        PendingPlanService.isValidPlanId(planId) ? '?plan=${planId!.trim()}' : '';
    context.go('/signup$query');
  }

  void _scrollToPlans() {
    final ctx = _plansKey.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
      alignment: 0.05,
    );
  }

  @override
  Widget build(BuildContext context) {
    final trialOpen = TrialOffer.hasSpotsRemaining;

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFFE8F2F1),
              EchoDeskColors.background,
              Color(0xFFF7F5F2),
            ],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 960;
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1120),
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      wide ? 40 : 20,
                      wide ? 36 : 16,
                      wide ? 40 : 20,
                      28,
                    ),
                    child: wide
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    flex: 5,
                                    child: _HeroColumn(
                                      trialOpen: trialOpen,
                                      onCreateAccount: () => _createAccount(),
                                      onLogIn: () => context.go('/login'),
                                      onSeePlans: _scrollToPlans,
                                    ),
                                  ),
                                  const SizedBox(width: 36),
                                  const Expanded(
                                    flex: 4,
                                    child: _ProductPreviewPanel(),
                                  ),
                                ],
                              ),
                              const SizedBox(height: EchoDeskSpacing.xxl),
                              KeyedSubtree(
                                key: _plansKey,
                                child: _PlansStrip(
                                  trialOpen: trialOpen,
                                  onSelectTrial: () => _createAccount(),
                                  onSelectPlan: (id) =>
                                      _createAccount(planId: id),
                                ),
                              ),
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _HeroColumn(
                                trialOpen: trialOpen,
                                onCreateAccount: () => _createAccount(),
                                onLogIn: () => context.go('/login'),
                                onSeePlans: _scrollToPlans,
                              ),
                              const SizedBox(height: EchoDeskSpacing.lg),
                              const _ProductPreviewPanel(),
                              const SizedBox(height: EchoDeskSpacing.xl),
                              KeyedSubtree(
                                key: _plansKey,
                                child: _PlansStrip(
                                  trialOpen: trialOpen,
                                  onSelectTrial: () => _createAccount(),
                                  onSelectPlan: (id) =>
                                      _createAccount(planId: id),
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _HeroColumn extends StatelessWidget {
  const _HeroColumn({
    required this.trialOpen,
    required this.onCreateAccount,
    required this.onLogIn,
    required this.onSeePlans,
  });

  final bool trialOpen;
  final VoidCallback onCreateAccount;
  final VoidCallback onLogIn;
  final VoidCallback onSeePlans;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const BrandLockup(markSize: 44, centered: false),
        const SizedBox(height: EchoDeskSpacing.xl),
        Text(
          'Never miss another booking call.',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
                height: 1.15,
                color: EchoDeskColors.ink,
              ),
        ),
        const SizedBox(height: EchoDeskSpacing.sm),
        Text(
          'EchoDesk answers your business line, checks Google Calendar, and books appointments while you work.',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: EchoDeskColors.muted,
                height: 1.45,
              ),
        ),
        const SizedBox(height: EchoDeskSpacing.lg),
        _TrialOfferBanner(trialOpen: trialOpen),
        const SizedBox(height: EchoDeskSpacing.lg),
        const _ValueRows(),
        const SizedBox(height: EchoDeskSpacing.xl),
        FilledButton(
          onPressed: onCreateAccount,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          child: Text(
            trialOpen ? 'Start 14-day free trial' : 'Create account',
          ),
        ),
        const SizedBox(height: EchoDeskSpacing.sm),
        OutlinedButton(
          onPressed: onLogIn,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          child: const Text('Log in'),
        ),
        const SizedBox(height: EchoDeskSpacing.sm),
        TextButton(
          onPressed: onSeePlans,
          child: const Text('Compare paid plans'),
        ),
      ],
    );
  }
}

class _TrialOfferBanner extends StatelessWidget {
  const _TrialOfferBanner({required this.trialOpen});

  final bool trialOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(EchoDeskSpacing.md),
      decoration: BoxDecoration(
        color: EchoDeskColors.brandSoft,
        borderRadius: BorderRadius.circular(EchoDeskRadii.md),
        border: Border.all(color: EchoDeskColors.brandTeal.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            trialOpen
                ? 'Launch offer · ${TrialOffer.trialDays}-day free trial'
                : 'Launch trial is full',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: EchoDeskColors.brand,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            trialOpen
                ? '${TrialOffer.spotsLabel}. Includes ${TrialOffer.includedMinutes} call minutes, one business number, and calendar booking. No credit card.'
                : 'Choose Starter, Growth, or Business below to continue.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: EchoDeskColors.ink.withValues(alpha: 0.78),
                  height: 1.4,
                ),
          ),
        ],
      ),
    );
  }
}

class _ValueRows extends StatelessWidget {
  const _ValueRows();

  static const _items = [
    (Icons.call_outlined, 'Answers every call professionally'),
    (Icons.event_available_outlined, 'Books only from real calendar availability'),
    (Icons.phone_iphone_outlined, 'Call history, recordings, and bookings in one place'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final item in _items) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(item.$1, size: 20, color: EchoDeskColors.brandTeal),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.$2,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: EchoDeskColors.ink,
                        height: 1.35,
                        fontWeight: FontWeight.w500,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _ProductPreviewPanel extends StatelessWidget {
  const _ProductPreviewPanel();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: EchoDeskColors.surface,
        borderRadius: BorderRadius.circular(EchoDeskRadii.lg),
        border: Border.all(color: EchoDeskColors.line),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'What callers experience',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 14),
          _PreviewBubble(
            label: 'Caller',
            text: 'Do you have anything tomorrow morning?',
            alignEnd: false,
          ),
          const SizedBox(height: 10),
          _PreviewBubble(
            label: 'EchoDesk',
            text: 'Yes — 10:30 AM or 11:15 AM are open.',
            alignEnd: true,
          ),
          const SizedBox(height: 10),
          _PreviewBubble(
            label: 'Caller',
            text: '10:30 works.',
            alignEnd: false,
          ),
          const SizedBox(height: 10),
          _PreviewBubble(
            label: 'EchoDesk',
            text: "You're booked. I'll send the confirmation now.",
            alignEnd: true,
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: EchoDeskColors.successSoft,
              borderRadius: BorderRadius.circular(EchoDeskRadii.sm),
            ),
            child: Row(
              children: [
                Icon(Icons.check_circle, size: 18, color: EchoDeskColors.success),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Appointment saved to your Google Calendar',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: EchoDeskColors.ink,
                          fontWeight: FontWeight.w600,
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

class _PreviewBubble extends StatelessWidget {
  const _PreviewBubble({
    required this.label,
    required this.text,
    required this.alignEnd,
  });

  final String label;
  final String text;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final bg = alignEnd ? EchoDeskColors.brandSoft : EchoDeskColors.surfaceSoft;
    return Align(
      alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: EchoDeskColors.soft,
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 2),
              Text(
                text,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: EchoDeskColors.ink,
                      height: 1.35,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlansStrip extends StatelessWidget {
  const _PlansStrip({
    required this.trialOpen,
    required this.onSelectTrial,
    required this.onSelectPlan,
  });

  final bool trialOpen;
  final VoidCallback onSelectTrial;
  final void Function(String planId) onSelectPlan;

  @override
  Widget build(BuildContext context) {
    final plans = <_PlanChip>[
      if (trialOpen)
        _PlanChip(
          name: '14-day trial',
          price: 'Free',
          detail: '${TrialOffer.includedMinutes} min · ${TrialOffer.spotsLabel}',
          onTap: onSelectTrial,
          emphasize: true,
        ),
      _PlanChip(
        name: 'Starter',
        price: '\$69/mo',
        detail: '400 minutes',
        onTap: () => onSelectPlan('starter'),
        emphasize: !trialOpen,
      ),
      _PlanChip(
        name: 'Growth',
        price: '\$129/mo',
        detail: '850 minutes',
        onTap: () => onSelectPlan('growth'),
      ),
      _PlanChip(
        name: 'Business',
        price: '\$179/mo',
        detail: '1,350 minutes',
        onTap: () => onSelectPlan('business'),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Plans',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
        ),
        const SizedBox(height: 6),
        Text(
          'Overage is \$0.20 per extra minute. Pick a plan to create your account.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: EchoDeskColors.muted,
              ),
        ),
        const SizedBox(height: EchoDeskSpacing.md),
        ...plans.map(
          (p) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: p.emphasize
                  ? EchoDeskColors.brandSoft
                  : EchoDeskColors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(EchoDeskRadii.md),
                side: BorderSide(
                  color: p.emphasize
                      ? EchoDeskColors.brandTeal.withValues(alpha: 0.45)
                      : EchoDeskColors.line,
                ),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(EchoDeskRadii.md),
                onTap: p.onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              p.name,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            Text(
                              p.detail,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: EchoDeskColors.muted),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        p.price,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: EchoDeskColors.brand,
                            ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        Icons.chevron_right,
                        color: EchoDeskColors.soft,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PlanChip {
  const _PlanChip({
    required this.name,
    required this.price,
    required this.detail,
    required this.onTap,
    this.emphasize = false,
  });

  final String name;
  final String price;
  final String detail;
  final VoidCallback onTap;
  final bool emphasize;
}
