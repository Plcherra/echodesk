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
import '../../utils/appointment_formatters.dart';
import '../../utils/call_formatters.dart';
import '../../widgets/constrained_scaffold_body.dart';

class ReceptionistDetailScreen extends StatefulWidget {
  final String receptionistId;

  const ReceptionistDetailScreen({super.key, required this.receptionistId});

  @override
  State<ReceptionistDetailScreen> createState() =>
      _ReceptionistDetailScreenState();
}

class _ReceptionistDetailScreenState extends State<ReceptionistDetailScreen> {
  bool get _isPhoneDevice => !kIsWeb &&
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
        final result = await loadCallHistoryResult(widget.receptionistId, limit: 20);
        history = result.calls;
        _callHistoryDegradedReason = result.degraded ? result.degradedReason : null;
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
        final all = List<Map<String, dynamic>>.from(aptData['appointments'] ?? []);
        final now = DateTime.now().toUtc();
        for (final a in all) {
          final start = a['start_time'] != null
              ? DateTime.tryParse(a['start_time'] as String)
              : null;
          if (start != null && start.isAfter(now) &&
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

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/receptionists'),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () =>
                context.push('/receptionists/${r.id}/settings'),
          ),
        ],
      ),
      body: constrainedScaffoldBody(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    r.name,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: r.status == 'active'
                        ? Colors.green.shade100
                        : Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    r.status ?? 'active',
                    style: TextStyle(
                      color: r.status == 'active'
                          ? Colors.green.shade800
                          : Colors.grey.shade700,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(
              r.displayPhone,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
            const SizedBox(height: 24),
            _OverviewCard(
              receptionist: r,
              callHistory: _callHistory,
              onCopyNumber: () {
                Clipboard.setData(ClipboardData(text: r.displayPhone));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Number copied')),
                );
              },
              onCallBack: _isPhoneDevice
                  ? () => launchUrl(
                        Uri.parse('tel:${r.displayPhone}'),
                        mode: LaunchMode.externalApplication,
                      )
                  : null,
              onManageSettings: () =>
                  context.push('/receptionists/${r.id}/settings'),
              onViewCallHistory: () => context.push(
                '/receptionists/${r.id}/calls?name=${Uri.encodeComponent(r.name)}',
              ),
              onViewAppointments: () => context.push(
                '/appointments?receptionist_id=${r.id}&tab=today',
              ),
            ),
            const SizedBox(height: 24),
            _RecentCallsSection(
              calls: _callHistory.take(3).toList(),
              receptionistId: r.id,
              errorText: _callHistoryError,
              degradedText: _callHistoryDegradedReason,
              onViewAll: () => context.push(
                '/receptionists/${r.id}/calls?name=${Uri.encodeComponent(r.name)}',
              ),
            ),
            const SizedBox(height: 24),
            _UpcomingAppointmentsSection(
              appointments: _upcomingAppointments,
              receptionistName: r.name,
              onViewAll: () => context.push('/appointments?receptionist_id=${r.id}'),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                FilledButton(
                  onPressed: () =>
                      context.push('/receptionists/${r.id}/settings'),
                  child: const Text('Manage settings'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => _showDeleteConfirm(context, r),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  child: const Text('Delete'),
                ),
              ],
            ),
          ],
        ),
      ),
      ),
    );
  }

  void _showDeleteConfirm(BuildContext context, Receptionist r) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete receptionist?'),
        content: Text(
          'This will remove "${r.name}" as an assistant. Your business phone line stays with the business unless you release it in Telnyx. This cannot be undone.',
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
                await ApiClient.post(
                  '/api/mobile/receptionists/${r.id}/delete',
                );
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('"${r.name}" deleted')),
                );
                context.go('/receptionists');
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text(AppStrings.couldNotDeleteReceptionist)),
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

class _OverviewCard extends StatelessWidget {
  final Receptionist receptionist;
  final List<Map<String, dynamic>> callHistory;
  final VoidCallback onCopyNumber;
  final VoidCallback? onCallBack;
  final VoidCallback onManageSettings;
  final VoidCallback onViewCallHistory;
  final VoidCallback onViewAppointments;

  const _OverviewCard({
    required this.receptionist,
    required this.callHistory,
    required this.onCopyNumber,
    this.onCallBack,
    required this.onManageSettings,
    required this.onViewCallHistory,
    required this.onViewAppointments,
  });

