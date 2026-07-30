import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/receptionist.dart';
import '../../strings.dart';
import '../../services/api_client.dart';
import '../../theme/echodesk_theme.dart';
import '../../widgets/constrained_scaffold_body.dart';
import '../../widgets/loading_skeleton.dart';
import '../../widgets/state_views.dart';

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
          .select(
              'id, name, phone_number, inbound_phone_number, status, deleted_at')
          .eq('user_id', user.id)
          .order('created_at', ascending: false);

      final list = (res as List)
          .where((e) => (e as Map)['deleted_at'] == null)
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
    final showFirstTimeOnboarding =
        _isSubscribed && _receptionists.isEmpty && !_loading && _error == null;
    final showAddFab = _isSubscribed &&
        _receptionists.isNotEmpty &&
        !_loading &&
        _error == null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Receptionists'),
        actions: [
          if (showAddFab)
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: 'Add receptionist',
              onPressed: _navigateToCreate,
            ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      floatingActionButton: showAddFab
          ? FloatingActionButton.extended(
              onPressed: _navigateToCreate,
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            )
          : null,
      body: constrainedScaffoldBody(
        child: _loading
            ? const ListLoadingView()
            : _error != null
                ? Center(
                    child: ErrorStateView(
                      title: 'Could not load receptionists',
                      message: _error,
                      onRetry: _load,
                    ),
                  )
                : !_isSubscribed
                    ? _buildUpgradePrompt()
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 16),
                          children: [
                            if (showFirstTimeOnboarding) ...[
                              _buildCreateStepper(),
                              const SizedBox(height: 24),
                            ],
                            if (_receptionists.isEmpty)
                              _buildEmptyState()
                            else ...[
                              Text(
                                'Tap the phone icon or long-press a row to place an outbound call. '
                                'New receptionists share your existing business number.',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: EchoDeskColors.soft),
                              ),
                              const SizedBox(height: EchoDeskSpacing.sm),
                              ..._receptionists.map((r) {
                                final isActive =
                                    r.status == null || r.status == 'active';
                                return Card(
                                  margin: const EdgeInsets.only(bottom: 6),
                                  child: ListTile(
                                    dense: true,
                                    visualDensity: VisualDensity.compact,
                                    contentPadding:
                                        const EdgeInsets.symmetric(
                                            horizontal: 14, vertical: 6),
                                    title: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            r.name,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodyMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: isActive
                                                ? EchoDeskColors.successSoft
                                                : EchoDeskColors.surfaceMuted,
                                            borderRadius:
                                                BorderRadius.circular(
                                                    EchoDeskRadii.sm),
                                          ),
                                          child: Text(
                                            r.status ?? 'active',
                                            style: TextStyle(
                                              fontSize: MediaQuery
                                                      .textScalerOf(context)
                                                  .clamp(
                                                    minScaleFactor: 1.0,
                                                    maxScaleFactor: 1.4,
                                                  )
                                                  .scale(11)
                                                  .clamp(11.0, 16.0),
                                              fontWeight: FontWeight.w600,
                                              color: isActive
                                                  ? EchoDeskColors.success
                                                  : EchoDeskColors.muted,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    subtitle: Text(
                                      r.displayPhone,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: EchoDeskColors.muted,
                                          ),
                                    ),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          icon: const Icon(
                                            Icons.phone_outlined,
                                            size: 20,
                                          ),
                                          tooltip: 'Place outbound call',
                                          visualDensity: VisualDensity.compact,
                                          onPressed: () =>
                                              _showOutboundCallSheet(
                                                  context, r),
                                        ),
                                        Icon(
                                          Icons.chevron_right,
                                          size: 18,
                                          color: EchoDeskColors.soft,
                                        ),
                                      ],
                                    ),
                                    onTap: () =>
                                        context.push('/receptionists/${r.id}'),
                                    onLongPress: () =>
                                        _showOutboundCallSheet(context, r),
                                  ),
                                );
                              }),
                              const SizedBox(height: 72),
                            ],
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
            const Text('Subscribe to continue'),
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
        padding: const EdgeInsets.all(EchoDeskSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Create receptionist',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: EchoDeskSpacing.xs),
            Text(
              'Complete each step. Calendar is required for booking and availability.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: EchoDeskColors.muted,
                  ),
            ),
            const SizedBox(height: EchoDeskSpacing.md),
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
                    color: currentStep > 1
                        ? EchoDeskColors.success
                        : EchoDeskColors.line,
                  ),
                ),
                _StepCircle(
                  done: false,
                  current: currentStep == 2,
                  label: '2',
                ),
              ],
            ),
            const SizedBox(height: EchoDeskSpacing.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Connect Calendar',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: EchoDeskColors.muted,
                      ),
                ),
                Text(
                  'Create Receptionist',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: EchoDeskColors.muted,
                      ),
                ),
              ],
            ),
            const SizedBox(height: EchoDeskSpacing.md),
            if (currentStep == 1)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Step 1: Connect Google Calendar',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: EchoDeskSpacing.sm),
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
                  Text(
                    'Step 2: Create your receptionist',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: EchoDeskSpacing.sm),
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
    return EmptyStateView(
      icon: Icons.support_agent,
      title: 'No receptionists yet',
      subtitle: 'Create your first AI receptionist to answer on your business line.',
      action: FilledButton.icon(
        onPressed: _navigateToCreate,
        icon: const Icon(Icons.add),
        label: const Text('Create Receptionist'),
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
          ? EchoDeskColors.success
          : current
              ? EchoDeskColors.brand
              : EchoDeskColors.surfaceMuted,
      child: Text(
        done ? '✓' : label,
        style: TextStyle(
          color: done || current ? Colors.white : EchoDeskColors.muted,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
