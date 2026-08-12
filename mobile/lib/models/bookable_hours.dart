/// Structured weekly bookable hours for receptionist create / settings.
library;

class DayHours {
  bool open;
  /// Minutes from midnight (0–1439).
  int startMinutes;
  int endMinutes;

  DayHours({
    required this.open,
    required this.startMinutes,
    required this.endMinutes,
  });

  factory DayHours.openDefault() => DayHours(
        open: true,
        startMinutes: 9 * 60,
        endMinutes: 17 * 60,
      );

  factory DayHours.closedDefault() => DayHours(
        open: false,
        startMinutes: 9 * 60,
        endMinutes: 17 * 60,
      );

  factory DayHours.fromJson(Map<String, dynamic>? json) {
    if (json == null) return DayHours.closedDefault();
    final open = json['open'] == true;
    return DayHours(
      open: open,
      startMinutes: _parseHhMm(json['start']?.toString()) ?? 9 * 60,
      endMinutes: _parseHhMm(json['end']?.toString()) ?? 17 * 60,
    );
  }

  Map<String, dynamic> toJson() => {
        'open': open,
        'start': formatHhMm(startMinutes),
        'end': formatHhMm(endMinutes),
      };

  DayHours copy() => DayHours(
        open: open,
        startMinutes: startMinutes,
        endMinutes: endMinutes,
      );
}

class BookableHours {
  /// Keys: mon..sun
  final Map<String, DayHours> weekly;

  BookableHours({required this.weekly});

  static const dayKeys = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  static const dayLabels = {
    'mon': 'Monday',
    'tue': 'Tuesday',
    'wed': 'Wednesday',
    'thu': 'Thursday',
    'fri': 'Friday',
    'sat': 'Saturday',
    'sun': 'Sunday',
  };

  factory BookableHours.defaults() {
    final weekly = <String, DayHours>{};
    for (final k in dayKeys) {
      weekly[k] = (k == 'sat' || k == 'sun')
          ? DayHours.closedDefault()
          : DayHours.openDefault();
    }
    return BookableHours(weekly: weekly);
  }

  factory BookableHours.fromJson(Map<String, dynamic>? json) {
    final rawWeekly = json?['weekly'];
    if (rawWeekly is! Map) return BookableHours.defaults();
    final weekly = <String, DayHours>{};
    for (final k in dayKeys) {
      final day = rawWeekly[k];
      weekly[k] = DayHours.fromJson(
        day is Map<String, dynamic>
            ? day
            : (day is Map ? Map<String, dynamic>.from(day) : null),
      );
    }
    return BookableHours(weekly: weekly);
  }

  Map<String, dynamic> toJson() => {
        'weekly': {
          for (final k in dayKeys) k: (weekly[k] ?? DayHours.closedDefault()).toJson(),
        },
      };

  bool get hasAtLeastOneOpenDay =>
      dayKeys.any((k) => weekly[k]?.open == true);

  String? validationError() {
    if (!hasAtLeastOneOpenDay) {
      return 'Open at least one day of the week';
    }
    for (final k in dayKeys) {
      final day = weekly[k];
      if (day == null) continue;
      if (!day.open) continue;
      if (day.startMinutes < 0 ||
          day.startMinutes > 23 * 60 + 59 ||
          day.endMinutes < 0 ||
          day.endMinutes > 23 * 60 + 59) {
        return 'Invalid hours for ${dayLabels[k]}';
      }
    }
    return null;
  }

  void copyWeekdaysFromMonday() {
    final mon = weekly['mon']?.copy() ?? DayHours.openDefault();
    for (final k in ['tue', 'wed', 'thu', 'fri']) {
      weekly[k] = mon.copy();
    }
  }
}

String formatHhMm(int minutes) {
  final h = (minutes ~/ 60).clamp(0, 23);
  final m = (minutes % 60).clamp(0, 59);
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

String formatHhMmSpoken(int minutes) {
  final h24 = (minutes ~/ 60).clamp(0, 23);
  final m = (minutes % 60).clamp(0, 59);
  final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
  final ampm = h24 < 12 ? 'AM' : 'PM';
  if (m == 0) return '$h12 $ampm';
  return '$h12:${m.toString().padLeft(2, '0')} $ampm';
}

int? _parseHhMm(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final parts = raw.trim().split(':');
  if (parts.length < 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  if (h < 0 || h > 23 || m < 0 || m > 59) return null;
  return h * 60 + m;
}
