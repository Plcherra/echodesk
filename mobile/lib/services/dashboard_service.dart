import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'api_client.dart';
import '../models/receptionist.dart';

class DashboardData {
  final Map<String, dynamic> profile;
  final List<Receptionist> receptionists;
  final int totalReceptionists;
  final int activeReceptionists;
  final int totalUsageMinutes;
  final int? includedMinutes;
  final int overageMinutes;
  final int? remainingMinutes;
  final bool isPayg;
  final int totalCalls;
  final double totalCallMinutes;
  final List<Map<String, dynamic>> recentCalls;

  const DashboardData({
    required this.profile,
    required this.receptionists,
    required this.totalReceptionists,
    required this.activeReceptionists,
    required this.totalUsageMinutes,
    required this.includedMinutes,
    required this.overageMinutes,
    required this.remainingMinutes,
    required this.isPayg,
    required this.totalCalls,
    required this.totalCallMinutes,
    required this.recentCalls,
  });
}

class DashboardService {
  const DashboardService();

  Future<DashboardData> loadForUser(String userId) async {
    final supabase = Supabase.instance.client;

    final profileRes = await supabase
        .from('users')
        .select(
            'subscription_status, billing_plan, billing_plan_metadata, phone, '
            'calendar_id, onboarding_completed_at')
        .eq('id', userId)
        .maybeSingle();

    final subscriptionStatus = profileRes?['subscription_status'] ?? '';
    final isActive =
        subscriptionStatus == 'active' || subscriptionStatus == 'trialing';

    List<Receptionist> recs = [];
    int total = 0, active = 0;
    if (isActive) {
      final recsRes = await supabase
          .from('receptionists')
          .select('id, name, phone_number, inbound_phone_number, status')
          .eq('user_id', userId)
          .order('created_at', ascending: false);

      recs = (recsRes as List)
          .map((e) => Receptionist.fromJson(e as Map<String, dynamic>))
          .toList();

      final countRes = await supabase
          .from('receptionists')
          .select('id')
          .eq('user_id', userId);
      total = (countRes as List).length;
      active = recs.where((r) => r.status == 'active').length;
    }

    // Usage: query usage_snapshots for current period (same logic as web dashboard)
    int usageMin = 0, overage = 0;
    int? included;
    int? remaining;
    final meta = profileRes?['billing_plan_metadata'] as Map<String, dynamic>?;
    final billingPlan = profileRes?['billing_plan'] as String?;
    final isPayg = billingPlan == 'subscription_payg';
    if (meta != null && meta['included_minutes'] != null) {
      included = meta['included_minutes'] as int;
    }

    if (isActive) {
      final now = DateTime.now().toUtc();
      final periodStart =
          '${now.year}-${(now.month).toString().padLeft(2, '0')}-01';
      final usageRes = await supabase
          .from('usage_snapshots')
          .select('total_seconds, overage_minutes')
          .eq('user_id', userId)
          .eq('period_start', periodStart);

      final rows = usageRes;
      int totalSeconds = 0;
      for (final r in rows) {
        totalSeconds += (r['total_seconds'] as int?) ?? 0;
        overage += (r['overage_minutes'] as int?) ?? 0;
      }
      usageMin = (totalSeconds / 60).ceil();
      if (included != null && !isPayg) {
        remaining = (included - usageMin).clamp(0, included);
      }
    }

    int totalCalls = 0;
    double totalCallMinutes = 0.0;
    List<Map<String, dynamic>> recentCalls = [];
    int usageMinutesRealtime = 0;
    try {
      final summaryRes = await ApiClient.get('/api/mobile/dashboard-summary');
      if (summaryRes.statusCode >= 200 &&
          summaryRes.statusCode < 300 &&
          summaryRes.body.isNotEmpty) {
        final decoded = jsonDecode(summaryRes.body) as Map<String, dynamic>?;
        totalCalls = decoded?['total_calls'] as int? ?? 0;
        totalCallMinutes =
            (decoded?['total_minutes'] as num?)?.toDouble() ?? 0.0;
        recentCalls = List<Map<String, dynamic>>.from(
            (decoded?['recent_calls'] as List?) ?? []);
        usageMinutesRealtime =
            (decoded?['usage_minutes_realtime'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {}

    // Prefer real-time minutes from user_plans (CDR-updated) so dashboard reflects calls immediately.
    if (usageMinutesRealtime > 0) {
      usageMin = usageMinutesRealtime;
      if (included != null && !isPayg) {
        remaining = (included - usageMin).clamp(0, included);
      }
    } else if (usageMin == 0 && totalCallMinutes > 0) {
      usageMin = totalCallMinutes.ceil();
      if (included != null && !isPayg) {
        remaining = (included - usageMin).clamp(0, included);
      }
    }

    return DashboardData(
      profile: Map<String, dynamic>.from(profileRes ?? {}),
      receptionists: recs,
      totalReceptionists: total,
      activeReceptionists: active,
      totalUsageMinutes: usageMin,
      includedMinutes: included,
      overageMinutes: overage,
      remainingMinutes: remaining,
      isPayg: isPayg,
      totalCalls: totalCalls,
      totalCallMinutes: totalCallMinutes,
      recentCalls: recentCalls,
    );
  }
}
