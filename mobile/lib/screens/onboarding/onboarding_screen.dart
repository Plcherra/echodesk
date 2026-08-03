import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/trial_offer.dart';
import '../../services/api_client.dart';
import '../../strings.dart';
import '../../theme/echodesk_theme.dart';
import '../../widgets/brand_lockup.dart';
import '../../widgets/confirm_sign_out.dart';
import '../../widgets/constrained_scaffold_body.dart';
import '../../widgets/state_views.dart';

enum _OnboardingPhase {
  welcome,
  calendar,
  assistant,
  testCall,
  ready,
}

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  bool get _isPhoneDevice =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  bool _hasCalendar = false;
  bool _hasPhone = false;
  bool _hasReceptionist = false;
  String? _testCallNumber;
  bool _isSubscribed = false;
  String? _subscriptionStatus;
  String? _apiCurrentStep;
  String? _error;
  bool _loading = true;
  bool _welcomeSeen = false;
  bool _testAcknowledged = false;
  bool _completing = false;
  bool _handledCalendarReturn = false;
  int _phaseAnimKey = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final calendar = GoRouterState.of(context).uri.queryParameters['calendar'];
    if (calendar == 'connected' && !_handledCalendarReturn) {
      _handledCalendarReturn = true;
      _welcomeSeen = true;
      _load().then((_) {
        if (!mounted) return;
        // Drop the query so we don't loop.
        context.go('/onboarding');
      });
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiClient.get('/api/mobile/onboarding-status');
      if (res.statusCode < 200 || res.statusCode >= 300) {
        final data = _parseJson(res.body);
        throw Exception(data['error'] as String? ?? 'Could not load setup');
      }
      final data = _parseJson(res.body);
      final phone = data['phoneNumber'] as String?;
      if (!mounted) return;
      final hasCalendar = data['hasCalendar'] == true;
      final hasReceptionist = data['hasReceptionist'] == true;
      setState(() {
        _hasCalendar = hasCalendar;
        _hasPhone = data['hasBusinessPhoneNumber'] == true;
        _isSubscribed = data['hasActiveSubscription'] == true;
        _subscriptionStatus = data['subscriptionStatus'] as String?;
        _hasReceptionist = hasReceptionist;
        _testCallNumber = phone;
        _apiCurrentStep = data['currentStep'] as String?;
        // Resume mid-setup without forcing the welcome screen again.
        if (hasCalendar || hasReceptionist) {
          _welcomeSeen = true;
        }
        _loading = false;
        _phaseAnimKey++;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Map<String, dynamic> _parseJson(String body) {
    try {
      return body.isNotEmpty
          ? jsonDecode(body) as Map<String, dynamic>
          : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  _OnboardingPhase get _phase {
    if (!_welcomeSeen) return _OnboardingPhase.welcome;

    // Prefer live flags; API currentStep is a hint (subscribe/create map to assistant).
    if (!_hasCalendar || _apiCurrentStep == 'connect_calendar') {
      return _OnboardingPhase.calendar;
    }
    if (!_isSubscribed ||
        _apiCurrentStep == 'subscribe' ||
        !_hasReceptionist ||
        _apiCurrentStep == 'create_receptionist') {
      if (_hasReceptionist && _isSubscribed) {
        // Fall through to test call.
      } else {
        return _OnboardingPhase.assistant;
      }
    }
    // Show test-call with the number before the celebration screen.
    if (!_testAcknowledged) {
      return _OnboardingPhase.testCall;
    }
    if (_hasPhone && _hasReceptionist && _hasCalendar && _isSubscribed) {
      return _OnboardingPhase.ready;
    }
    return _OnboardingPhase.testCall;
  }

  int get _railIndex {
    switch (_phase) {
      case _OnboardingPhase.welcome:
        return 0;
      case _OnboardingPhase.calendar:
        return 0;
      case _OnboardingPhase.assistant:
        return 1;
      case _OnboardingPhase.testCall:
        return 2;
      case _OnboardingPhase.ready:
        return 3;
    }
  }

  bool get _isTrialing =>
      (_subscriptionStatus ?? '').toLowerCase() == 'trialing';

  Future<void> _connectCalendar() async {
    try {
      final res = await ApiClient.get(
        '/api/mobile/google-auth-url',
        queryParams: {'return_to': 'mobile'},
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final url = data['url'] as String?;
        if (url != null && await canLaunchUrl(Uri.parse(url))) {
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        }
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(AppStrings.couldNotConnectCalendar)),
        );
      }
    }
  }

  Future<void> _openCreateAssistant() async {
    final created = await context.push<bool>('/receptionists/create?firstRun=1');
    if (!mounted) return;
    await _load();
    if (created == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Assistant created — next, try a test call')),
      );
    }
  }

  Future<void> _completeOnboarding() async {
    setState(() => _completing = true);
    try {
      final res = await ApiClient.post(
        '/api/mobile/onboarding/complete',
        body: const {},
      );
      final data = _parseJson(res.body);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        final missing = (data['missing'] as List?)
                ?.map((item) => item.toString())
                .join(', ') ??
            '';
        throw Exception(
          missing.isEmpty
              ? data['error'] as String? ?? 'Setup is not complete yet.'
              : 'Finish setup first: $missing',
        );
      }
      if (mounted) context.go('/dashboard');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
      await _load();
    } finally {
      if (mounted) setState(() => _completing = false);
    }
  }

  Future<void> _dialTestCall() async {
    final number = _testCallNumber;
    if (number == null || number.isEmpty) return;
    await launchUrl(
      Uri.parse('tel:$number'),
      mode: LaunchMode.externalApplication,
    );
  }

  void _copyNumber() {
    final number = _testCallNumber;
    if (number == null || number.isEmpty) return;
    Clipboard.setData(ClipboardData(text: number));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Number copied')),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _apiCurrentStep == null && _error == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null && _apiCurrentStep == null && !_hasCalendar) {
      return Scaffold(
        appBar: AppBar(title: const Text('Setup')),
        body: Center(
          child: ErrorStateView(
            title: 'Could not load setup',
            message: _error,
            onRetry: _load,
          ),
        ),
      );
    }

    final phase = _phase;

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
          child: constrainedScaffoldBody(
            child: RefreshIndicator(
              onRefresh: _load,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 12, 0),
                      child: Row(
                        children: [
                          const Expanded(
                            child: BrandLockup(markSize: 32, centered: false),
                          ),
                          if (_isSubscribed)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: _TrialChip(isTrialing: _isTrialing),
                            ),
                          PopupMenuButton<String>(
                            tooltip: 'Account',
                            onSelected: (value) {
                              if (value == 'signout') {
                                confirmSignOut(context);
                              }
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: 'signout',
                                child: Text('Sign out'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (phase != _OnboardingPhase.welcome)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                        child: _StepRail(activeIndex: _railIndex),
                      ),
                    ),
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 320),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) {
                          final offset = Tween<Offset>(
                            begin: const Offset(0.04, 0.06),
                            end: Offset.zero,
                          ).animate(animation);
                          return FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              position: offset,
                              child: child,
                            ),
                          );
                        },
                        child: KeyedSubtree(
                          key: ValueKey('${phase.name}_$_phaseAnimKey'),
                          child: _buildPhaseBody(phase),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPhaseBody(_OnboardingPhase phase) {
    switch (phase) {
      case _OnboardingPhase.welcome:
        return _WelcomeBody(
          isTrialing: _isTrialing || _isSubscribed,
          onStart: () => setState(() {
            _welcomeSeen = true;
            _phaseAnimKey++;
          }),
        );
      case _OnboardingPhase.calendar:
        return _StepBody(
          kicker: 'Step 1 of 4',
          headline: 'Connect Google Calendar',
          body:
              'EchoDesk checks real availability and books appointments on your calendar — no double-booking.',
          footnote: 'We only use the calendar you choose for booking.',
          primaryLabel: 'Connect Google Calendar',
          onPrimary: _connectCalendar,
          secondaryLabel: 'I’ve connected — refresh',
          onSecondary: _load,
        );
      case _OnboardingPhase.assistant:
        if (!_isSubscribed) {
          return _StepBody(
            kicker: 'Step 2 of 4',
            headline: 'Activate your plan to continue',
            body:
                'Create your AI receptionist after choosing a plan — or claim a launch trial spot if one is still open.',
            footnote: 'Takes about a minute. No long-term contract.',
            primaryLabel: 'Choose a plan',
            onPrimary: () => context.push('/checkout'),
            secondaryLabel: 'Refresh status',
            onSecondary: _load,
          );
        }
        return _StepBody(
          kicker: 'Step 2 of 4',
          headline: 'Create your AI receptionist',
          body:
              'Name your assistant, pick a voice, and get a US business number that answers and books for you.',
          footnote: 'About 3 minutes. You can change details later.',
          primaryLabel: 'Create your AI receptionist',
          onPrimary: _openCreateAssistant,
          secondaryLabel: 'Refresh status',
          onSecondary: _load,
        );
      case _OnboardingPhase.testCall:
        return _TestCallBody(
          phoneNumber: _testCallNumber,
          isPhoneDevice: _isPhoneDevice,
          onDial: _dialTestCall,
          onCopy: _copyNumber,
          onRefresh: _load,
          showContinue: _hasPhone,
          onContinue: () => setState(() {
            _testAcknowledged = true;
            _phaseAnimKey++;
          }),
        );
      case _OnboardingPhase.ready:
        return _ReadyBody(
          phoneNumber: _testCallNumber,
          isPhoneDevice: _isPhoneDevice,
          completing: _completing,
          onComplete: _completeOnboarding,
          onDial: _dialTestCall,
          onCopy: _copyNumber,
        );
    }
  }
}

