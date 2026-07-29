import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/call_history_service.dart';
import '../../utils/call_formatters.dart';
import '../../widgets/constrained_scaffold_body.dart';
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
            _DetailRow(label: 'Date & time', value: formatCallTimestamp(start)),
            _DetailRow(label: 'Duration', value: formatCallDuration(dur)),
            _DetailRow(label: 'Outcome', value: outcome),
            if (fromNumber.isNotEmpty)
              _DetailRow(
                label: 'From',
                value: formatPhoneForDisplay(fromNumber),
                onTap: () => _copyAndNotify(context, fromNumber),
              ),
            if (toNumber.isNotEmpty)
              _DetailRow(
                label: 'To',
                value: formatPhoneForDisplay(toNumber),
                onTap: () => _copyAndNotify(context, toNumber),
              ),
            const SizedBox(height: 20),
            _buildQuickActions(
              context: context,
              fromNumber: fromNumber,
              isPhoneDevice: isPhoneDevice,
              appointmentId: appointmentId,
            ),
            const SizedBox(height: 24),
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
        FilledButton.tonalIcon(
          onPressed: () => _copyAndNotify(context, fromNumber),
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Copy number'),
        ),
      if (fromNumber.isNotEmpty && isPhoneDevice)
        FilledButton.tonalIcon(
          onPressed: () async {
            final uri = Uri.parse('tel:$fromNumber');
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
          icon: const Icon(Icons.phone, size: 18),
          label: const Text('Call back'),
        ),
      if (appointmentId != null && appointmentId.isNotEmpty)
        FilledButton.tonalIcon(
          onPressed: () => context.push('/appointments/$appointmentId'),
          icon: const Icon(Icons.event, size: 18),
          label: const Text('View appointment'),
        ),
    ];
    if (actions.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Quick actions',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: actions),
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
            const SizedBox(width: 16),
            Expanded(child: recordingCard),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTranscriptCard(context, transcript!),
          const SizedBox(height: 16),
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
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            transcript,
            style: Theme.of(context).textTheme.bodyMedium,
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
          style: Theme.of(context).textTheme.titleSmall,
        ),
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
              Row(
                children: [
                  _RecordingStatusChip(label: statusLabel, isAvailable: hasRecording),
                  if (recordingDuration != null && recordingDuration > 0) ...[
                    const SizedBox(width: 8),
                    Text(
                      formatCallDuration(recordingDuration),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Text(
                statusExplanation,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              if (hasRecording) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _recordingActionBusy
                          ? null
                          : (_isPlaying ? _stopPlaying : _playRecording),
                      icon: Icon(_isPlaying ? Icons.stop : Icons.play_arrow, size: 18),
                      label: Text(_isPlaying ? 'Stop' : 'Play'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _recordingActionBusy ? null : _downloadRecording,
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('Download'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _recordingActionBusy ? null : _copyRecordingLink,
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
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

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback? onTap;

  const _DetailRow({
    required this.label,
    required this.value,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final child = Padding(
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
          Text(
            value,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ],
      ),
    );

    if (onTap != null) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: child,
      );
    }
    return child;
  }
}
