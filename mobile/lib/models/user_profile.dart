/// Active, trialing, and Apple billing-grace accounts can use the product.
bool subscriptionIsEntitled(String? status) {
  switch ((status ?? '').toLowerCase()) {
    case 'active':
    case 'trialing':
    case 'grace_period':
      return true;
    default:
      return false;
  }
}

class UserProfile {
  final String? subscriptionStatus;
  final String? billingPlan;
  final Map<String, dynamic>? billingPlanMetadata;
  final String? phone;
  final String? calendarId;
  final String? businessName;
  final String? businessAddress;
  final String? onboardingCompletedAt;

  UserProfile({
    this.subscriptionStatus,
    this.billingPlan,
    this.billingPlanMetadata,
    this.phone,
    this.calendarId,
    this.businessName,
    this.businessAddress,
    this.onboardingCompletedAt,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      subscriptionStatus: json['subscription_status'] as String?,
      billingPlan: json['billing_plan'] as String?,
      billingPlanMetadata:
          json['billing_plan_metadata'] as Map<String, dynamic>?,
      phone: json['phone'] as String?,
      calendarId: json['calendar_id'] as String?,
      businessName: json['business_name'] as String?,
      businessAddress: json['business_address'] as String?,
      onboardingCompletedAt: json['onboarding_completed_at'] as String?,
    );
  }

  bool get isActive => subscriptionIsEntitled(subscriptionStatus);

  int? get overageRateCents {
    final value = billingPlanMetadata?['overage_rate_cents'];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }

  /// Apple-billed accounts are a hard cap. Stripe metadata omits this.
  String? get billingSource {
    final value = billingPlanMetadata?['billing_source'];
    return value is String ? value : null;
  }
  bool get hasCalendar => (calendarId ?? '').trim().isNotEmpty;
  bool get hasPhone => (phone ?? '').trim().isNotEmpty;
  bool get onboardingComplete =>
      (onboardingCompletedAt ?? '').trim().isNotEmpty;

  int? get includedMinutes {
    final meta = billingPlanMetadata;
    if (meta == null) return null;
    final v = meta['included_minutes'];
    return v is int ? v : null;
  }
}