class _TrialChip extends StatelessWidget {
  const _TrialChip({required this.isTrialing});

  final bool isTrialing;

  @override
  Widget build(BuildContext context) {
    final label = isTrialing
        ? '${TrialOffer.trialDays}-day trial · ${TrialOffer.includedMinutes} min'
        : 'Active';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: EchoDeskColors.brandSoft,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: EchoDeskColors.line),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: EchoDeskColors.brand,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _StepRail extends StatelessWidget {
  const _StepRail({required this.activeIndex});

  final int activeIndex;

  static const _labels = ['Calendar', 'Assistant', 'Test call', 'Ready'];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < _labels.length; i++) ...[
          Expanded(
            child: Column(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 240),
                  height: 4,
                  decoration: BoxDecoration(
                    color: i <= activeIndex
                        ? EchoDeskColors.brandTeal
                        : EchoDeskColors.lineStrong,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _labels[i],
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: i <= activeIndex
                            ? EchoDeskColors.ink
                            : EchoDeskColors.soft,
                        fontWeight:
                            i == activeIndex ? FontWeight.w700 : FontWeight.w500,
                      ),
                ),
              ],
            ),
          ),
          if (i < _labels.length - 1) const SizedBox(width: 8),
        ],
      ],
    );
  }
}

class _WelcomeBody extends StatelessWidget {
  const _WelcomeBody({
    required this.isTrialing,
    required this.onStart,
  });

