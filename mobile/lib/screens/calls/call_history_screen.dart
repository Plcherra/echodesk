import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../services/call_history_service.dart';
import '../../utils/call_formatters.dart';
import '../../widgets/constrained_scaffold_body.dart';
import '../../widgets/loading_skeleton.dart';
import '../../widgets/state_views.dart';
import '../../theme/echodesk_theme.dart';

class CallHistoryScreen extends StatefulWidget {
  final String receptionistId;
  final String? receptionistName;

  const CallHistoryScreen({
    super.key,
    required this.receptionistId,
    this.receptionistName,
  });

  @override
  State<CallHistoryScreen> createState() => _CallHistoryScreenState();
}

class _CallHistoryScreenState extends State<CallHistoryScreen> {
  List<Map<String, dynamic>> _calls = [];
  bool _loading = true;
  String? _error;
  String? _degradedReason;
  String? _outcomeFilter;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _degradedReason = null;
    });
    try {
      final result = await loadCallHistoryResult(widget.receptionistId);
      setState(() {
        _calls = result.calls;
        _degradedReason = result.degraded ? result.degradedReason : null;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _filteredCalls {
    if (_outcomeFilter == null || _outcomeFilter!.isEmpty) return _calls;
    return _calls.where((c) => callOutcomeLabel(c) == _outcomeFilter).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: Text(widget.receptionistName ?? 'Call history'),
      ),
      body: constrainedScaffoldBody(
        child: _loading
            ? const ListLoadingView()
            : _error != null
                ? _buildError()
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_degradedReason != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                          child: Text(
                            'Limited call data: $_degradedReason',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      _buildFilterChips(),
                      Expanded(
                        child: RefreshIndicator(
                          onRefresh: _load,
                          child: _filteredCalls.isEmpty
                              ? _buildEmpty()
                              : ListView.builder(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 24, vertical: 16),
                                  itemCount: _filteredCalls.length,
                                  itemBuilder: (context, i) {
                                    final call = _filteredCalls[i];
                                    return _CallRow(
                                      call: call,
                                      onTap: () => _openDetail(call),
                                    );
                                  },
                                ),
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }

  Widget _buildFilterChips() {
    const filters = [
      (null, 'All'),
      ('Completed', 'Completed'),
      ('Short Call', 'Short Call'),
      ('Missed', 'Missed'),
      ('Booked', 'Booked'),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Row(
        children: filters.map((f) {
          final selected = _outcomeFilter == f.$1;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: Text(f.$2),
              selected: selected,
              onSelected: (_) {
                setState(() => _outcomeFilter = selected ? null : f.$1);
              },
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: ErrorStateView(
        title: 'Could not load calls',
        message: _error,
        onRetry: _load,
      ),
    );
  }

  Widget _buildEmpty() {
    final isFiltered = _outcomeFilter != null;
    return CustomScrollView(
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyStateView(
            icon: Icons.phone_missed_outlined,
            title: isFiltered ? 'No $_outcomeFilter calls' : 'No calls yet',
            subtitle: isFiltered
                ? 'Try a different filter.'
                : "When customers call your AI receptionist, they'll appear here.",
          ),
        ),
      ],
    );
  }

  void _openDetail(Map<String, dynamic> call) {
    context.push(
      '/receptionists/${widget.receptionistId}/calls/${call['id']}',
      extra: call,
    );
  }
}

class _CallRow extends StatelessWidget {
  final Map<String, dynamic> call;
  final VoidCallback onTap;

  const _CallRow({required this.call, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final start = call['started_at'] != null
        ? DateTime.tryParse(call['started_at'] as String)
        : null;
    final dur = call['duration_seconds'] as int?;
    final transcript = call['transcript'] as String?;
    final preview = truncateTranscriptPreview(transcript);
    final outcome = callOutcomeLabel(call);
    final fromNumber = call['from_number'] as String? ?? '';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        title: Row(
          children: [
            Expanded(
              child: Text(
                formatCallTimestamp(start),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            if (_hasRecording(call))
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(
                  Icons.mic,
                  size: 16,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            _OutcomeChip(label: outcome),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  formatCallDuration(dur),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (fromNumber.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(
                    formatPhoneForDisplay(fromNumber, mask: true),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ],
            ),
            if (preview.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                preview,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontStyle: FontStyle.italic,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
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

  bool _hasRecording(Map<String, dynamic> call) {
    final status = call['recording_status'] as String?;
    return status == 'available';
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
        return (EchoDeskColors.success, EchoDeskColors.successSoft);
      case 'Completed':
        return (EchoDeskColors.info, EchoDeskColors.infoSoft);
      case 'Short Call':
        return (EchoDeskColors.warning, EchoDeskColors.warningSoft);
      case 'Missed':
        return (EchoDeskColors.danger, EchoDeskColors.dangerSoft);
      default:
        return (EchoDeskColors.muted, EchoDeskColors.surfaceMuted);
    }
  }
}
