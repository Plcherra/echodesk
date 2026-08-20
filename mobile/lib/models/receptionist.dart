class Receptionist {
  final String id;
  final String name;
  final String phoneNumber;
  final String? status;
  final String? inboundPhoneNumber;
  final String? calendarId;
  final String? systemPrompt;
  final String? greeting;
  final String? voiceId;
  /// Curated voice preset key (e.g. friendly_warm) for UI label. Internal/admin only: voice_id is used for TTS.
  final String? voicePresetKey;
  final String? voiceCloneId;
  final String? assistantIdentity;
  final String? extraInstructions;

  Receptionist({
    required this.id,
    required this.name,
    required this.phoneNumber,
    this.status,
    this.inboundPhoneNumber,
    this.calendarId,
    this.systemPrompt,
    this.greeting,
    this.voiceId,
    this.voicePresetKey,
    this.voiceCloneId,
    this.assistantIdentity,
    this.extraInstructions,
  });

  String get displayPhone => inboundPhoneNumber ?? phoneNumber;

  factory Receptionist.fromJson(Map<String, dynamic> json) {
    return Receptionist(
      id: json['id'] as String,
      name: json['name'] as String,
      phoneNumber: json['phone_number'] as String,
      status: json['status'] as String?,
      inboundPhoneNumber: json['inbound_phone_number'] as String?,
      calendarId: json['calendar_id'] as String?,
      systemPrompt: json['system_prompt'] as String?,
      greeting: json['greeting'] as String?,
      voiceId: json['voice_id'] as String?,
      voicePresetKey: json['voice_preset_key'] as String?,
      voiceCloneId: json['voice_clone_id'] as String?,
      assistantIdentity: json['assistant_identity'] as String?,
      extraInstructions: json['extra_instructions'] as String?,
    );
  }
}