  final bool isTrialing;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(flex: 2),
        const BrandLockup(markSize: 56, centered: true),
        const SizedBox(height: EchoDeskSpacing.xl),
        Text(
          isTrialing
              ? 'Your ${TrialOffer.trialDays}-day trial is ready'
              : 'Welcome to EchoDesk',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
                height: 1.15,
              ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: EchoDeskSpacing.md),
        Text(
          'In a few minutes you’ll have an AI receptionist that answers calls and books from your real calendar.',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: EchoDeskColors.muted,
                fontWeight: FontWeight.w400,
                height: 1.4,
              ),
          textAlign: TextAlign.center,
        ),
        const Spacer(flex: 3),
        FilledButton(
          onPressed: onStart,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
          ),
          child: const Text('Start setup'),
        ),
        const SizedBox(height: EchoDeskSpacing.sm),
        Text(
          'Calendar → assistant → test call. About 5 minutes.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: EchoDeskColors.soft,
              ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _StepBody extends StatelessWidget {
  const _StepBody({
    required this.kicker,
    required this.headline,
    required this.body,
    required this.primaryLabel,
    required this.onPrimary,
    this.footnote,
    this.secondaryLabel,
    this.onSecondary,
  });

  final String kicker;
  final String headline;
  final String body;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final String? footnote;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          kicker,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: EchoDeskColors.brandTeal,
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: EchoDeskSpacing.sm),
        Text(
          headline,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
                height: 1.15,
              ),
        ),
        const SizedBox(height: EchoDeskSpacing.md),
        Text(
          body,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: EchoDeskColors.muted,
                height: 1.45,
              ),
        ),
        const Spacer(),
        if (footnote != null) ...[
          Text(
            footnote!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: EchoDeskColors.soft,
                ),
          ),
          const SizedBox(height: EchoDeskSpacing.md),
        ],
        FilledButton(
          onPressed: onPrimary,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
          ),
          child: Text(primaryLabel),
        ),
        if (secondaryLabel != null && onSecondary != null) ...[
          const SizedBox(height: EchoDeskSpacing.sm),
          TextButton(
            onPressed: onSecondary,
            child: Text(secondaryLabel!),
          ),
        ],
      ],
    );
  }
}

