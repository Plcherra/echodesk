import 'package:flutter/material.dart';

import '../../../theme/echodesk_theme.dart';

class ReceptionistCalendarTab extends StatelessWidget {
  final String receptionistId;
  final Map<String, dynamic>? status;
  final bool loading;
  final Future<void> Function() onRefresh;

  const ReceptionistCalendarTab({
    super.key,
    required this.receptionistId,
    required this.status,
    required this.loading,
    required this.onRefresh,
  });

  static String _str(dynamic v) {
    if (v == null) return '';
    if (v is String) return v;
    return v.toString();
  }

  @override
  Widget build(BuildContext context) {
    final s = status ?? {};
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
      onRefresh: onRefresh,
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
                      : receptionistId,
                ),
                const Divider(height: 1),
                _StatusRow(
                  label: 'Mode',
                  value: mode == 'business'
                      ? 'Business / Team'
                      : 'Personal / Solo',
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
          if (loading) ...[
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: EchoDeskColors.muted,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );
  }
}
