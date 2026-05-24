/// Wizard form data for creating a receptionist (matches AddReceptionistWizardModal)
class StaffItem {
  final String name;
  final String description;

  StaffItem({required this.name, required this.description});

  Map<String, dynamic> toJson() =>
      {'name': name, 'description': description};
}

class ServiceItem {
  final String name;
  final String description;
  final int? durationMinutes;
  final int? priceCents;
  final bool requiresLocation;
  final String? defaultLocationType;

  ServiceItem({
    required this.name,
    required this.description,
    this.durationMinutes,
    this.priceCents,
    this.requiresLocation = false,
    this.defaultLocationType,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        if (durationMinutes != null) 'duration_minutes': durationMinutes,
        if (priceCents != null) 'price_cents': priceCents,
        'requires_location': requiresLocation,
        if (defaultLocationType != null && defaultLocationType!.isNotEmpty)
          'default_location_type': defaultLocationType,
      };
}

class WizardFormData {
  String name;
  String country;
  String calendarId;
  String mode; // 'personal' | 'business'
  String phoneStrategy; // 'new' | 'own'
  String? areaCode;
  String? ownPhone;
  String? providerSid;
  String systemPrompt;
  String? greeting;
  String? voiceId;
  /// Curated voice preset key (e.g. friendly_warm). Sent as voice_preset_key; backend resolves to voice_id.
  String? voicePresetKey;
  String? assistantIdentity;
  List<StaffItem> staff;
  List<ServiceItem> services;
  String? promotions;
  String? businessHours;
  String? extraInstructions;
  String? voicePersonality;
  String? fallbackBehavior;
  String? fallbackTransferNumber;
  int? maxCallDurationMinutes;
  bool consent;

  WizardFormData({
    this.name = '',
    this.country = 'US',
    this.calendarId = 'primary',
    this.mode = 'personal',
    this.phoneStrategy = 'new',
    this.areaCode = '212',
    this.ownPhone,
    this.providerSid,
    this.systemPrompt =
        "You are a friendly, professional receptionist for a [business or personal context, e.g. salon, consulting, personal]. Answer calls politely, book appointments into Google Calendar, confirm details, and be helpful. Never be pushy.",
    this.greeting,
    this.voiceId,
    this.voicePresetKey = 'friendly_warm',
    this.assistantIdentity,
    List<StaffItem>? staff,
    List<ServiceItem>? services,
    this.promotions,
    this.businessHours,
    this.extraInstructions,
    this.voicePersonality = 'friendly',
    this.fallbackBehavior = 'voicemail',
    this.fallbackTransferNumber,
    this.maxCallDurationMinutes,
    this.consent = false,
  })  : staff = staff ?? [],
        services = services ?? [];

