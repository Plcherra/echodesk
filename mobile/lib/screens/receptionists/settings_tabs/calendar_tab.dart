import 'package:flutter/material.dart';

import '../../../services/api_client.dart';
import '../../../theme/echodesk_theme.dart';

class ReceptionistCalendarTab extends StatefulWidget {
  final String receptionistId;
  final Map<String, dynamic>? status;
  final bool loading;
  final Future<void> Function() onRefresh;
  /// Called after a successful mode change so parent can rebuild tabs.
  final Future<void> Function(String mode)? onModeChanged;

  const ReceptionistCalendarTab({
    super.key,
    required this.receptionistId,
    required this.status,
    required this.loading,
    required this.onRefresh,
    this.onModeChanged,
  });

  @override
  State<ReceptionistCalendarTab> createState() =>
      _ReceptionistCalendarTabState();
}

class _ReceptionistCalendarTabState extends State<ReceptionistCalendarTab> {
  bool _savingMode = false;

  static String _str(dynamic v) {
    if (v == null) return '';
    if (v is String) return v;
    return v.toString();
  }

  Future<void> _setMode(String newMode) async {
    final s = widget.status ?? {};
    final current =
        _str(s['mode']).isEmpty ? 'personal' : _str(s['mode']);
    if (newMode == current || _savingMode) return;

    final goingSolo = newMode == 'personal';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(goingSolo
            ? 'Switch to Personal / Solo?'
            : 'Switch to Business / Team?'),
        content: Text(
          goingSolo
              ? 'Staff and locations stay saved but won’t be used until you switch back. '
                  'Your phone number and Google calendar stay the same.'
              : 'Unlocks staff and store locations. '
                  'Your phone number and Google calendar stay the same.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Switch'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _savingMode = true);
    try {
      final res = await ApiClient.patch(
        '/api/mobile/receptionists/${widget.receptionistId}',
        body: {'mode': newMode},
      );
      if (!mounted) return;
      if (res.statusCode >= 200 && res.statusCode < 300) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              newMode == 'business'
                  ? 'Switched to Business / Team'
                  : 'Switched to Personal / Solo',
            ),
          ),
        );
        await widget.onModeChanged?.call(newMode);
        await widget.onRefresh();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't update mode. Please try again.")),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't update mode. Please try again.")),
        );
      }
    } finally {
      if (mounted) setState(() => _savingMode = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.status ?? {};
    final mode = _str(s['mode']).isEmpty ? 'personal' : _str(s['mode']);
    final assistantName = _str(s['assistant_name']);
    final connectedEmail = _str(s['connected_google_email']).isEmpty
        ? null
        : _str(s['connected_google_email']);
    final bookingLabel = _str(s['booking_calendar_label']);
    final bookingId = _str(s['booking_calendar_id']);
    final bookingCalendar = bookingLabel.isNotEmpty
        ? bookingLabel
        : (bookingId.isNotEmpty ? bookingId : 'primary');
    final connected = s['calendar_connected'] == true;

    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: ListView(
        padding: const EdgeInsets.all(EchoDeskSpacing.lg),
        children: [
          Text(
            'Calendar',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: EchoDeskSpacing.xs),
          Text(
            'Used for availability checks and bookings for this assistant.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: EchoDeskColors.muted,
                ),
          ),
          const SizedBox(height: EchoDeskSpacing.md),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                _StatusRow(
                  label: 'Assistant',
                  value: assistantName.isNotEmpty
                      ? assistantName
                      : widget.receptionistId,
                ),
                const Divider(height: 1),
                _StatusRow(
                  label: 'Google account',
                  value: connectedEmail ?? 'Not connected',
                  trailing: Icon(
                    connected ? Icons.check_circle : Icons.error_outline,
                    size: 20,
                    color: connected
                        ? EchoDeskColors.success
                        : EchoDeskColors.warning,
                  ),
                ),
                const Divider(height: 1),
                _StatusRow(
                  label: 'Booking calendar',
                  value: bookingCalendar,
                ),
              ],
            ),
          ),
          const SizedBox(height: EchoDeskSpacing.lg),
          Text(
            'Receptionist mode',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: EchoDeskSpacing.xs),
          Text(
            'Same phone number either way. Business unlocks staff and store locations.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: EchoDeskColors.muted,
                ),
          ),
          const SizedBox(height: EchoDeskSpacing.sm),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'personal',
                label: Text('Solo'),
                icon: Icon(Icons.person_outline, size: 18),
              ),
              ButtonSegment(
                value: 'business',
                label: Text('Business'),
                icon: Icon(Icons.storefront_outlined, size: 18),
              ),
            ],
            selected: {mode == 'business' ? 'business' : 'personal'},
            onSelectionChanged: _savingMode
                ? null
                : (set) {
                    final next = set.first;
                    _setMode(next);
                  },
          ),
          if (_savingMode) ...[
            const SizedBox(height: EchoDeskSpacing.md),
            const LinearProgressIndicator(),
          ],
          if (widget.loading) ...[
            const SizedBox(height: EchoDeskSpacing.md),
            const LinearProgressIndicator(),
          ],
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final String label;
  final String value;
  final Widget? trailing;

  const _StatusRow({
    required this.label,
    required this.value,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      title: Text(label),
      subtitle: Text(value),
      trailing: trailing,
    );
  }
}
