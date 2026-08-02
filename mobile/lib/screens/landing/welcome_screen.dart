import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../config/trial_offer.dart';
import '../../services/pending_plan_service.dart';
import '../../theme/echodesk_theme.dart';
import '../../widgets/brand_lockup.dart';

/// First screen before login: clear Create account / Log in (phone + desktop).
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  @override
  void initState() {
    super.initState();
    _refreshTrialSpots();
  }

  Future<void> _refreshTrialSpots() async {
    await TrialOffer.refreshFromApi();
    if (mounted) setState(() {});
  }

  Future<void> _createAccount() async {
    await PendingPlanService.clear();
    if (!mounted) return;
    context.go('/signup');
  }

  @override
  Widget build(BuildContext context) {
    final trialOpen = TrialOffer.hasSpotsRemaining;
    final trialLabel = trialOpen
        ? TrialOffer.spotsLabel
        : 'Trial spots are full — create an account to choose a plan';

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFFF3F7F6),
              EchoDeskColors.background,
              Color(0xFFE8F0EE),
            ],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 900;
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1080),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: wide ? 40 : 24,
                      vertical: wide ? 48 : 28,
                    ),
                    child: wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                  child: _BrandCopy(trialLabel: trialLabel)),
                              const SizedBox(width: 48),
                              SizedBox(
                                width: 380,
                                child: _AuthCard(
                                  trialOpen: trialOpen,
                                  onCreateAccount: _createAccount,
                                  onLogIn: () => context.go('/login'),
                                  onLearnMore: () => context.go('/learn-more'),
                                ),
                              ),
                            ],
                          )
                        : SingleChildScrollView(
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight: constraints.maxHeight - 56,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _BrandCopy(trialLabel: trialLabel),
                                  const SizedBox(height: EchoDeskSpacing.xl),
                                  _AuthCard(
                                    trialOpen: trialOpen,
                                    onCreateAccount: _createAccount,
                                    onLogIn: () => context.go('/login'),
                                    onLearnMore: () =>
                                        context.go('/learn-more'),
                                  ),
                                ],
                              ),
                            ),
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

class _BrandCopy extends StatelessWidget {
  const _BrandCopy({required this.trialLabel});

  final String trialLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const BrandLockup(markSize: 52, centered: false),
        const SizedBox(height: EchoDeskSpacing.xl),
        Text(
          'Your AI receptionist that answers calls and books appointments.',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
                color: EchoDeskColors.ink,
                height: 1.2,
              ),
        ),
        const SizedBox(height: EchoDeskSpacing.md),
        Text(
          'Create an account here in the app — on iPhone, Android, or Mac.',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: EchoDeskColors.muted,
                height: 1.4,
              ),
        ),
        const SizedBox(height: EchoDeskSpacing.lg),
        Text(
          trialLabel,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: EchoDeskColors.brand,
                fontWeight: FontWeight.w600,
              ),
        ),
      ],
    );
  }
}

class _AuthCard extends StatelessWidget {
  const _AuthCard({
    required this.trialOpen,
    required this.onCreateAccount,
    required this.onLogIn,
    required this.onLearnMore,
  });

  final bool trialOpen;
  final VoidCallback onCreateAccount;
  final VoidCallback onLogIn;
  final VoidCallback onLearnMore;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: EchoDeskColors.surface.withValues(alpha: 0.92),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(EchoDeskRadii.lg),
        side: const BorderSide(color: EchoDeskColors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(EchoDeskSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Get started',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: EchoDeskSpacing.xs),
            Text(
              'Create an account in the app — no email signup form on the website.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: EchoDeskColors.muted,
                  ),
            ),
            const SizedBox(height: EchoDeskSpacing.lg),
            FilledButton(
              onPressed: onCreateAccount,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: Text(
                trialOpen ? 'Create account — free trial' : 'Create account',
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
              onPressed: onLearnMore,
              child: const Text('See plans & how it works'),
            ),
          ],
        ),
      ),
    );
  }
}
