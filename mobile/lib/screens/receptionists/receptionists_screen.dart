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
  List<Map<String, dynamic>> _pendingRelease = [];
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

      var pending = <Map<String, dynamic>>[];
      try {
        final pendingRes =
            await ApiClient.get('/api/mobile/phone-numbers/pending-release');
        if (pendingRes.statusCode >= 200 && pendingRes.statusCode < 300) {
          final data = jsonDecode(pendingRes.body) as Map<String, dynamic>?;
          final nums = data?['numbers'] as List<dynamic>? ?? [];
          pending = nums
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        }
      } catch (_) {
        // Banner is best-effort; list still loads.
      }

      setState(() {
        _receptionists = list;
        _pendingRelease = pending;
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

  String _pendingDisplay(Map<String, dynamic> item) {
    final pretty = (item['phone_display'] as String?)?.trim();
    if (pretty != null && pretty.isNotEmpty) return pretty;
    return (item['phone_number'] as String? ?? '').trim();
  }

  @override
  Widget build(BuildContext context) {
    final isEmpty = _receptionists.isEmpty;
    final hasPending = _pendingRelease.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Receptionists'),
        actions: [
          if (!isEmpty)
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
                              horizontal: 24, vertical: 20),
                          children: [
                            if (isEmpty)
                              _buildEmptyComposition(
                                hasPending: hasPending,
                              )
                            else ...[
                              if (hasPending) ...[
                                ..._pendingRelease.map(
                                  (item) => Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: _buildPendingCompact(item),
                                  ),
                                ),
                              ],
                              Text(
                                'Tap the phone icon or long-press a row to place an outbound call.',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: EchoDeskColors.soft),
                              ),
                              const SizedBox(height: EchoDeskSpacing.md),
                              ..._receptionists.map(_buildReceptionistTile),
                              const SizedBox(height: 72),
                            ],
                          ],
                        ),
                      ),
      ),
    );
  }

  /// One composition for the empty page — single story, single primary CTA.
  Widget _buildEmptyComposition({required bool hasPending}) {
    if (!_hasCalendar) {
      return _buildSetupCard(
        title: 'Connect calendar first',
        body:
            'Google Calendar is required for booking and availability before you create a receptionist.',
        ctaLabel: 'Connect in Settings',
        onPressed: () => context.push('/settings'),
        trailingNote: hasPending && _pendingRelease.isNotEmpty
            ? 'Your number ${_pendingDisplay(_pendingRelease.first)} is held until you finish setup.'
            : null,
      );
    }

    if (hasPending) {
      final item = _pendingRelease.first;
      final display = _pendingDisplay(item);
      return _buildSetupCard(
        eyebrow: 'Number held · release pending',
        title: display.isNotEmpty ? display : 'Number held',
        body: AppStrings.pendingReleaseSubtitle,
        ctaLabel: AppStrings.pendingReleaseCta,
        onPressed: _navigateToCreate,
        emphasizeTitle: true,
      );
    }

    return _buildSetupCard(
      title: 'No receptionists yet',
      body:
          'Create your first AI receptionist to answer on your business line and book appointments.',
      ctaLabel: 'Create receptionist',
      onPressed: _navigateToCreate,
      showIcon: true,
    );
  }

  Widget _buildSetupCard({
    String? eyebrow,
    required String title,
    required String body,
    required String ctaLabel,
    required VoidCallback onPressed,
    String? trailingNote,
    bool emphasizeTitle = false,
    bool showIcon = false,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(22, 28, 22, 24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFFF7F4F0),
            Color(0xFFEEF4F4),
          ],
        ),
        borderRadius: BorderRadius.circular(EchoDeskRadii.lg),
        border: Border.all(color: EchoDeskColors.line.withValues(alpha: 0.85)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showIcon) ...[
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: EchoDeskColors.brandSoft,
                borderRadius: BorderRadius.circular(EchoDeskRadii.md),
              ),
              child: const Icon(
                Icons.support_agent,
                color: EchoDeskColors.brand,
                size: 28,
              ),
            ),
            const SizedBox(height: 18),
          ],
          if (eyebrow != null) ...[
            Text(
              eyebrow.toUpperCase(),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: EchoDeskColors.soft,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.7,
                  ),
            ),
            const SizedBox(height: 10),
          ],
          Text(
            title,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: emphasizeTitle ? 0.15 : -0.2,
                  height: 1.15,
                  color: EchoDeskColors.ink,
                ),
          ),
          const SizedBox(height: 10),
          Text(
            body,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: EchoDeskColors.muted,
                  height: 1.45,
                ),
          ),
          if (trailingNote != null) ...[
            const SizedBox(height: 12),
            Text(
              trailingNote,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: EchoDeskColors.soft,
                    height: 1.4,
                  ),
            ),
          ],
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onPressed,
              child: Text(ctaLabel),
            ),
          ),
        ],
      ),
    );
  }

  /// Quiet strip when the list already has receptionists — no extra create button.
  Widget _buildPendingCompact(Map<String, dynamic> item) {
    final display = _pendingDisplay(item);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: EchoDeskColors.surfaceSoft,
        borderRadius: BorderRadius.circular(EchoDeskRadii.md),
        border: Border.all(color: EchoDeskColors.line),
      ),
      child: Row(
        children: [
          const Icon(Icons.phone_paused_outlined,
              size: 18, color: EchoDeskColors.brand),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  display.isNotEmpty ? display : AppStrings.pendingReleaseTitle,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                Text(
                  'Release pending — unused in 24–48 hours',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: EchoDeskColors.soft,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReceptionistTile(Receptionist r) {
    final isActive = r.status == null || r.status == 'active';
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        title: Row(
          children: [
            Expanded(
              child: Text(
                r.name,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: isActive
                    ? EchoDeskColors.successSoft
                    : EchoDeskColors.surfaceMuted,
                borderRadius: BorderRadius.circular(EchoDeskRadii.sm),
              ),
              child: Text(
                r.status ?? 'active',
                style: TextStyle(
                  fontSize: MediaQuery.textScalerOf(context)
                      .clamp(minScaleFactor: 1.0, maxScaleFactor: 1.4)
                      .scale(11)
                      .clamp(11.0, 16.0),
                  fontWeight: FontWeight.w600,
                  color:
                      isActive ? EchoDeskColors.success : EchoDeskColors.muted,
                ),
              ),
            ),
          ],
        ),
        subtitle: Text(
          r.displayPhone,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: EchoDeskColors.muted,
              ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.phone_outlined, size: 20),
              tooltip: 'Place outbound call',
              visualDensity: VisualDensity.compact,
              onPressed: () => _showOutboundCallSheet(context, r),
            ),
            const Icon(
              Icons.chevron_right,
              size: 18,
              color: EchoDeskColors.soft,
            ),
          ],
        ),
        onTap: () => context.push('/receptionists/${r.id}'),
        onLongPress: () => _showOutboundCallSheet(context, r),
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
}
