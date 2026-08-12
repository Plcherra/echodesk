import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/bookable_hours.dart';
import '../../theme/echodesk_theme.dart';

/// Compact weekly hours: day chips + per-day start/end via bottom-sheet pickers.
class BookableHoursEditor extends StatefulWidget {
  const BookableHoursEditor({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final BookableHours value;
  final ValueChanged<BookableHours> onChanged;

  @override
  State<BookableHoursEditor> createState() => _BookableHoursEditorState();
}

class _BookableHoursEditorState extends State<BookableHoursEditor> {
  static const _dayLetters = {
    'sun': 'S',
    'mon': 'M',
    'tue': 'T',
    'wed': 'W',
    'thu': 'T',
    'fri': 'F',
    'sat': 'S',
  };

  /// Which open day is being edited (start/end apply to this day).
  String? _editingKey;

  void _notify() => widget.onChanged(widget.value);

  String? get _effectiveEditingKey {
    final openKeys = BookableHours.dayKeys
        .where((k) => widget.value.weekly[k]?.open == true)
        .toList();
    if (openKeys.isEmpty) return null;
    if (_editingKey != null && openKeys.contains(_editingKey)) {
      return _editingKey;
    }
    return openKeys.first;
  }

  void _toggleDay(String key) {
    FocusManager.instance.primaryFocus?.unfocus();
    final day = widget.value.weekly[key]!;
    final willOpen = !day.open;
    day.open = willOpen;
    if (willOpen) {
      final editKey = _effectiveEditingKey;
      if (editKey != null && editKey != key) {
        final src = widget.value.weekly[editKey]!;
        day.startMinutes = src.startMinutes;
        day.endMinutes = src.endMinutes;
      }
      _editingKey = key;
    } else if (_editingKey == key) {
      _editingKey = null;
    }
    setState(_notify);
  }

  void _selectDayForEdit(String key) {
    if (widget.value.weekly[key]?.open != true) return;
    setState(() => _editingKey = key);
  }

  Future<void> _pickTime({required bool isStart}) async {
    final key = _effectiveEditingKey;
    if (key == null) return;
    final day = widget.value.weekly[key]!;
    final initial = TimeOfDay(
      hour: (isStart ? day.startMinutes : day.endMinutes) ~/ 60,
      minute: (isStart ? day.startMinutes : day.endMinutes) % 60,
    );

    final picked = await showModalBottomSheet<TimeOfDay>(
      context: context,
      isScrollControlled: false,
      builder: (ctx) => _TimeSheet(
        title: isStart ? 'Start time' : 'End time',
        initial: initial,
      ),
    );
    if (picked == null || !mounted) return;
    final minutes = picked.hour * 60 + picked.minute;
    if (isStart) {
      day.startMinutes = minutes;
    } else {
      day.endMinutes = minutes;
    }
    setState(_notify);
  }

  void _applyEditingToAllOpen() {
    final key = _effectiveEditingKey;
    if (key == null) return;
    final src = widget.value.weekly[key]!;
    for (final k in BookableHours.dayKeys) {
      final d = widget.value.weekly[k]!;
      if (!d.open || k == key) continue;
      d.startMinutes = src.startMinutes;
      d.endMinutes = src.endMinutes;
    }
    setState(_notify);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final editKey = _effectiveEditingKey;
    final editDay = editKey == null ? null : widget.value.weekly[editKey];
    final overnight = editDay != null &&
        editDay.open &&
        editDay.endMinutes <= editDay.startMinutes;

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
          'Tap days to open them. Select an open day to set its hours. Long-press to close.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Text(
              'On',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: BookableHours.dayKeys.map((key) {
                  final open = widget.value.weekly[key]?.open == true;
                  final editing = key == editKey;
                  return _DayChip(
                    letter: _dayLetters[key]!,
                    open: open,
                    editing: editing,
                    onTap: () {
                      if (open) {
                        _selectDayForEdit(key);
                      } else {
                        _toggleDay(key);
                      }
                    },
                    onLongPress: () {
                      if (open) _toggleDay(key);
                    },
                  );
                }).toList(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: BookableHours.dayKeys
              .where((k) => widget.value.weekly[k]?.open == true)
              .map((k) {
            final d = widget.value.weekly[k]!;
            final label = BookableHours.dayLabels[k]!.substring(0, 3);
            final active = k == editKey;
            return GestureDetector(
              onTap: () => _selectDayForEdit(k),
              child: Text(
                '$label ${formatHhMm(d.startMinutes)}–${formatHhMm(d.endMinutes)}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: active ? EchoDeskColors.brand : EchoDeskColors.muted,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 14),
        if (editDay != null) ...[
          Text(
            'Hours for ${BookableHours.dayLabels[editKey]}',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _pickTime(isStart: true),
                  child: Text('Start ${formatHhMm(editDay.startMinutes)}'),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: Text('–'),
              ),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _pickTime(isStart: false),
                  child: Text('End ${formatHhMm(editDay.endMinutes)}'),
                ),
              ),
            ],
          ),
          if (overnight) ...[
            const SizedBox(height: 8),
            Text(
              'Overnight — ends the next day',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
          const SizedBox(height: 4),
          TextButton(
            onPressed: _applyEditingToAllOpen,
            child: const Text('Apply these hours to all open days'),
          ),
        ] else
          Text(
            'Select at least one open day.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: EchoDeskColors.danger,
            ),
          ),
      ],
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({
    required this.letter,
    required this.open,
    required this.editing,
    required this.onTap,
    required this.onLongPress,
  });

  final String letter;
  final bool open;
  final bool editing;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final fill = open ? EchoDeskColors.brand : Colors.transparent;
    return Material(
      color: fill,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: editing
                  ? EchoDeskColors.brandTeal
                  : (open ? EchoDeskColors.brand : EchoDeskColors.lineStrong),
              width: editing ? 2.5 : 1,
            ),
          ),
          child: Text(
            letter,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: open ? Colors.white : EchoDeskColors.ink,
            ),
          ),
        ),
      ),
    );
  }
}

class _TimeSheet extends StatefulWidget {
  const _TimeSheet({required this.title, required this.initial});

  final String title;
  final TimeOfDay initial;

  @override
  State<_TimeSheet> createState() => _TimeSheetState();
}

class _TimeSheetState extends State<_TimeSheet> {
  late DateTime _date;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    // CupertinoDatePicker requires minutes divisible by minuteInterval.
    var minute = widget.initial.minute;
    if (minute % 30 != 0) {
      minute = ((minute + 15) ~/ 30) * 30;
      if (minute == 60) minute = 0;
    }
    var hour = widget.initial.hour;
    if (widget.initial.minute >= 45 && minute == 0) {
      hour = (hour + 1) % 24;
    }
    _date = DateTime(now.year, now.month, now.day, hour, minute);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: 280,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () {
                      Navigator.of(context).pop(
                        TimeOfDay(hour: _date.hour, minute: _date.minute),
                      );
                    },
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.time,
                use24hFormat: true,
                minuteInterval: 30,
                initialDateTime: _date,
                onDateTimeChanged: (d) => setState(() => _date = d),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