class _TestCallBody extends StatelessWidget {
  const _TestCallBody({
    required this.phoneNumber,
    required this.isPhoneDevice,
    required this.onDial,
    required this.onCopy,
    required this.onRefresh,
    required this.onContinue,
    required this.showContinue,
  });

  final String? phoneNumber;
  final bool isPhoneDevice;
  final VoidCallback onDial;
  final VoidCallback onCopy;
  final Future<void> Function() onRefresh;
  final VoidCallback onContinue;
  final bool showContinue;

  @override
  Widget build(BuildContext context) {
    final hasNumber = phoneNumber != null && phoneNumber!.trim().isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Step 3 of 4',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: EchoDeskColors.brandTeal,
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: EchoDeskSpacing.sm),
        Text(
          'Make a test call',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
                height: 1.15,
              ),
        ),
        const SizedBox(height: EchoDeskSpacing.md),
        Text(
          hasNumber
              ? 'Call your new business line and ask to book an appointment. Hear how your assistant answers.'
              : 'Your number is almost ready. Refresh in a moment — provisioning usually takes a few seconds.',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: EchoDeskColors.muted,
                height: 1.45,
              ),
        ),
        const SizedBox(height: EchoDeskSpacing.xl),
        if (hasNumber) ...[
          Text(
            'Your business line',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: EchoDeskColors.soft,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            phoneNumber!,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                ),
          ),
          const SizedBox(height: EchoDeskSpacing.md),
          Text(
            'Tip: say “I’d like to book a haircut tomorrow morning.”',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: EchoDeskColors.soft,
                ),
          ),
          const Spacer(),
          if (isPhoneDevice)
            FilledButton.icon(
              onPressed: onDial,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              icon: const Icon(Icons.phone),
              label: const Text('Call now'),
            )
          else
            FilledButton.icon(
              onPressed: onCopy,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              icon: const Icon(Icons.copy),
              label: const Text('Copy number'),
            ),
          const SizedBox(height: EchoDeskSpacing.sm),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onRefresh,
                  child: const Text('Refresh'),
                ),
              ),
              if (showContinue) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: onContinue,
                    child: const Text('I’m done testing'),
                  ),
                ),
              ],
            ],
          ),
        ] else ...[
          const Spacer(),
          FilledButton.icon(
            onPressed: onRefresh,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh status'),
          ),
        ],
      ],
    );
  }
}

class _ReadyBody extends StatelessWidget {
  const _ReadyBody({
    required this.phoneNumber,
    required this.isPhoneDevice,
    required this.completing,
    required this.onComplete,
    required this.onDial,
    required this.onCopy,
  });

  final String? phoneNumber;
  final bool isPhoneDevice;
  final bool completing;
  final VoidCallback onComplete;
  final VoidCallback onDial;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final hasNumber = phoneNumber != null && phoneNumber!.trim().isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(flex: 1),
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.85, end: 1),
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutBack,
          builder: (context, scale, child) => Transform.scale(
            scale: scale,
            child: child,
          ),
          child: const Icon(
            Icons.check_circle_rounded,
            size: 72,
            color: EchoDeskColors.success,
          ),
        ),
        const SizedBox(height: EchoDeskSpacing.lg),
        Text(
          'You’re live',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
              ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: EchoDeskSpacing.md),
        Text(
          'Calendar, assistant, and business line are ready. Callers can reach you — and book — anytime.',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: EchoDeskColors.muted,
                height: 1.45,
              ),
          textAlign: TextAlign.center,
        ),
        if (hasNumber) ...[
          const SizedBox(height: EchoDeskSpacing.xl),
          Text(
            'Business line',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: EchoDeskColors.soft,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            phoneNumber!,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: EchoDeskSpacing.md),
        Text(
          'Share this number with customers — or forward your existing line later in Settings.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: EchoDeskColors.soft,
              ),
          textAlign: TextAlign.center,
        ),
        const Spacer(flex: 2),
        FilledButton(
          onPressed: completing ? null : onComplete,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
          ),
          child: completing
              ? const SizedBox(
                  height: 22,
                  width: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Go to dashboard'),
        ),
        if (hasNumber) ...[
          const SizedBox(height: EchoDeskSpacing.sm),
          if (isPhoneDevice)
            TextButton.icon(
              onPressed: onDial,
              icon: const Icon(Icons.phone_outlined, size: 18),
              label: const Text('Make a test call'),
            )
          else
            TextButton.icon(
              onPressed: onCopy,
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy business number'),
            ),
        ],
      ],
    );
  }
}
