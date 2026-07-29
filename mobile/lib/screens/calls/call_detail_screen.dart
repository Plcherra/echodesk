import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/call_history_service.dart';
import '../../utils/call_formatters.dart';
import '../../widgets/constrained_scaffold_body.dart';
import '../../widgets/outcome_chip.dart';
import '../../widgets/state_views.dart';
import '../../theme/echodesk_theme.dart';

/// Recording status from backend: available | processing | not_recorded | failed
/// null/absent = not_recorded
String _recordingStatusLabel(String? status) {
  switch (status) {
    case 'available':
      return 'Available';
    case 'expired':
      return 'Expired';
    case 'processing':
      return 'Processing';
    case 'not_recorded':
      return 'Not recorded';
    case 'failed':
      return 'Failed';
    default:
      return 'Not recorded';
  }
}

class CallDetailScreen extends StatefulWidget {
  final String receptionistId;
  final String callId;
  final Map<String, dynamic>? callData;

  const CallDetailScreen({
    super.key,
    required this.receptionistId,
    required this.callId,
    this.callData,
  });

  @override
  State<CallDetailScreen> createState() => _CallDetailScreenState();
}

class _CallDetailScreenState extends State<CallDetailScreen> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;
  bool _recordingExpired = false;
  bool _recordingActionBusy = false;

  Map<String, dynamic>? _call;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _call = widget.callData;
    if (_call == null) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final call = await loadCallDetail(
        receptionistId: widget.receptionistId,
        callId: widget.callId,
      );
      if (!mounted) return;
      setState(() {
        _call = call;
        _loading = false;
      });
    } on CallHistoryApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
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
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => context.pop(),
          ),
          title: const Text('Call details'),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final call = _call;
    if (call == null) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => context.pop(),
          ),
          title: const Text('Call details'),
        ),
        body: Center(
          child: ErrorStateView(
            title: 'Call not found',
            message: _error ??
                'This call could not be loaded. Go back and try again.',
            onRetry: _load,
          ),
        ),
      );
    }

    final start = call['started_at'] != null
        ? DateTime.tryParse(call['started_at'] as String)
        : null;
    final dur = call['duration_seconds'] as int?;
    final transcript = (call['transcript'] as String?)?.trim();
    final fromNumber = call['from_number'] as String? ?? '';
    final toNumber = call['to_number'] as String? ?? '';
    final outcome = callOutcomeLabel(call);

    final recordingStatus = call['recording_status'] as String?;
    final recordedAt = call['recorded_at'] != null
        ? DateTime.tryParse(call['recorded_at'] as String)
        : null;
    final recordingDuration = call['recording_duration_seconds'] as int?;

    final effectiveRecordingStatus = _recordingExpired ? 'expired' : recordingStatus;
    final hasRecording =
        !_recordingExpired && recordingStatus == 'available';
    final hasTranscript = transcript != null && transcript.isNotEmpty;
    final appointmentId = call['appointment_id'] as String?;
    final isPhoneDevice = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android);

    final metaParts = <String>[
      formatCallTimestamp(start),
      formatCallDuration(dur),
    ].where((s) => s.isNotEmpty && s != '—').toList();

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: const Text('Call details'),
        actions: [
          if (fromNumber.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: fromNumber));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Number copied')),
                );
              },
              tooltip: 'Copy number',
            ),
        ],
      ),
      body: constrainedScaffoldBody(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          children: [
            // Header: outcome chip + date/duration
            Align(
              alignment: Alignment.centerLeft,
              child: OutcomeChip(label: outcome, prominent: true),
            ),
            if (metaParts.isNotEmpty) ...[
              const SizedBox(height: EchoDeskSpacing.sm),
              Text(
                metaParts.join(' · '),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: EchoDeskColors.muted,
                    ),
              ),
            ],

            if (fromNumber.isNotEmpty || toNumber.isNotEmpty) ...[
              const SizedBox(height: EchoDeskSpacing.md),
              _CallerInfoBlock(
                fromNumber: fromNumber,
                toNumber: toNumber,
                onCopy: (number) => _copyAndNotify(context, number),
              ),
            ],

            const SizedBox(height: EchoDeskSpacing.lg),
            _buildQuickActions(
              context: context,
              fromNumber: fromNumber,
              isPhoneDevice: isPhoneDevice,
              appointmentId: appointmentId,
            ),
            const SizedBox(height: EchoDeskSpacing.lg),
            _buildRecordingAndTranscriptSection(
              context: context,
              recordingStatus: effectiveRecordingStatus,
              recordedAt: recordedAt,
              startedAt: start,
              recordingDuration: recordingDuration,
              hasRecording: hasRecording,
              transcript: transcript,
              hasTranscript: hasTranscript,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickActions({
    required BuildContext context,
    required String fromNumber,
    required bool isPhoneDevice,
    required String? appointmentId,
  }) {
    final actions = <Widget>[
      if (fromNumber.isNotEmpty)
        _ActionTile(
          icon: Icons.copy_outlined,
          label: 'Copy number',
          onTap: () => _copyAndNotify(context, fromNumber),
        ),
      if (fromNumber.isNotEmpty && isPhoneDevice)
        _ActionTile(
          icon: Icons.phone_outlined,
          label: 'Call back',
          onTap: () async {
            final uri = Uri.parse('tel:$fromNumber');
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
        ),
      if (appointmentId != null && appointmentId.isNotEmpty)
        _ActionTile(
          icon: Icons.event_outlined,
          label: 'View appointment',
          onTap: () => context.push('/appointments/$appointmentId'),
        ),
    ];
    if (actions.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Quick actions',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: EchoDeskSpacing.sm),
        LayoutBuilder(
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
        ),
      ],
    );
  }

  Widget _buildRecordingAndTranscriptSection({
    required BuildContext context,
    required String? recordingStatus,
    required DateTime? recordedAt,
    required DateTime? startedAt,
    required int? recordingDuration,
    required bool hasRecording,
    required String? transcript,
    required bool hasTranscript,
  }) {
    final recordingCard = _buildRecordingCard(
      context: context,
      recordingStatus: recordingStatus,
      recordedAt: recordedAt,
      startedAt: startedAt,
      recordingDuration: recordingDuration,
      hasRecording: hasRecording,
    );

    if (hasTranscript && hasRecording) {
      final useRow = MediaQuery.sizeOf(context).width > 600;
      if (useRow) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _buildTranscriptCard(context, transcript!)),
            const SizedBox(width: EchoDeskSpacing.md),
            Expanded(child: recordingCard),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTranscriptCard(context, transcript!),
          const SizedBox(height: EchoDeskSpacing.md),
          recordingCard,
        ],
      );
    }
    if (hasTranscript) {
      return _buildTranscriptCard(context, transcript!);
    }
    return recordingCard;
  }

  Widget _buildTranscriptCard(BuildContext context, String transcript) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Transcript',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: EchoDeskSpacing.sm),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: EchoDeskColors.surface,
            borderRadius: BorderRadius.circular(EchoDeskRadii.md),
            border: Border.all(color: EchoDeskColors.line),
          ),
          child: SelectableText(
            transcript,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: EchoDeskColors.ink,
                ),
          ),
        ),
      ],
    );
  }

  Widget _buildRecordingCard({
    required BuildContext context,
    required String? recordingStatus,
    required DateTime? recordedAt,
    required DateTime? startedAt,
    required int? recordingDuration,
    required bool hasRecording,
  }) {
    final statusLabel = _recordingStatusLabel(recordingStatus);
    String statusExplanation = '';
    switch (recordingStatus) {
      case 'available':
        statusExplanation =
            'Play, download, or copy — each action requests a new short-lived link from your provider.';
        break;
      case 'expired':
        statusExplanation =
            'This recording link is no longer valid. Try Play again to fetch a fresh link.';
        break;
      case 'processing':
        final ageMinutes = startedAt == null
            ? null
            : DateTime.now().toUtc().difference(startedAt.toUtc()).inMinutes;
        if (ageMinutes != null && ageMinutes >= 15) {
          statusExplanation =
              'Recording is still processing after $ageMinutes minutes. Provider recording webhook may be delayed or missing.';
        } else {
          statusExplanation =
              'Recording is being processed. Check back in a few minutes.';
        }
        break;
      case 'not_recorded':
        statusExplanation =
            'This call was not recorded. Recording may be disabled or consent was not given.';
        break;
      case 'failed':
        statusExplanation =
            'Recording failed. The call may have been too short or an error occurred.';
        break;
      default:
        statusExplanation =
            'No recording is available for this call. Recording may be disabled.';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Recording',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: EchoDeskSpacing.sm),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: EchoDeskColors.surface,
            borderRadius: BorderRadius.circular(EchoDeskRadii.md),
            border: Border.all(color: EchoDeskColors.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _RecordingStatusChip(
                    label: statusLabel,
                    isAvailable: hasRecording,
                  ),
                  if (recordingDuration != null && recordingDuration > 0) ...[
                    const SizedBox(width: EchoDeskSpacing.sm),
                    Text(
                      formatCallDuration(recordingDuration),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: EchoDeskColors.muted,
                          ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: EchoDeskSpacing.sm),
              Text(
                statusExplanation,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: EchoDeskColors.muted,
                    ),
              ),
              if (hasRecording) ...[
                const SizedBox(height: EchoDeskSpacing.md),
                Wrap(
                  spacing: EchoDeskSpacing.sm,
                  runSpacing: EchoDeskSpacing.sm,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _recordingActionBusy
                          ? null
                          : (_isPlaying ? _stopPlaying : _playRecording),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: EchoDeskColors.brand,
                        side: const BorderSide(color: EchoDeskColors.line),
                      ),
                      icon: Icon(
                        _isPlaying ? Icons.stop : Icons.play_arrow,
                        size: 18,
                      ),
                      label: Text(_isPlaying ? 'Stop' : 'Play'),
                    ),
                    OutlinedButton.icon(
                      onPressed:
                          _recordingActionBusy ? null : _downloadRecording,
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: EchoDeskColors.ink,
                        side: const BorderSide(color: EchoDeskColors.line),
                      ),
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('Download'),
                    ),
                    OutlinedButton.icon(
                      onPressed:
                          _recordingActionBusy ? null : _copyRecordingLink,
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: EchoDeskColors.ink,
                        side: const BorderSide(color: EchoDeskColors.line),
                      ),
                      icon: const Icon(Icons.link, size: 18),
                      label: const Text('Copy link'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<String?> _fetchFreshRecordingUrl() async {
    setState(() => _recordingActionBusy = true);
    try {
      final url = await fetchCallRecordingUrl(
        receptionistId: widget.receptionistId,
        callId: widget.callId,
      );
      if (mounted) {
        setState(() => _recordingExpired = false);
      }
      return url;
    } on CallHistoryApiException catch (e) {
      if (mounted) {
        final msg = e.message.toLowerCase();
        if (e.statusCode == 409 ||
            e.statusCode == 502 ||
            msg.contains('expired') ||
            msg.contains('403')) {
          setState(() => _recordingExpired = true);
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
      return null;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not get recording link: $e')),
        );
      }
      return null;
    } finally {
      if (mounted) {
        setState(() => _recordingActionBusy = false);
      }
    }
  }

  Future<void> _playRecording() async {
    final url = await _fetchFreshRecordingUrl();
    if (url == null || !mounted) {
      return;
    }
    try {
      setState(() => _isPlaying = true);
      await _audioPlayer.play(UrlSource(url));
      await _audioPlayer.onPlayerComplete.first;
    } catch (e) {
      if (mounted) {
        final msg = e.toString().toLowerCase();
        if (msg.contains('403') || msg.contains('404') || msg.contains('expired')) {
          setState(() => _recordingExpired = true);
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not play: $e'),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () => _playRecording(),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isPlaying = false);
      }
    }
  }

  Future<void> _downloadRecording() async {
    final url = await _fetchFreshRecordingUrl();
    if (url == null || !mounted) {
      return;
    }
    await _openUrl(url);
  }

  Future<void> _copyRecordingLink() async {
    final url = await _fetchFreshRecordingUrl();
    if (url == null || !mounted) {
      return;
    }
    _copyAndNotify(context, url);
  }

  Future<void> _stopPlaying() async {
    await _audioPlayer.stop();
    setState(() => _isPlaying = false);
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      setState(() => _recordingExpired = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open link')),
      );
    }
  }

  void _copyAndNotify(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Copied')),
      );
    }
  }
}

