import 'dart:convert';

import 'package:http/http.dart' as http;

import 'env.dart';

/// Launch acquisition offer: 14-day free trial for the first [totalSpots] customers.
///
/// Remaining spots are loaded live from `GET /api/public/trial-offer` (no redeploy).
/// [claimedSpots] dart-define is only a last-resort offline fallback.
class TrialOffer {
  TrialOffer._();

  static const int trialDays = 14;
  static const int defaultTotalSpots = 100;
  static const int includedMinutes = 60;

  /// Offline fallback only. Prefer the live API.
  static const int claimedSpots = int.fromEnvironment(
    'TRIAL_SPOTS_CLAIMED',
    defaultValue: 0,
  );

  static int _liveTotal = defaultTotalSpots;
  static int? _liveRemaining;

  static int get totalSpots => _liveTotal;

  static int get spotsRemaining {
    if (_liveRemaining != null) return _liveRemaining!;
    final left = defaultTotalSpots - claimedSpots;
    if (left < 0) return 0;
    if (left > defaultTotalSpots) return defaultTotalSpots;
    return left;
  }

  static bool get hasSpotsRemaining => spotsRemaining > 0;

  static String get headline =>
      '$trialDays-day free trial for the first $totalSpots customers';

  static String get spotsLabel {
    final n = spotsRemaining;
    final total = totalSpots;
    if (n <= 0) return 'Trial spots are full — choose a plan to get started';
    if (n == 1) return '1 of $total trial spots left';
    return '$n of $total trial spots left';
  }

  static const List<String> marketingFeatures = [
    '14 days',
    'One phone number',
    '60 included call minutes',
    'Google Calendar booking',
    'Recordings and summaries',
    'No credit card required',
  ];

  /// Fetch live inventory from the backend. Safe to call repeatedly.
  static Future<void> refreshFromApi() async {
    try {
      final base = Env.apiBaseUrl.replaceAll(RegExp(r'/$'), '');
      final uri = Uri.parse('$base/api/public/trial-offer');
      final res = await http.get(
        uri,
        headers: const {'Accept': 'application/json'},
      );
      if (res.statusCode != 200) return;
      final body = jsonDecode(res.body);
      if (body is! Map) return;
      final total = body['total_spots'];
      final remaining = body['remaining'];
      if (total is int && total > 0) {
        _liveTotal = total;
      } else if (total is num && total > 0) {
        _liveTotal = total.toInt();
      }
      if (remaining is int) {
        _liveRemaining = remaining < 0 ? 0 : remaining;
      } else if (remaining is num) {
        final n = remaining.toInt();
        _liveRemaining = n < 0 ? 0 : n;
      }
    } catch (_) {
      // Keep last known / offline fallback.
    }
  }
}