  @override
  Widget build(BuildContext context) {
    final r = receptionist;
    final todayCount = _todayCallCount(callHistory);
    final voiceLabel = (r.voicePresetKey != null && r.voicePresetKey!.isNotEmpty)
        ? _formatPresetKey(r.voicePresetKey!)
        : ((r.voiceId != null && r.voiceId!.isNotEmpty) ? 'Custom' : 'Default');
    final calendarLabel = (r.calendarId != null && r.calendarId!.isNotEmpty)
        ? _shortCalendarDisplay(r.calendarId!)
        : 'Not connected';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Overview',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 10),
            _OverviewRow('Uses business line', r.displayPhone),
            Padding(
              padding: const EdgeInsets.only(left: 100, bottom: 8),
              child: Text(
                'Shared business number — this assistant answers calls on your business line.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
            _OverviewRow('Calendar', calendarLabel),
            _OverviewRow('Voice', voiceLabel),
            if (todayCount != null) _OverviewRow('Calls today', '$todayCount'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                FilledButton.tonalIcon(
                  onPressed: onCopyNumber,
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy'),
                ),
                if (onCallBack != null)
                  FilledButton.tonalIcon(
                    onPressed: onCallBack,
                    icon: const Icon(Icons.phone, size: 16),
                    label: const Text('Call back'),
                  ),
                FilledButton.tonalIcon(
                  onPressed: onManageSettings,
                  icon: const Icon(Icons.settings, size: 16),
                  label: const Text('Settings'),
                ),
                FilledButton.tonalIcon(
                  onPressed: onViewCallHistory,
                  icon: const Icon(Icons.history, size: 16),
                  label: const Text('Calls'),
                ),
                FilledButton.tonalIcon(
                  onPressed: onViewAppointments,
                  icon: const Icon(Icons.event, size: 16),
                  label: const Text('Appointments'),
                ),
              ],
            ),
          ],
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
    return key.split('_').map((s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}').join(' ');
  }

  String _shortCalendarDisplay(String id) {
    if (id.contains('@')) return 'Connected';
    if (id == 'primary') return 'Primary';
    return 'Connected';
  }
}

class _UpcomingAppointmentsSection extends StatelessWidget {
  final List<Map<String, dynamic>> appointments;
  final String receptionistName;
  final VoidCallback onViewAll;

  const _UpcomingAppointmentsSection({
    required this.appointments,
    required this.receptionistName,
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
              style: Theme.of(context).textTheme.titleMedium,
            ),
            TextButton(
              onPressed: onViewAll,
              child: const Text('View all'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (appointments.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Icon(Icons.event_available, size: 36, color: Colors.grey.shade400),
                  const SizedBox(height: 8),
                  Text(
                    'No upcoming appointments',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Appointments booked by this receptionist will appear here.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          )
        else
          ...appointments.map((apt) {
            final start = apt['start_time'] != null
                ? DateTime.tryParse(apt['start_time'] as String)
                : null;
            final serviceName = (apt['service_name'] as String?)?.trim();
            final displayService =
                serviceName != null && serviceName.isNotEmpty ? serviceName : 'Generic';
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                title: Text(
                  formatAppointmentDateTime(start),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                subtitle: Text(
                  displayService,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                trailing: const Icon(Icons.chevron_right, size: 20),
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
              style: Theme.of(context).textTheme.titleMedium,
            ),
            TextButton(
              onPressed: onViewAll,
              child: const Text('View all calls'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (errorText != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Call history unavailable: $errorText',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
              ),
            ),
          )
        else if (degradedText != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Limited call data: $degradedText',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          )
        else if (calls.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Icon(Icons.phone_missed_outlined,
                      size: 48, color: Colors.grey.shade400),
                  const SizedBox(height: 12),
                  Text(
                    'No calls yet',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "When customers call your AI receptionist, they'll appear here.",
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          )
        else
          ...calls.map((call) => _DetailCallRow(
                call: call,
                receptionistId: receptionistId,
                onTap: () => context.push(
                  '/receptionists/$receptionistId/calls/${call['id']}',
                  extra: call,
                ),
              )),
      ],
    );
  }
}

class _DetailCallRow extends StatelessWidget {
  final Map<String, dynamic> call;
  final String receptionistId;
  final VoidCallback onTap;

  const _DetailCallRow({
    required this.call,
    required this.receptionistId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final start = call['started_at'] != null
        ? DateTime.tryParse(call['started_at'] as String)
        : null;
    final dur = call['duration_seconds'] as int?;
    final preview = truncateTranscriptPreview(call['transcript'] as String?);
    final outcome = callOutcomeLabel(call);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        title: Row(
          children: [
            Expanded(
              child: Text(
                formatCallTimestamp(start),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            _OutcomeChip(label: outcome),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(
              formatCallDuration(dur),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (preview.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                preview,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
        trailing: const Icon(Icons.chevron_right, size: 20),
      ),
    );
  }
}

class _OutcomeChip extends StatelessWidget {
  final String label;

  const _OutcomeChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final (color, bgColor) = _colorsForOutcome(label);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  (Color, Color) _colorsForOutcome(String label) {
    switch (label) {
      case 'Booked':
        return (Colors.green.shade800, Colors.green.shade100);
      case 'Completed':
        return (Colors.blue.shade800, Colors.blue.shade100);
      case 'Short Call':
        return (Colors.orange.shade800, Colors.orange.shade100);
      case 'Missed':
        return (Colors.red.shade800, Colors.red.shade100);
      default:
        return (Colors.grey.shade700, Colors.grey.shade200);
    }
  }
}

class _OverviewRow extends StatelessWidget {
  final String label;
  final String value;

  const _OverviewRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
