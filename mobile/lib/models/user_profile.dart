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

  bool get isActive =>
      subscriptionStatus == 'active' || subscriptionStatus == 'trialing';
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