  Map<String, dynamic> toApiBody() {
    final body = <String, dynamic>{
      'name': name.trim(),
      'country': country,
      'calendar_id': calendarId.trim(),
      'mode': mode,
      'phone_strategy': phoneStrategy,
      'system_prompt': systemPrompt.trim(),
      'consent': consent,
      'staff': staff.where((s) => s.name.trim().isNotEmpty).map((s) => s.toJson()).toList(),
    };
    if (greeting != null && greeting!.trim().isNotEmpty) body['greeting'] = greeting!.trim();
    if (voicePresetKey != null && voicePresetKey!.trim().isNotEmpty) body['voice_preset_key'] = voicePresetKey!.trim();
    if (phoneStrategy == 'new') {
      body['area_code'] = areaCode ?? '212';
    } else {
      if (ownPhone != null && ownPhone!.trim().isNotEmpty) {
        body['own_phone'] = ownPhone!.trim();
      }
      if (providerSid != null && providerSid!.trim().isNotEmpty) {
        body['provider_sid'] = providerSid!.trim();
      }
    }
    if (promotions != null && promotions!.trim().isNotEmpty) {
      body['promotions'] = promotions!.trim();
    }
    if (extraInstructions != null && extraInstructions!.trim().isNotEmpty) {
      body['extra_instructions'] = extraInstructions!.trim();
    }
    if (businessHours != null && businessHours!.trim().isNotEmpty) {
      body['business_hours'] = businessHours!.trim();
    }
    final servicePayload = services
        .where((s) => s.name.trim().isNotEmpty)
        .map((s) => s.toJson())
        .toList();
    if (servicePayload.isNotEmpty) {
      body['services'] = servicePayload;
    }
    if (voicePersonality != null) body['voice_personality'] = voicePersonality;
    if (fallbackBehavior != null) body['fallback_behavior'] = fallbackBehavior;
    if (fallbackBehavior == 'transfer') {
      final normalized = normalizePhoneToE164(fallbackTransferNumber ?? '');
      if (normalized != null && normalized.isNotEmpty) {
        body['fallback_transfer_number'] = normalized;
      }
    }
    if (maxCallDurationMinutes != null) {
      body['max_call_duration_minutes'] = maxCallDurationMinutes;
    }
    return body;
  }
}

/// Normalizes user input to E.164 (e.g. +16176137764).
/// Accepts spaces, dashes, parentheses; returns null if invalid.
String? normalizePhoneToE164(String input) {
  final onlyPlusAndDigits = input.replaceAll(RegExp(r'[^\d+]'), '');
  if (onlyPlusAndDigits.isEmpty) return null;
  final digits = onlyPlusAndDigits.replaceAll('+', '');
  if (digits.isEmpty) return null;
  String e164;
  if (digits.length == 10 && !digits.startsWith('0')) {
    e164 = '+1$digits';
  } else if (digits.length == 11 && digits.startsWith('1')) {
    e164 = '+$digits';
  } else if (digits.length >= 10 && digits.length <= 15) {
    e164 = '+$digits';
  } else {
    return null;
  }
  if (!RegExp(r'^\+\d{10,15}$').hasMatch(e164)) return null;
  return e164;
}

/// Constants from wizard schemas
class SelectOption {
  final String value;
  final String label;
  const SelectOption(this.value, this.label);
}

const areaCodes = [
  SelectOption('212', '212 (New York)'),
  SelectOption('310', '310 (LA)'),
  SelectOption('415', '415 (San Francisco)'),
  SelectOption('617', '617 (Boston)'),
  SelectOption('646', '646 (New York)'),
  SelectOption('202', '202 (DC)'),
  SelectOption('305', '305 (Miami)'),
  SelectOption('702', '702 (Las Vegas)'),
  SelectOption('312', '312 (Chicago)'),
  SelectOption('404', '404 (Atlanta)'),
  SelectOption('512', '512 (Austin)'),
  SelectOption('206', '206 (Seattle)'),
];

const countryOptions = [
  SelectOption('US', 'United States'),
  SelectOption('CA', 'Canada'),
  SelectOption('UK', 'United Kingdom'),
  SelectOption('Other', 'Other'),
];

const voicePersonalityOptions = [
  SelectOption('friendly', 'Friendly & Warm'),
  SelectOption('professional', 'Professional & Calm'),
  SelectOption('energetic', 'Energetic'),
  SelectOption('calm', 'Calm & Soothing'),
];

/// Maps user-facing voice personality to internal TTS voice ID.
/// Used so onboarding only exposes personality; voice_id is sent to the API internally.
String voiceIdFromPersonality(String? personality) {
  switch (personality) {
    case 'professional':
      return 'voice_professional_v1';
    case 'energetic':
      return 'voice_energetic_v1';
    case 'calm':
      return 'voice_calm_v1';
    case 'friendly':
    default:
      return 'voice_friendly_v1';
  }
}

const fallbackBehaviorOptions = [
  SelectOption('voicemail', 'Take voicemail'),
  SelectOption('transfer', 'Transfer to human'),
];

const locationTypeOptions = [
  SelectOption('no_location', 'No location'),
  SelectOption('customer_address', 'Customer address'),
  SelectOption('phone_call', 'Phone call'),
  SelectOption('video_meeting', 'Video meeting'),
  SelectOption('custom', 'Custom text'),
];
