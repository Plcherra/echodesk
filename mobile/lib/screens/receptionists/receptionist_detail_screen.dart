import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/receptionist.dart';
import '../../strings.dart';
import '../../services/api_client.dart';
import '../../services/appointment_service.dart';
import '../../services/call_history_service.dart';
import '../../theme/echodesk_theme.dart';
import '../../utils/appointment_formatters.dart';
import '../../utils/call_formatters.dart';
import '../../widgets/constrained_scaffold_body.dart';
import '../../widgets/outcome_chip.dart';
import '../../widgets/state_views.dart';
import '../../widgets/status_chip.dart';

class ReceptionistDetailScreen extends StatefulWidget {
  final String receptionistId;

  const ReceptionistDetailScreen({super.key, required this.receptionistId});

  @override
  State<ReceptionistDetailScreen> createState() =>
      _ReceptionistDetailScreenState();
}

class _ReceptionistDetailScreenState extends State<ReceptionistDetailScreen> {
  bool get _isPhoneDevice =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  Receptionist? _receptionist;
  List<Map<String, dynamic>> _callHistory = [];
  List<Map<String, dynamic>> _upcomingAppointments = [];
  bool _loading = true;
  String? _error;
  String? _callHistoryError;
  String? _callHistoryDegradedReason;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
      _callHistoryError = null;
      _callHistoryDegradedReason = null;
    });
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) throw Exception('Not authenticated');

      final supabase = Supabase.instance.client;

      final recRes = await supabase
          .from('receptionists')
          .select(
              'id, name, phone_number, inbound_phone_number, calendar_id, status, '
              'system_prompt, greeting, voice_id, voice_preset_key, assistant_identity, extra_instructions')
          .eq('id', widget.receptionistId)
          .eq('user_id', user.id)
          .maybeSingle();

      if (recRes == null) {
        if (!mounted) return;
        setState(() {
          _error = 'Not found';
          _loading = false;
        });
        return;
      }

      List<Map<String, dynamic>> history = [];
      try {
        final result =
            await loadCallHistoryResult(widget.receptionistId, limit: 20);
        history = result.calls;
        _callHistoryDegradedReason =
            result.degraded ? result.degradedReason : null;
      } on CallHistoryApiException catch (e) {
        _callHistoryError = e.message;
        // Fallback: try call_usage if call_logs API fails
        try {
          final fallback = await supabase
              .from('call_usage')
              .select('id, started_at, ended_at, duration_seconds, transcript')
              .eq('receptionist_id', widget.receptionistId)
              .order('started_at', ascending: false)
              .limit(20);
          final raw = fallback as List;
          history = List<Map<String, dynamic>>.from((raw as List?) ?? []);
        } catch (_) {}
      } catch (_) {
        _callHistoryError = 'Failed to load call history';
      }

      List<Map<String, dynamic>> upcoming = [];
      try {
        final aptData = await loadAppointments(
          receptionistId: widget.receptionistId,
          limit: 20,
        );
        final all =
            List<Map<String, dynamic>>.from(aptData['appointments'] ?? []);
        final now = DateTime.now().toUtc();
        for (final a in all) {
          final start = a['start_time'] != null
              ? DateTime.tryParse(a['start_time'] as String)
              : null;
          if (start != null &&
              start.isAfter(now) &&
              (a['status'] as String? ?? '') != 'cancelled') {
            upcoming.add(a);
          }
        }
        upcoming.sort((a, b) {
          final sa = DateTime.tryParse(a['start_time'] as String? ?? '');
          final sb = DateTime.tryParse(b['start_time'] as String? ?? '');
          if (sa == null || sb == null) return 0;
          return sa.compareTo(sb);
        });
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _receptionist = Receptionist.fromJson(recRes);
        _callHistory = history;
        _upcomingAppointments = upcoming.take(5).toList();
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

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => context.go('/receptionists'),
          ),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_receptionist == null) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => context.go('/receptionists'),
          ),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _error != null ? 'Could not load' : 'Receptionist not found',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _load,
                    child: const Text('Retry'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    final r = _receptionist!;
    final todayCount = _todayCallCount(_callHistory);
    final voiceLabel =
        (r.voicePresetKey != null && r.voicePresetKey!.isNotEmpty)
            ? _formatPresetKey(r.voicePresetKey!)
            : ((r.voiceId != null && r.voiceId!.isNotEmpty)
                ? 'Custom'
                : 'Default');
    final calendarLabel = (r.calendarId != null && r.calendarId!.isNotEmpty)
        ? _shortCalendarDisplay(r.calendarId!)
        : 'Not connected';
    final isActive = r.status == null || r.status == 'active';

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/receptionists'),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => context.push('/receptionists/${r.id}/settings'),
          ),
        ],
      ),
      body: constrainedScaffoldBody(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            children: [
              // Header: name + status badge
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      r.name,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  const SizedBox(width: EchoDeskSpacing.sm),
                  _StatusBadge(
                    label: r.status ?? 'active',
                    active: isActive,
                  ),
                ],
              ),
              const SizedBox(height: EchoDeskSpacing.sm),
              SelectableText(
                r.displayPhone,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: EchoDeskColors.brandTeal,
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: EchoDeskSpacing.xs),
              Text(
                'Shared business number — this assistant answers on your line.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: EchoDeskColors.muted,
                    ),
              ),

              const SizedBox(height: EchoDeskSpacing.md),

              // Compact info chips
              Wrap(
                spacing: EchoDeskSpacing.sm,
                runSpacing: EchoDeskSpacing.sm,
                children: [
                  _InfoChip(
                    icon: Icons.calendar_today_outlined,
                    label: 'Calendar',
                    value: calendarLabel,
                  ),
                  _InfoChip(
                    icon: Icons.record_voice_over_outlined,
                    label: 'Voice',
                    value: voiceLabel,
                  ),
                  if (todayCount != null)
                    _InfoChip(
                      icon: Icons.phone_in_talk_outlined,
                      label: 'Calls today',
                      value: '$todayCount',
                    ),
                ],
              ),

              const SizedBox(height: EchoDeskSpacing.lg),

              // Primary actions — compact 2×2 grid
              _ActionGrid(
                onCallBack: _isPhoneDevice
                    ? () => launchUrl(
                          Uri.parse('tel:${r.displayPhone}'),
                          mode: LaunchMode.externalApplication,
                        )
                    : null,
                onAppointments: () => context.push(
                  '/appointments?receptionist_id=${r.id}&tab=today',
                ),
                onCopyNumber: () {
                  Clipboard.setData(ClipboardData(text: r.displayPhone));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Number copied')),
                  );
                },
                onViewCalls: () => context.push(
                  '/receptionists/${r.id}/calls?name=${Uri.encodeComponent(r.name)}',
                ),
              ),

              const SizedBox(height: EchoDeskSpacing.lg),

              _RecentCallsSection(
                calls: _callHistory.take(3).toList(),
                receptionistId: r.id,
                errorText: _callHistoryError,
                degradedText: _callHistoryDegradedReason,
                onViewAll: () => context.push(
                  '/receptionists/${r.id}/calls?name=${Uri.encodeComponent(r.name)}',
                ),
              ),

              const SizedBox(height: EchoDeskSpacing.lg),

              _UpcomingAppointmentsSection(
                appointments: _upcomingAppointments,
                onViewAll: () =>
                    context.push('/appointments?receptionist_id=${r.id}'),
              ),

              const SizedBox(height: EchoDeskSpacing.lg),

              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => _showDeleteConfirm(context, r),
                  style: TextButton.styleFrom(
                    foregroundColor: EchoDeskColors.danger,
                  ),
                  child: const Text('Delete receptionist'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  int? _todayCallCount(List<Map<String, dynamic>> calls) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    var count = 0;
    for (final c in calls) {
      final s = c['started_at'];
      if (s == null) continue;
      final dt = DateTime.tryParse(s as String);
      if (dt != null) {
        final d = DateTime(dt.year, dt.month, dt.day);
        if (d == today) count++;
      }
    }
    return count > 0 ? count : null;
  }

  String _formatPresetKey(String key) {
    return key
        .split('_')
        .map((s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}')
        .join(' ');
  }

  String _shortCalendarDisplay(String id) {
    if (id.contains('@')) return 'Connected';
    if (id == 'primary') return 'Primary';
    return 'Connected';
  }

  void _showDeleteConfirm(BuildContext context, Receptionist r) {
    final phone = r.displayPhone.trim();
    final phoneBit = phone.isNotEmpty && phone != '—'
        ? ' Your number $phone stays with your account so you can attach it to a new assistant.'
        : ' Your business number stays with your account so you can attach it to a new assistant.';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete receptionist?'),
        content: Text(
          'This will remove "${r.name}". Calls will stop.$phoneBit '
          'If you don’t reuse it, we’ll release it within 24–48 hours.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              try {
                final res = await ApiClient.post(
                  '/api/mobile/receptionists/${r.id}/delete',
                );
                String snack = AppStrings.receptionistDeletionRequested;
                if (res.statusCode >= 200 && res.statusCode < 300) {
                  try {
                    final data =
                        jsonDecode(res.body) as Map<String, dynamic>?;
                    final msg = (data?['message'] as String?)?.trim();
                    if (msg != null && msg.isNotEmpty) snack = msg;
                  } catch (_) {}
                }
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(snack),
                    duration: const Duration(seconds: 6),
                  ),
                );
                context.go('/receptionists');
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text(AppStrings.couldNotDeleteReceptionist)),
                  );
                }
              }
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String label;
  final bool active;

  const _StatusBadge({required this.label, required this.active});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: active ? EchoDeskColors.successSoft : EchoDeskColors.surfaceMuted,
        borderRadius: BorderRadius.circular(EchoDeskRadii.sm),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: active ? EchoDeskColors.success : EchoDeskColors.muted,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: EchoDeskColors.surfaceSoft,
        borderRadius: BorderRadius.circular(EchoDeskRadii.sm),
        border: Border.all(color: EchoDeskColors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: EchoDeskColors.muted),
          const SizedBox(width: 6),
          Text(
            '$label · ',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: EchoDeskColors.muted,
                ),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: EchoDeskColors.ink,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

