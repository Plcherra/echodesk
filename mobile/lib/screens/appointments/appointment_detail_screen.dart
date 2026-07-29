import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../services/appointment_service.dart';
import '../../utils/appointment_formatters.dart';
import '../../widgets/constrained_scaffold_body.dart';

class AppointmentDetailScreen extends StatefulWidget {
  final String appointmentId;

  const AppointmentDetailScreen({super.key, required this.appointmentId});

  @override
  State<AppointmentDetailScreen> createState() => _AppointmentDetailScreenState();
}

class _AppointmentDetailScreenState extends State<AppointmentDetailScreen> {
  Map<String, dynamic>? _appointment;
  bool _loading = true;
  String? _error;
  bool _saving = false;

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
      final apt = await loadAppointment(widget.appointmentId);
      setState(() {
        _appointment = apt;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _updateStatus(String status) async {
    setState(() => _saving = true);
    try {
      final result =
          await updateAppointment(widget.appointmentId, status: status);
      if (!mounted) return;
      if (result.ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Status updated to ${_statusLabel(status)}')),
        );
        _load();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.error ?? 'Could not update status')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Guard Confirm behind an explicit dialog when the appointment still needs
  /// review, so a stray tap doesn't lock in a booking without a second look.
  Future<void> _confirmConfirm() async {
    final start = _appointment?['start_time'] != null
        ? DateTime.tryParse(_appointment!['start_time'] as String)
        : null;
    final whenText =
        start != null ? ' on ${formatAppointmentDateTime(start)}' : '';
    final serviceName =
        (_appointment?['service_name'] as String?)?.trim();
    final serviceText = (serviceName != null && serviceName.isNotEmpty)
        ? ' ($serviceName)'
        : '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm this appointment?'),
        content: Text(
          'This marks the appointment$serviceText$whenText as confirmed. '
          'You can still cancel it later if needed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (ok == true) _updateStatus('confirmed');
  }

  /// Guard destructive cancellation behind an explicit confirmation so a stray
  /// tap can't cancel a real booking.
  Future<void> _confirmCancel() async {
    final start = _appointment?['start_time'] != null
        ? DateTime.tryParse(_appointment!['start_time'] as String)
        : null;
    final whenText = start != null ? ' on ${formatAppointmentDateTime(start)}' : '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this appointment?'),
        content: Text(
          'This cancels the appointment$whenText. The caller won\'t be automatically '
          'notified, and this can\'t be undone from here.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Cancel appointment'),
          ),
        ],
      ),
    );
    if (ok == true) _updateStatus('cancelled');
  }

  Future<void> _applyUpdate({
    required Future<({bool ok, String? error})> Function() update,
    required String successMessage,
  }) async {
    setState(() => _saving = true);
    try {
      final result = await update();
      if (!mounted) return;
      if (result.ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(successMessage)),
        );
        _load();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.error ?? 'Update failed')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _showEditService() async {
    final current = (_appointment?['service_name'] as String?)?.trim() ?? '';
    final c = await showDialog<String>(
      context: context,
      builder: (ctx) => _EditTextDialog(
        title: 'Edit service',
        label: 'Service name',
        initialValue: current,
        hint: 'e.g. Consultation, House cleaning',
      ),
    );
    if (c != null && c != current) {
      await _applyUpdate(
        update: () =>
            updateAppointment(widget.appointmentId, serviceName: c),
        successMessage: 'Service updated',
      );
    }
  }

  Future<void> _showEditNotes() async {
    final current = (_appointment?['notes'] as String?)?.trim() ?? '';
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => _EditTextDialog(
        title: 'Edit notes',
        label: 'Notes / instructions',
        initialValue: current,
      ),
    );
    if (result != null && result != current) {
      await _applyUpdate(
        update: () =>
            updateAppointment(widget.appointmentId, notes: result),
        successMessage: 'Notes updated',
      );
    }
  }

  Future<void> _showAttachPaymentLink() async {
    final current = (_appointment?['payment_link'] as String?)?.trim() ?? '';
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => _EditTextDialog(
        title: 'Attach payment link',
        label: 'Payment URL',
        initialValue: current,
        hint: 'https://...',
      ),
    );
    if (result != null) {
      await _applyUpdate(
        update: () => updateAppointment(
          widget.appointmentId,
          paymentLink: result.isEmpty ? null : result,
        ),
        successMessage: 'Payment link updated',
      );
    }
  }

  Future<void> _showEditAddress() async {
    final current = (_appointment?['customer_address'] as String?)?.trim() ?? '';
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => _EditTextDialog(
        title: 'Edit address',
        label: 'Service address',
        initialValue: current,
        hint: '123 Main St, City',
      ),
    );
    if (result != null) {
      await _applyUpdate(
        update: () => updateAppointment(
          widget.appointmentId,
          customerAddress: result.isEmpty ? null : result,
        ),
        successMessage: 'Address updated',
      );
    }
  }

  Future<void> _showEditVideoLink() async {
    final current = (_appointment?['location_text'] as String?)?.trim() ?? '';
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => _EditTextDialog(
        title: 'Edit video meeting link',
        label: 'Meeting URL',
        initialValue: current,
        hint: 'https://zoom.us/... or https://meet.google.com/...',
      ),
    );
    if (result != null) {
      await _applyUpdate(
        update: () => updateAppointment(
          widget.appointmentId,
          locationText: result.isEmpty ? null : result,
        ),
        successMessage: 'Meeting link updated',
      );
    }
  }

  Future<void> _showEditServiceInstructions() async {
    final current = (_appointment?['meeting_instructions'] as String?)?.trim() ?? '';
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => _EditTextDialog(
        title: 'Edit service instructions',
        label: 'Prep instructions for the customer',
        initialValue: current,
        hint: 'e.g. Please arrive 10 min early, bring ID',
      ),
    );
    if (result != null) {
      await _applyUpdate(
        update: () => updateAppointment(
          widget.appointmentId,
          meetingInstructions: result.isEmpty ? null : result,
        ),
        successMessage: 'Instructions updated',
      );
    }
  }

  String _buildDefaultMessage(Map<String, dynamic> apt) {
    final parts = <String>[];
    final base = (apt['followup_message_resolved'] as String?)?.trim();
    if (base != null && base.isNotEmpty) parts.add(base);
    final payment = (apt['payment_link'] as String?)?.trim();
    if (payment != null && payment.isNotEmpty) parts.add('Payment: $payment');
    final instructions = (apt['meeting_instructions'] as String?)?.trim();
    if (instructions != null && instructions.isNotEmpty) parts.add(instructions);
    final addr = (apt['customer_address'] as String?)?.trim();
    if (addr != null && addr.isNotEmpty) parts.add('Location: $addr');
    final loc = (apt['location_text'] as String?)?.trim();
    if (loc != null && loc.isNotEmpty && addr == null) parts.add('Meeting link: $loc');
    return parts.isEmpty ? 'Your appointment is confirmed.' : parts.join('\n\n');
  }

  Future<void> _showSendConfirmation({bool isResend = false}) async {
    final apt = _appointment;
    if (apt == null) return;
    final callerNumber = (apt['caller_number'] as String?)?.trim();
    if (callerNumber == null || callerNumber.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No caller number — cannot send SMS')),
      );
      return;
    }
    final defaultMsg = _buildDefaultMessage(apt);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => _MessageComposerDialog(
        title: isResend ? 'Resend confirmation' : 'Send confirmation',
        initialMessage: defaultMsg,
      ),
    );
    if (result == null) return;
    setState(() => _saving = true);
    try {
      final res = await sendConfirmation(widget.appointmentId, message: result);
      if (mounted) {
        if (res['success'] == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(isResend ? 'Confirmation resent' : 'Confirmation sent')),
          );
          _load();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(res['error']?.toString() ?? 'Failed to send')),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool _isAddressBased(Map<String, dynamic> apt) {
    final t = (apt['location_type'] as String?)?.toLowerCase();
    return t == 'customer_address';
  }

  bool _isVideoMeeting(Map<String, dynamic> apt) {
    final t = (apt['location_type'] as String?)?.toLowerCase();
    return t == 'video_meeting';
  }

  Future<void> _showEditAddressOrVideo() async {
    final addr = (_appointment?['customer_address'] as String?)?.trim() ?? '';
    final loc = (_appointment?['location_text'] as String?)?.trim() ?? '';
    final current = addr.isNotEmpty ? addr : loc;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => _EditTextDialog(
        title: 'Add address or meeting link',
        label: 'Address or video URL',
        initialValue: current,
        hint: '123 Main St or https://zoom.us/...',
      ),
    );
    if (result != null) {
      await _applyUpdate(
        update: () => updateAppointment(
          widget.appointmentId,
          customerAddress: result.isNotEmpty ? result : null,
          locationText: result.isNotEmpty ? result : null,
        ),
        successMessage: 'Updated',
      );
    }
  }

  String _statusLabel(String s) {
    switch (s) {
      case 'confirmed': return 'Confirmed';
      case 'needs_review': return 'Needs Review';
      case 'cancelled': return 'Cancelled';
      case 'completed': return 'Completed';
      default: return s;
    }
  }

  Widget _buildFollowUpSection({
    required Map<String, dynamic> apt,
    required bool confirmSent,
    required bool hasPayment,
    required bool hasInstructions,
    String? locationType,
  }) {
    final lastSent = apt['confirmation_message_sent_at'];
    DateTime? lastSentDt;
    if (lastSent != null) {
      lastSentDt = DateTime.tryParse(lastSent as String);
    }
    String lastSentStr = '—';
    if (lastSentDt != null) {
      final local = lastSentDt.toLocal();
      lastSentStr = '${local.month}/${local.day}/${local.year} ${local.hour}:${local.minute.toString().padLeft(2, '0')}';
    }
    String confirmationValue = 'Not sent';
    if (confirmSent) {
      final status = apt['sms_delivery_status'] as String?;
      if (status == 'delivered') {
        confirmationValue = 'Delivered';
      } else if (status == 'delivery_failed' || status == 'sending_failed') {
        confirmationValue = 'Failed';
      } else {
        confirmationValue = 'Sent';
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Follow-up', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _FollowUpRow(label: 'Confirmation', value: confirmationValue),
              _FollowUpRow(label: 'Last sent', value: lastSentStr),
              _FollowUpRow(label: 'Channel', value: 'SMS'),
              _FollowUpRow(label: 'Payment link', value: hasPayment ? 'Yes' : 'No'),
              _FollowUpRow(label: 'Instructions', value: hasInstructions ? 'Yes' : 'No'),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.pop()),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_appointment == null || _error != null) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.pop()),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(_error ?? 'Appointment not found', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(onPressed: _load, child: const Text('Retry')),
              ],
            ),
          ),
        ),
      );
    }

    final apt = _appointment!;
    final start = apt['start_time'] != null ? DateTime.tryParse(apt['start_time'] as String) : null;
    final status = apt['status'] as String? ?? 'needs_review';
    final serviceName = (apt['service_name'] as String?)?.trim();
    final displayService = serviceName != null && serviceName.isNotEmpty ? serviceName : 'Generic appointment';
    final isGeneric = (apt['booking_mode'] as String?) == 'generic' || (serviceName == null || serviceName.isEmpty);
    final transcript = apt['transcript'] as String?;
    final location = (apt['customer_address'] as String?)?.trim();
    final locationText = (apt['location_text'] as String?)?.trim();
    final locDisplay = location ?? locationText;
    final paymentLink = (apt['payment_link'] as String?)?.trim();
    final hasPayment = paymentLink != null && paymentLink.isNotEmpty;
    final confirmSent = apt['confirmation_message_sent_at'] != null;
    final callerNumber = (apt['caller_number'] as String?)?.trim();

    final canConfirm = status != 'confirmed' && status != 'cancelled' && status != 'completed';
    final canCancel = status != 'cancelled' && status != 'completed';
    final canComplete = status != 'completed' &&
        status != 'cancelled' &&
        start != null &&
        start.isBefore(DateTime.now());

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.pop()),
        title: const Text('Appointment details'),
        actions: [
          if (apt['caller_number'] != null && (apt['caller_number'] as String).isNotEmpty)
            IconButton(
              icon: const Icon(Icons.copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: apt['caller_number'] as String));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Number copied')));
              },
              tooltip: 'Copy caller number',
            ),
        ],
      ),
      body: constrainedScaffoldBody(
        child: _saving
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                children: [
                  if (isGeneric)
                    Card(
                      color: Colors.amber.shade50,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Icon(Icons.warning_amber, color: Colors.amber.shade800),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Generic appointment — service/details not fully confirmed',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.amber.shade900,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (isGeneric) const SizedBox(height: 16),
                  _DetailRow(label: 'Date & time', value: formatAppointmentDateTime(start)),
                  _DetailRow(label: 'Service', value: displayService),
                  _DetailRow(label: 'Receptionist', value: apt['receptionist_name'] as String? ?? '—'),
                  _DetailRow(label: 'Caller', value: apt['caller_number'] != null ? maskPhone(apt['caller_number']) : '—'),
                  _DetailRow(label: 'Status', value: _statusLabel(status)),
                  if (locDisplay != null && locDisplay.isNotEmpty)
                    _DetailRow(label: 'Location / address', value: locDisplay),
                  if (hasPayment) _DetailRow(label: 'Payment link', value: 'Attached'),
                  const SizedBox(height: 24),
                  _buildFollowUpSection(
                    apt: apt,
                    confirmSent: confirmSent,
                    hasPayment: hasPayment,
                    hasInstructions: (apt['meeting_instructions'] as String?)?.trim().isNotEmpty ?? false,
                    locationType: apt['location_type'] as String?,
                  ),
                  if (apt['notes'] != null && (apt['notes'] as String).trim().isNotEmpty)
                    _DetailRow(label: 'Notes', value: (apt['notes'] as String).trim()),
                  if (transcript != null && transcript.trim().isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text('Transcript', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SelectableText(
                        truncatePreview(transcript, maxLength: 500),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ],
              ),
      ),
      bottomNavigationBar: _saving
          ? null
          : SafeArea(
              child: Material(
                elevation: 8,
                color: Theme.of(context).colorScheme.surface,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (status == 'confirmed')
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _StatusNote(
                            icon: Icons.check_circle,
                            color: Colors.green.shade700,
                            text: 'This appointment is confirmed.',
                          ),
                        ),
                      if (status == 'cancelled')
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _StatusNote(
                            icon: Icons.cancel,
                            color: Theme.of(context).colorScheme.error,
                            text: 'This appointment was cancelled.',
                          ),
                        ),
                      if (canConfirm || canCancel)
                        Row(
                          children: [
                            if (canCancel)
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: _confirmCancel,
                                  icon: const Icon(Icons.cancel_outlined, size: 18),
                                  label: const Text('Cancel'),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Theme.of(context).colorScheme.error,
                                    side: BorderSide(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error
                                          .withValues(alpha: 0.5),
                                    ),
                                  ),
                                ),
                              ),
                            if (canConfirm && canCancel) const SizedBox(width: 12),
                            if (canConfirm)
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: status == 'needs_review'
                                      ? _confirmConfirm
                                      : () => _updateStatus('confirmed'),
                                  icon: const Icon(Icons.check, size: 18),
                                  label: const Text('Confirm'),
                                ),
                              ),
                          ],
                        ),
                      TextButton.icon(
                        onPressed: () => _showMoreActions(
                          apt: apt,
                          displayService: displayService,
                          hasPayment: hasPayment,
                          confirmSent: confirmSent,
                          callerNumber: callerNumber,
                          location: location,
                          locationText: locationText,
                          locDisplay: locDisplay,
                          canComplete: canComplete,
                        ),
                        icon: const Icon(Icons.more_horiz, size: 18),
                        label: const Text('More actions'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Future<void> _showMoreActions({
    required Map<String, dynamic> apt,
    required String displayService,
    required bool hasPayment,
    required bool confirmSent,
    required String? callerNumber,
    required String? location,
    required String? locationText,
    required String? locDisplay,
    required bool canComplete,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'More actions',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (canComplete)
                  ListTile(
                    leading: const Icon(Icons.done_all),
                    title: const Text('Mark as completed'),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _updateStatus('completed');
                    },
                  ),
                const Divider(height: 1),
                _ActionTile(
                  icon: Icons.design_services_outlined,
                  label: 'Edit service',
                  value: displayService,
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _showEditService();
                  },
                ),
                _ActionTile(
                  icon: Icons.notes_outlined,
                  label: 'Edit notes',
                  value: ((apt['notes'] as String?)?.trim().isNotEmpty ?? false)
                      ? 'Added'
                      : 'None',
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _showEditNotes();
                  },
                ),
                _ActionTile(
                  icon: Icons.payment_outlined,
                  label: 'Payment link',
                  value: hasPayment ? 'Attached' : 'None',
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _showAttachPaymentLink();
                  },
                ),
                _ActionTile(
                  icon: Icons.list_alt_outlined,
                  label: 'Service instructions',
                  value: ((apt['meeting_instructions'] as String?)?.trim().isNotEmpty ?? false)
                      ? 'Added'
                      : 'None',
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _showEditServiceInstructions();
                  },
                ),
                if (_isAddressBased(apt))
                  _ActionTile(
                    icon: Icons.place_outlined,
                    label: 'Service address',
                    value: (location != null && location.isNotEmpty) ? location : 'None',
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _showEditAddress();
                    },
                  )
                else if (_isVideoMeeting(apt))
                  _ActionTile(
                    icon: Icons.videocam_outlined,
                    label: 'Meeting link',
                    value: (locationText != null && locationText.isNotEmpty)
                        ? locationText
                        : 'None',
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _showEditVideoLink();
                    },
                  )
                else
                  _ActionTile(
                    icon: Icons.location_on_outlined,
                    label: 'Address / meeting link',
                    value: (locDisplay != null && locDisplay.isNotEmpty) ? locDisplay : 'None',
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _showEditAddressOrVideo();
                    },
                  ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.send_outlined),
                  title: Text(confirmSent ? 'Resend confirmation' : 'Send confirmation'),
                  subtitle: callerNumber == null || callerNumber.isEmpty
                      ? const Text('No caller number')
                      : null,
                  enabled: callerNumber != null && callerNumber.isNotEmpty,
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _showSendConfirmation(isResend: confirmSent);
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FollowUpRow extends StatelessWidget {
  final String label;
  final String value;

  const _FollowUpRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          Expanded(child: Text(value, style: Theme.of(context).textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// Compact, scannable row for the "Edit details" card. Reads like a settings
/// list (label + current value + chevron) instead of a wall of buttons.
class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? value;
  final VoidCallback? onTap;

  const _ActionTile({
    required this.icon,
    required this.label,
    this.value,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasValue = value != null && value!.trim().isNotEmpty;
    return ListTile(
      leading: Icon(icon, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
      title: Text(label, style: Theme.of(context).textTheme.bodyMedium),
      subtitle: hasValue
          ? Text(
              value!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            )
          : null,
      trailing: Icon(Icons.chevron_right, size: 20, color: Colors.grey.shade400),
      onTap: onTap,
    );
  }
}

/// Inline status confirmation note shown in place of a Confirm button once the
/// decision has been made.
class _StatusNote extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _StatusNote({required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w500,
                ),
          ),
        ),
      ],
    );
  }
}

class _MessageComposerDialog extends StatefulWidget {
  final String title;
  final String initialMessage;

  const _MessageComposerDialog({required this.title, required this.initialMessage});

  @override
  State<_MessageComposerDialog> createState() => _MessageComposerDialogState();
}

class _MessageComposerDialogState extends State<_MessageComposerDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialMessage);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Edit the message before sending. Keep it concise.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            maxLines: 5,
            decoration: const InputDecoration(
              hintText: 'Your appointment is confirmed for...',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final t = _controller.text.trim();
            Navigator.of(context).pop(t.isEmpty ? widget.initialMessage : t);
          },
          child: const Text('Send'),
        ),
      ],
    );
  }
}

class _EditTextDialog extends StatefulWidget {
  final String title;
  final String label;
  final String initialValue;
  final String? hint;

  const _EditTextDialog({
    required this.title,
    required this.label,
    required this.initialValue,
    this.hint,
  });

  @override
  State<_EditTextDialog> createState() => _EditTextDialogState();
}

class _EditTextDialogState extends State<_EditTextDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: widget.label.contains('Notes') ? 4 : 1,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 4),
          Text(value, style: Theme.of(context).textTheme.bodyLarge),
        ],
      ),
    );
  }
}