class _RecordingStatusChip extends StatelessWidget {
  final String label;
  final bool isAvailable;

  const _RecordingStatusChip({required this.label, required this.isAvailable});

  @override
  Widget build(BuildContext context) {
    final (color, bgColor) = isAvailable
        ? (EchoDeskColors.success, EchoDeskColors.successSoft)
        : _colorsForStatus(label);
    final fontSize = MediaQuery.textScalerOf(context)
        .clamp(minScaleFactor: 1.0, maxScaleFactor: 1.4)
        .scale(12)
        .clamp(11.0, 16.0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(EchoDeskRadii.sm),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  (Color, Color) _colorsForStatus(String label) {
    switch (label) {
      case 'Processing':
        return (EchoDeskColors.warning, EchoDeskColors.warningSoft);
      case 'Failed':
        return (EchoDeskColors.danger, EchoDeskColors.dangerSoft);
      default:
        return (EchoDeskColors.muted, EchoDeskColors.surfaceMuted);
    }
  }
}

class _CallerInfoBlock extends StatelessWidget {
  final String fromNumber;
  final String toNumber;
  final void Function(String number) onCopy;

  const _CallerInfoBlock({
    required this.fromNumber,
    required this.toNumber,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: EchoDeskColors.surface,
        borderRadius: BorderRadius.circular(EchoDeskRadii.md),
        border: Border.all(color: EchoDeskColors.line),
      ),
      child: Column(
        children: [
          if (fromNumber.isNotEmpty)
            _CallerRow(
              label: 'From',
              value: formatPhoneForDisplay(fromNumber),
              onTap: () => onCopy(fromNumber),
            ),
          if (fromNumber.isNotEmpty && toNumber.isNotEmpty)
            const Divider(height: 16, color: EchoDeskColors.line),
          if (toNumber.isNotEmpty)
            _CallerRow(
              label: 'To',
              value: formatPhoneForDisplay(toNumber),
              onTap: () => onCopy(toNumber),
            ),
        ],
      ),
    );
  }
}

class _CallerRow extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTap;

  const _CallerRow({
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(EchoDeskRadii.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              child: Text(
                label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: EchoDeskColors.muted,
                    ),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: EchoDeskColors.ink,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
            Icon(Icons.copy_outlined, size: 16, color: EchoDeskColors.soft),
          ],
        ),
      ),
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