class _ActionGrid extends StatelessWidget {
  final VoidCallback? onCallBack;
  final VoidCallback onAppointments;
  final VoidCallback onCopyNumber;
  final VoidCallback onViewCalls;

  const _ActionGrid({
    this.onCallBack,
    required this.onAppointments,
    required this.onCopyNumber,
    required this.onViewCalls,
  });

  @override
  Widget build(BuildContext context) {
    final actions = <Widget>[
      if (onCallBack != null)
        _ActionTile(
          icon: Icons.phone_outlined,
          label: 'Call back',
          onTap: onCallBack!,
        ),
      _ActionTile(
        icon: Icons.event_outlined,
        label: 'Appointments',
        onTap: onAppointments,
      ),
      _ActionTile(
        icon: Icons.copy_outlined,
        label: 'Copy number',
        onTap: onCopyNumber,
      ),
      _ActionTile(
        icon: Icons.history,
        label: 'View calls',
        onTap: onViewCalls,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final tileWidth = (constraints.maxWidth - EchoDeskSpacing.sm) / 2;
        return Wrap(
          spacing: EchoDeskSpacing.sm,
          runSpacing: EchoDeskSpacing.sm,
          children: actions
              .map((w) => SizedBox(width: tileWidth, child: w))
              .toList(),
        );
      },
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: EchoDeskColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(EchoDeskRadii.md),
        side: const BorderSide(color: EchoDeskColors.line),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(EchoDeskRadii.md),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(
            children: [
              Icon(icon, size: 20, color: EchoDeskColors.brand),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: EchoDeskColors.ink,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UpcomingAppointmentsSection extends StatelessWidget {
  final List<Map<String, dynamic>> appointments;
  final VoidCallback onViewAll;

  const _UpcomingAppointmentsSection({
    required this.appointments,
    required this.onViewAll,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Upcoming appointments',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            if (appointments.isNotEmpty)
              TextButton(
                onPressed: onViewAll,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('View all'),
              ),
          ],
        ),
        const SizedBox(height: EchoDeskSpacing.sm),
        if (appointments.isEmpty)
          const EmptyStateView(
            icon: Icons.event_available,
            title: 'No upcoming appointments',
            subtitle:
                'Appointments booked by this receptionist will appear here.',
            asCard: true,
          )
        else
          ...appointments.map((apt) {
            final start = apt['start_time'] != null
                ? DateTime.tryParse(apt['start_time'] as String)
                : null;
            final serviceName = (apt['service_name'] as String?)?.trim();
            final displayService =
                serviceName != null && serviceName.isNotEmpty
                    ? serviceName
                    : 'Generic';
            final status = (apt['status'] as String?) ?? 'needs_review';
            return Card(
              margin: const EdgeInsets.only(bottom: 6),
              child: ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        formatAppointmentDateTime(start),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                    StatusChip(status: status),
                  ],
                ),
                subtitle: Text(
                  displayService,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: EchoDeskColors.muted,
                      ),
                ),
                trailing: Icon(Icons.chevron_right,
                    size: 18, color: EchoDeskColors.soft),
                onTap: () => context.push('/appointments/${apt['id']}'),
              ),
            );
          }),
      ],
    );
  }
}

