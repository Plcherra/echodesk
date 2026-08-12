import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/bookable_hours.dart';
import '../../theme/echodesk_theme.dart';

/// Compact weekly hours editor: day chips + shared start/end dropdowns.
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

  /// 30-minute slots across 24h.
  static final List<int> _slotMinutes = [
    for (var m = 0; m < 24 * 60; m += 30) m,
  ];

  void _notify() => widget.onChanged(widget.value);

  void _toggleDay(String key) {
    FocusManager.instance.primaryFocus?.unfocus();
    final day = widget.value.weekly[key]!;
    final willOpen = !day.open;
    day.open = willOpen;
    if (willOpen) {
      for (final k in BookableHours.dayKeys) {
        final other = widget.value.weekly[k]!;
        if (k == key || !other.open) continue;
        day.startMinutes = other.startMinutes;
        day.endMinutes = other.endMinutes;
        break;
      }
    }
    setState(_notify);
  }

  void _setSharedTime({required bool isStart, required int minutes}) {
    FocusManager.instance.primaryFocus?.unfocus();
    for (final key in BookableHours.dayKeys) {
      final day = widget.value.weekly[key]!;
      if (!day.open) continue;
      if (isStart) {
        day.startMinutes = minutes;
      } else {
        day.endMinutes = minutes;
      }
    }
    setState(_notify);
  }

  int _sharedStart() {
    for (final key in BookableHours.dayKeys) {
      final day = widget.value.weekly[key]!;
      if (day.open) return day.startMinutes;
    }
    return 9 * 60;
  }

  int _sharedEnd() {
    for (final key in BookableHours.dayKeys) {
      final day = widget.value.weekly[key]!;
      if (day.open) return day.endMinutes;
    }
    return 17 * 60;
  }

  bool get _anyOpen =>
      BookableHours.dayKeys.any((k) => widget.value.weekly[k]?.open == true);

  bool get _overnight {
    if (!_anyOpen) return false;
    final s = _sharedStart();
    final e = _sharedEnd();
    return e <= s;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final start = _sharedStart();
    final end = _sharedEnd();

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
          'Tap days that are open, then set one start and end time for those days.',
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
                  return _DayChip(
                    letter: _dayLetters[key]!,
                    selected: open,
                    onTap: () => _toggleDay(key),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        if (_anyOpen) ...[
          Row(
            children: [
              Expanded(
                child: _TimeDropdown(
                  label: 'Start',
                  minutes: start,
                  options: _slotMinutes,
                  onChanged: (m) => _setSharedTime(isStart: true, minutes: m),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: Text('–'),
              ),
              Expanded(
                child: _TimeDropdown(
                  label: 'End',
                  minutes: end,
                  options: _slotMinutes,
                  onChanged: (m) => _setSharedTime(isStart: false, minutes: m),
                ),
              ),
            ],
          ),
          if (_overnight) ...[
            const SizedBox(height: 8),
            Text(
              'Overnight — ends the next day',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
          const SizedBox(height: 12),
          TextButton(
            onPressed: () {
              FocusManager.instance.primaryFocus?.unfocus();
              widget.value.copyWeekdaysFromMonday();
              // Ensure weekend stays as currently toggled; copyWeekdays only Mon–Fri.
              setState(_notify);
            },
            child: const Text('Copy Monday hours to Tue–Fri'),
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
    required this.selected,
    required this.onTap,
  });

  final String letter;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? EchoDeskColors.brand : Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? EchoDeskColors.brand : EchoDeskColors.lineStrong,
            ),
          ),
          child: Text(
            letter,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: selected ? Colors.white : EchoDeskColors.ink,
            ),
          ),
        ),
      ),
    );
  }
}

class _TimeDropdown extends StatelessWidget {
  const _TimeDropdown({
    required this.label,
    required this.minutes,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final int minutes;
  final List<int> options;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final value = options.contains(minutes) ? minutes : options.first;
    return DropdownButtonFormField<int>(
      // ignore: deprecated_member_use
      value: value,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      isExpanded: true,
      items: options
          .map(
            (m) => DropdownMenuItem<int>(
              value: m,
              child: Text(formatHhMm(m)),
            ),
          )
          .toList(),
      onChanged: (m) {
        if (m == null) return;
        FocusManager.instance.primaryFocus?.unfocus();
        SystemChannels.textInput.invokeMethod('TextInput.hide');
        onChanged(m);
      },
    );
  }
}
