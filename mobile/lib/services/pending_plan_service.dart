import 'package:shared_preferences/shared_preferences.dart';

import '../models/plan.dart';

class PendingPlanService {
  static const _key = 'pending_plan_id';

  static bool isValidPlanId(String? planId) {
    final normalized = planId?.trim();
    if (normalized == null || normalized.isEmpty) return false;
    return Plan.subscriptionPlans.any((plan) => plan.id == normalized);
  }

  static Future<void> save(String? planId) async {
    final normalized = planId?.trim();
    if (!isValidPlanId(normalized)) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, normalized!);
  }

  static Future<String?> peekValid() async {
    final prefs = await SharedPreferences.getInstance();
    final planId = prefs.getString(_key)?.trim();
    if (!isValidPlanId(planId)) {
      await prefs.remove(_key);
      return null;
    }
    return planId;
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
