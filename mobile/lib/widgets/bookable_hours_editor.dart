import 'package:flutter/material.dart';

import '../../models/bookable_hours.dart';

/// Required weekly open/closed + 24h start–end editor for assistant setup.
class BookableHoursEditor extends StatelessWidget {
  const BookableHoursEditor({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final BookableHours value;
  final ValueChanged<BookableHours> onChanged;

  void _notify() => onChanged(value);

  Future<void> _pickTime({
    required BuildContext context,
    required String dayKey,
    required bool isStart,
  }) async {
    final day = value.weekly[dayKey]!;
    final initialMinutes = isStart ? day.startMinutes : day.endMinutes;
    final initial = TimeOfDay(
      hour: initialMinutes ~/ 60,
      minute: initialMinutes % 60,
    );
    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
    if (picked == null) return;
    final minutes = picked.hour * 60 + picked.minute;
    if (isStart) {
      day.startMinutes = minutes;
    } else {
      day.endMinutes = minutes;
    }
    _notify();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Bookable hours',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Required. Set every day of the week. Use 24-hour times — overnight '
          'is allowed (e.g. 22:00–06:00). Callers can only book inside these windows.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () {
              value.copyWeekdaysFromMonday();
              _notify();
            },
            child: const Text('Copy Monday to weekdays'),
          ),
        ),
        const SizedBox(height: 4),
        ...BookableHours.dayKeys.map((key) {
          final day = value.weekly[key]!;
          final label = BookableHours.dayLabels[key]!;
          final overnight =
              day.open && day.endMinutes <= day.startMinutes;
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: theme.dividerColor),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            label,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Switch(
                          value: day.open,
                          onChanged: (v) {
                            day.open = v;
                            _notify();
                          },
                        ),
                        Text(day.open ? 'Open' : 'Closed'),
                        const SizedBox(width: 4),
                      ],
                    ),
                    if (day.open) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => _pickTime(
                                context: context,
                                dayKey: key,
                                isStart: true,
                              ),
                              child: Text(
                                'Start ${formatHhMm(day.startMinutes)}',
                              ),
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Text('–'),
                          ),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => _pickTime(
                                context: context,
                                dayKey: key,
                                isStart: false,
                              ),
                              child: Text(
                                'End ${formatHhMm(day.endMinutes)}',
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (overnight)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Overnight (ends next day)',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          );
        }),
      ],
    );
  }
}
