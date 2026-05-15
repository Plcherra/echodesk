import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/api_client.dart';
import '../../strings.dart';

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
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;
    await Supabase.instance.client
        .from('users')
        .update({
          'onboarding_completed_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        })
        .eq('id', user.id)
        .isFilter('onboarding_completed_at', null);
    if (mounted) context.go('/dashboard');
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
            onPressed: () => Supabase.instance.client.auth.signOut(),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Complete these steps to get the most out of your AI receptionist.',
          ),
          const SizedBox(height: 24),
          _buildStepper(steps, currentStep),
          const SizedBox(height: 24),
          if (currentStep == 1) _buildStep1(),
          if (currentStep == 2) _buildStep3(context),
          if (currentStep == 3) _buildStep4(context),
          if (currentStep == 4) _buildStep4(context),
          const SizedBox(height: 24),
          TextButton(
            onPressed: _completeOnboarding,
            child: const Text("I'll do this later"),
          ),
        ],
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
                ? Colors.green
                : i + 1 == current
                    ? Theme.of(context).colorScheme.primary
                    : Colors.grey.shade300,
            child: Text(
              i + 1 < current ? '✓' : '${i + 1}',
              style: TextStyle(
                color: i + 1 <= current ? Colors.white : Colors.grey.shade700,
                fontSize: 12,
              ),
            ),
          ),
          if (i < steps.length - 1)
            Expanded(
              child: Container(
                height: 2,
                color: i + 1 < current ? Colors.green : Colors.grey.shade300,
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildStep1() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('1. Connect Google Calendar'),
            const SizedBox(height: 8),
            const Text(
              'Required for booking and availability.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            if (_hasCalendar)
              const Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.green),
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

  Widget _buildStep3(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('2. Create your first receptionist'),
            const SizedBox(height: 8),
            const Text(
              'Set up the assistant that will answer your business number.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            if (_hasReceptionist)
              const Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.green),
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
                  const Text('You need an active subscription. '),
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

  Widget _buildStep4(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('3. Test call'),
            const SizedBox(height: 8),
            const Text(
              'Call your AI receptionist to hear it in action.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            if (_testCallNumber != null && _testCallNumber!.isNotEmpty)
              Column(
                children: [
                  const Text(
                    'Your business number — give this to customers so they can call and book.',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _testCallNumber!,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  if (!_isPhoneDevice)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Call this number from your phone to test the AI.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      if (_isPhoneDevice)
                        FilledButton.icon(
                          onPressed: () => launchUrl(
                            Uri.parse('tel:$_testCallNumber'),
                            mode: LaunchMode.externalApplication,
                          ),
                          icon: const Icon(Icons.phone),
                          label: const Text('Test call'),
                        )
                      else
                        FilledButton.icon(
                          onPressed: () {
                            Clipboard.setData(
                              ClipboardData(text: _testCallNumber ?? ''),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Copied!')),
                            );
                          },
                          icon: const Icon(Icons.copy),
                          label: const Text('Copy'),
                        ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _completeOnboarding,
                        child: const Text('Go to dashboard'),
                      ),
                    ],
                  ),
                ],
              )
            else if (_hasReceptionist)
              const Text(
                'Your number will appear shortly. Refresh or check Receptionists.',
              )
            else
              const Text('Create a receptionist first.'),
          ],
        ),
      ),
    );
  }
}
