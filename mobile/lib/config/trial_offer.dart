/// Launch acquisition offer: 14-day free trial for the first [totalSpots] customers.
///
/// Remaining spots are a **client-side counter** for marketing UI only.
/// Update [claimedSpots] (edit default below, or pass
/// `--dart-define=TRIAL_SPOTS_CLAIMED=N` at build/run) as trial seats fill.
///
/// TODO: Replace with a backend/API field once signup tracking exposes remaining seats.
class TrialOffer {
  TrialOffer._();

  static const int trialDays = 14;
  static const int totalSpots = 100;

  /// Number of trial seats already claimed. Override at build time:
  /// `flutter run --dart-define=TRIAL_SPOTS_CLAIMED=12`
  static const int claimedSpots = int.fromEnvironment(
    'TRIAL_SPOTS_CLAIMED',
    defaultValue: 0,
  );

  static int get spotsRemaining {
    final left = totalSpots - claimedSpots;
    if (left < 0) return 0;
    if (left > totalSpots) return totalSpots;
    return left;
  }

  static bool get hasSpotsRemaining => spotsRemaining > 0;

  static String get headline =>
      '$trialDays-day free trial for the first $totalSpots customers';

  static String get spotsLabel {
    final n = spotsRemaining;
    if (n <= 0) return 'Trial spots are full — choose a plan to get started';
    if (n == 1) return '1 trial spot left';
    return '$n trial spots left';
  }
}
