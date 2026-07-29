import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/api_client.dart';
import '../../strings.dart';
import '../../theme/echodesk_theme.dart';
import '../../widgets/confirm_sign_out.dart';
import '../../widgets/constrained_scaffold_body.dart';

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
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
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
      setState(() {
        _hasCalendar = data['hasCalendar'] == true;
        _hasPhone = data['hasBusinessPhoneNumber'] == true;
        _isSubscribed = data['hasActiveSubscription'] == true;
        _hasReceptionist = data['hasReceptionist'] == true;
        _testCallNumber = phone;
        _loading = false;
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

  Future<void> _completeOnboarding() async {
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
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Finish setup')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _load,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final currentStep = !_hasCalendar
        ? 1
        : !_hasReceptionist
            ? 2
            : !_hasPhone
                ? 3
                : 4;

    const steps = [
      ('Connect Calendar', Icons.calendar_today),
      ('Create Receptionist', Icons.person_add),
      ('Test Call', Icons.phone_in_talk),
      ('Done', Icons.check_circle),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Finish setup'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => context.push('/settings'),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => confirmSignOut(context),
          ),
        ],
      ),
      body: constrainedScaffoldBody(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              currentStep == 4
                  ? 'Your AI receptionist is set up and ready for callers.'
                  : 'Complete these steps to get the most out of your AI receptionist.',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 24),
            _buildStepper(steps, currentStep),
            const SizedBox(height: 24),
            if (currentStep == 1) _buildCalendarStep(),
            if (currentStep == 2) _buildCreateReceptionistStep(context),
            if (currentStep == 3) _buildTestCallStep(context),
            if (currentStep == 4) _buildReadyStep(context),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildStepper(List<(String, IconData)> steps, int current) {
    return Row(
      children: [
        for (var i = 0; i < steps.length; i++) ...[
          CircleAvatar(
            radius: 16,
            backgroundColor: i + 1 < current
                ? EchoDeskColors.success
                : i + 1 == current
                    ? Theme.of(context).colorScheme.primary
                    : EchoDeskColors.lineStrong,
            child: Text(
              i + 1 < current ? '✓' : '${i + 1}',
              style: TextStyle(
                color: i + 1 <= current ? Colors.white : EchoDeskColors.muted,
                fontSize: 12,
              ),
            ),
          ),
          if (i < steps.length - 1)
            Expanded(
              child: Container(
                height: 2,
                color: i + 1 < current
                    ? EchoDeskColors.success
                    : EchoDeskColors.lineStrong,
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildCalendarStep() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '1. Connect Google Calendar',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Required for booking and availability.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            if (_hasCalendar)
              const Row(
                children: [
                  Icon(Icons.check_circle, color: EchoDeskColors.success),
                  SizedBox(width: 8),
                  Text('Calendar connected'),
                ],
              )
            else
              FilledButton(
                onPressed: _connectCalendar,
                child: const Text('Connect Google Calendar'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCreateReceptionistStep(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '2. Create your first receptionist',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Set up the assistant that will answer on your business line.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            if (_hasReceptionist)
              const Row(
                children: [
                  Icon(Icons.check_circle, color: EchoDeskColors.success),
                  SizedBox(width: 8),
                  Text('Receptionist created'),
                ],
              )
            else if (_isSubscribed)
              FilledButton(
                onPressed: () async {
                  final created =
                      await context.push<bool>('/receptionists/create');
                  if (created == true) _load();
                },
                child: const Text('Create Receptionist'),
              )
            else
              Row(
                children: [
                  const Expanded(
                    child: Text('You need an active subscription.'),
                  ),
                  TextButton(
                    onPressed: () => context.push('/dashboard'),
                    child: const Text('Upgrade first'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// Step 3: try the line — not the final Done state.
  Widget _buildTestCallStep(BuildContext context) {
    final hasNumber =
        _testCallNumber != null && _testCallNumber!.trim().isNotEmpty;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '3. Test call',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Call your AI receptionist to hear it in action.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            if (hasNumber) ...[
              Text(
                'Your business line — give this number to customers so they can call and book.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _testCallNumber!,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!_isPhoneDevice)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Call this number from your phone to test the AI.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (_isPhoneDevice)
                    FilledButton.icon(
                      onPressed: _dialTestCall,
                      icon: const Icon(Icons.phone),
                      label: const Text('Test call'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: _copyNumber,
                      icon: const Icon(Icons.copy),
                      label: const Text('Copy number'),
                    ),
                  OutlinedButton.icon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Refresh'),
                  ),
                ],
              ),
            ] else if (_hasReceptionist) ...[
              Text(
                'Your number will appear shortly. Pull to refresh or check Receptionists.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh status'),
              ),
            ] else
              Text(
                'Create a receptionist first.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
          ],
        ),
      ),
    );
  }

  /// Step 4: distinct Done / “You’re ready” — not a reuse of the test-call card.
  Widget _buildReadyStep(BuildContext context) {
    final hasNumber =
        _testCallNumber != null && _testCallNumber!.trim().isNotEmpty;

    return Card(
      color: EchoDeskColors.successSoft.withValues(alpha: 0.45),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(
              Icons.check_circle_rounded,
              size: 56,
              color: EchoDeskColors.success,
            ),
            const SizedBox(height: 16),
            Text(
              'You’re ready',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Calendar, receptionist, and business line are set. '
              'Your assistant can answer calls and book appointments.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
            if (hasNumber) ...[
              const SizedBox(height: 20),
              Text(
                'Business line',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                _testCallNumber!,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _completeOnboarding,
              child: const Text('Go to dashboard'),
            ),
            if (hasNumber) ...[
              const SizedBox(height: 8),
              if (_isPhoneDevice)
                TextButton.icon(
                  onPressed: _dialTestCall,
                  icon: const Icon(Icons.phone_outlined, size: 18),
                  label: const Text('Make a test call'),
                )
              else
                TextButton.icon(
                  onPressed: _copyNumber,
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy business number'),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
