import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/receptionist.dart';
import '../../strings.dart';
import '../../services/api_client.dart';
import '../../widgets/constrained_scaffold_body.dart';

class ReceptionistsScreen extends StatefulWidget {
  const ReceptionistsScreen({super.key});

  @override
  State<ReceptionistsScreen> createState() => _ReceptionistsScreenState();
}

class _ReceptionistsScreenState extends State<ReceptionistsScreen> {
  List<Receptionist> _receptionists = [];
  bool _loading = true;
  String? _error;
  bool _isSubscribed = false;
  bool _hasCalendar = false;
  String? _calendarId;

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
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) throw Exception('Not authenticated');

      final supabase = Supabase.instance.client;

      final profileRes = await supabase
          .from('users')
          .select('subscription_status, calendar_id')
          .eq('id', user.id)
          .maybeSingle();

      final subscriptionStatus = profileRes?['subscription_status'] ?? '';
      _isSubscribed =
          subscriptionStatus == 'active' || subscriptionStatus == 'trialing';
      _calendarId = profileRes?['calendar_id'] as String?;
      _hasCalendar = (_calendarId ?? '').trim().isNotEmpty;

      final res = await supabase
          .from('receptionists')
          .select('id, name, phone_number, inbound_phone_number, status')
          .eq('user_id', user.id)
          .order('created_at', ascending: false);

      final list = (res as List)
          .map((e) => Receptionist.fromJson(e as Map<String, dynamic>))
          .toList();

      setState(() {
        _receptionists = list;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _showOutboundCallSheet(BuildContext context, Receptionist r) {
    final controller = TextEditingController();
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Call from ${r.name}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Uses your business line as caller ID.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Phone number',
                hintText: '+15551234567',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () async {
                final to = controller.text.trim();
                if (to.isEmpty) return;
                Navigator.of(ctx).pop();
                try {
                  final res = await ApiClient.post(
                    '/api/telnyx/outbound',
                    body: {'receptionist_id': r.id, 'to': to},
                  );
                  if (res.statusCode >= 200 && res.statusCode < 300) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text(AppStrings.callInitiated)),
                      );
                    }
                  } else {
                    final err = _parseError(res.body);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(err)),
                      );
                    }
                  }
                } catch (_) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text(AppStrings.couldNotStartCall)),
                    );
                  }
                }
              },
              icon: const Icon(Icons.phone),
              label: const Text('Place Call'),
            ),
          ],
        ),
      ),
    );
  }

  String _parseError(String body) {
    try {
      if (body.isEmpty) return 'Request failed';
      final m = jsonDecode(body) as Map<String, dynamic>?;
      if (m != null && m['error'] != null) return m['error'].toString();
    } catch (_) {}
    return body;
  }

  Future<void> _navigateToCreate() async {
    final created = await context.push<bool>('/receptionists/create');
    if (created == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Receptionists'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: constrainedScaffoldBody(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Text('Error: $_error'))
                : !_isSubscribed
                    ? _buildUpgradePrompt()
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 16),
                          children: [
                            _buildCreateStepper(),
                            const SizedBox(height: 24),
                            if (_receptionists.isEmpty)
                              _buildEmptyState()
                            else
                              ..._receptionists.map(
                                (r) => Card(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  child: ListTile(
                                    title: Text(r.name),
                                    subtitle: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          'Uses business line',
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelSmall
                                              ?.copyWith(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                              ),
                                        ),
                                        Text(r.displayPhone),
                                      ],
                                    ),
                                    isThreeLine: true,
                                    trailing: const Icon(Icons.chevron_right),
                                    onTap: () =>
                                        context.push('/receptionists/${r.id}'),
                                    onLongPress: () =>
                                        _showOutboundCallSheet(context, r),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
      ),
    );
  }

  Widget _buildUpgradePrompt() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Upgrade to Pro'),
            const SizedBox(height: 8),
            const Text(
              'You need an active subscription to add receptionists.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => context.go('/dashboard'),
              child: const Text('Go to dashboard'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCreateStepper() {
    final currentStep = !_hasCalendar ? 1 : 2;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Create receptionist'),
            const SizedBox(height: 4),
            const Text(
              'Complete each step. Calendar is required for booking and availability.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _StepCircle(
                  done: currentStep > 1,
                  current: currentStep == 1,
                  label: '1',
                ),
                Expanded(
                  child: Container(
                    height: 2,
                    color:
                        currentStep > 1 ? Colors.green : Colors.grey.shade300,
                  ),
                ),
                _StepCircle(
                  done: false,
                  current: currentStep == 2,
                  label: '2',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Connect Calendar', style: TextStyle(fontSize: 10)),
                const Text('Create Receptionist',
                    style: TextStyle(fontSize: 10)),
              ],
            ),
            const SizedBox(height: 16),
            if (currentStep == 1)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Step 1: Connect Google Calendar'),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: () => context.push('/settings'),
                    child: const Text('Connect in Settings'),
                  ),
                ],
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Step 2: Create your receptionist'),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _navigateToCreate,
                    icon: const Icon(Icons.add),
                    label: const Text('Add Receptionist'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('No receptionists yet.'),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _navigateToCreate,
            icon: const Icon(Icons.add),
            label: const Text('Create Receptionist'),
          ),
        ],
      ),
    );
  }
}

class _StepCircle extends StatelessWidget {
  final bool done;
  final bool current;
  final String label;

  const _StepCircle({
    required this.done,
    required this.current,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 16,
      backgroundColor: done
          ? Colors.green
          : current
              ? Theme.of(context).colorScheme.primary
              : Colors.grey.shade300,
      child: Text(
        done ? '✓' : label,
        style: TextStyle(
          color: done || current ? Colors.white : Colors.grey.shade700,
          fontSize: 12,
        ),
      ),
    );
  }
}