class _RecentCallsSection extends StatelessWidget {
  final List<Map<String, dynamic>> calls;
  final String receptionistId;
  final String? errorText;
  final String? degradedText;
  final VoidCallback onViewAll;

  const _RecentCallsSection({
    required this.calls,
    required this.receptionistId,
    this.errorText,
    this.degradedText,
    required this.onViewAll,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Recent calls',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            if (errorText == null && calls.isNotEmpty)
              TextButton(
                onPressed: onViewAll,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('View all'),
              ),
          ],
        ),
        const SizedBox(height: EchoDeskSpacing.sm),
        if (errorText != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                'Call history unavailable: $errorText',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: EchoDeskColors.danger,
                    ),
              ),
            ),
          )
        else if (degradedText != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                'Limited call data: $degradedText',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: EchoDeskColors.muted,
                    ),
              ),
            ),
          )
        else if (calls.isEmpty)
          const EmptyStateView(
            icon: Icons.phone_missed_outlined,
            title: 'No calls yet',
            subtitle:
                "When customers call your AI receptionist, they'll appear here.",
            asCard: true,
          )
        else
          ...calls.map((call) {
            final start = call['started_at'] != null
                ? DateTime.tryParse(call['started_at'] as String)
                : null;
            final dur = call['duration_seconds'] as int?;
            final outcome = callOutcomeLabel(call);
            return Card(
              margin: const EdgeInsets.only(bottom: 6),
              child: ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        formatCallTimestamp(start),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                    OutcomeChip(label: outcome),
                  ],
                ),
                subtitle: Text(
                  formatCallDuration(dur),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: EchoDeskColors.muted,
                      ),
                ),
                trailing: Icon(Icons.chevron_right,
                    size: 18, color: EchoDeskColors.soft),
                onTap: () => context.push(
                  '/receptionists/$receptionistId/calls/${call['id']}',
                  extra: call,
                ),
              ),
            );
          }),
      ],
    );
  }
}
