// Call service for background call handling.
// Shows native CallKit (iOS) / ConnectionService (Android) UI for call alerts.

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter_callkit_incoming/entities/android_params.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import 'package:flutter_callkit_incoming/entities/ios_params.dart';
import 'package:flutter_callkit_incoming/entities/notification_params.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

/// Callback when user taps Accept on incoming call UI.
typedef OnCallAccepted = void Function(String callSid, String receptionistId, String caller);

class CallService {
  static final CallService _instance = CallService._();
  factory CallService() => _instance;

  CallService._();

  bool _initialized = false;
  OnCallAccepted? onCallAccepted;

  Future<void> initialize() async {
    if (_initialized) return;

    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android) {
      FlutterCallkitIncoming.onEvent.listen(_onCallKitEvent);
    }
    _initialized = true;
  }

  void _onCallKitEvent(CallEvent? event) {
    if (event == null) return;
    switch (event.event) {
      case Event.actionCallIncoming:
        break;
      case Event.actionCallStart:
        break;
      case Event.actionCallAccept:
        _handleCallAccepted(event);
        break;
      case Event.actionCallDecline:
        break;
      case Event.actionCallEnded:
        break;
      case Event.actionCallTimeout:
        break;
      case Event.actionCallCallback:
        break;
      default:
        break;
    }
  }

  void _handleCallAccepted(CallEvent event) {
    final body = event.body;
    if (body == null) return;
    final callSid = body['id'] ?? body['call_sid'] ?? '';
    final extra = body['extra'] as Map<String, dynamic>?;
    final receptionistId = extra?['receptionist_id']?.toString() ?? '';
    final caller = extra?['caller']?.toString() ?? '';
    if (callSid.isNotEmpty) {
      onCallAccepted?.call(callSid, receptionistId, caller);
    }
  }

  /// Show incoming call UI when backend pushes call alert.
  Future<void> handlePushCallEvent(
    String type,
    String? callSid,
    String? receptionistName, {
    String receptionistId = '',
    String caller = '',
  }) async {
    if (callSid == null || callSid.isEmpty) return;

    if (type == 'incoming_call') {
      final displayName = caller.isNotEmpty
          ? '${receptionistName ?? 'Receptionist'} – $caller'
          : (receptionistName ?? 'Incoming call');
      await showIncomingCallUI(
        callId: callSid,
        callerName: displayName,
        callerNumber: caller,
        receptionistId: receptionistId,
      );
    } else if (type == 'call_ended') {
      await endCall(callSid);
    }
  }

  /// Display native incoming call UI (CallKit on iOS, ConnectionService on Android).
  Future<void> showIncomingCallUI({
    required String callId,
    required String callerName,
    required String callerNumber,
    String receptionistId = '',
  }) async {
    try {
      final params = CallKitParams(
        id: callId,
        nameCaller: callerName,
        appName: 'EchoDesk',
        avatar: '',
        handle: callerNumber,
        type: 0, // Audio
        textAccept: 'Accept',
        textDecline: 'Decline',
        missedCallNotification: const NotificationParams(
          showNotification: true,
          isShowCallback: false,
          subtitle: 'Missed call',
          callbackText: 'Call back',
        ),
        duration: 30000,
        extra: <String, dynamic>{
          'call_sid': callId,
          'receptionist_id': receptionistId,
          'caller': callerNumber,
        },
        headers: <String, dynamic>{},
        android: const AndroidParams(
          isCustomNotification: false,
          ringtonePath: 'system_ringtone_default',
          backgroundColor: '#0955fa',
          actionColor: '#4CAF50',
        ),
        ios: const IOSParams(
          iconName: 'CallKitLogo',
          handleType: 'generic',
          supportsVideo: false,
          maximumCallGroups: 1,
          maximumCallsPerCallGroup: 1,
          audioSessionMode: 'default',
          audioSessionActive: true,
          audioSessionPreferredSampleRate: 44100.0,
          audioSessionPreferredIOBufferDuration: 0.005,
          supportsDTMF: false,
          supportsHolding: false,
          supportsGrouping: false,
          supportsUngrouping: false,
          ringtonePath: 'system_ringtone_default',
        ),
      );

      await FlutterCallkitIncoming.showCallkitIncoming(params);
    } catch (e) {
      if (e.toString().contains('CallKit')) {
        // CallKit requires real device
      }
    }
  }

  /// End a call by id.
  Future<void> endCall(String callId) async {
    try {
      await FlutterCallkitIncoming.endCall(callId);
    } catch (_) {}
  }

  /// End all active calls.
  Future<void> endAllCalls() async {
    try {
      await FlutterCallkitIncoming.endAllCalls();
    } catch (_) {}
  }

  /// Start outbound call UI (optional - for future VoIP).
  Future<void> startOutgoingCall({
    required String callId,
    required String handle,
    String? name,
  }) async {
    try {
      final params = CallKitParams(
        id: callId,
        nameCaller: name ?? handle,
        handle: handle,
        type: 0,
        extra: <String, dynamic>{'call_sid': callId},
        android: const AndroidParams(isCustomNotification: false),
        ios: const IOSParams(handleType: 'phone'),
      );
      await FlutterCallkitIncoming.startCall(params);
    } catch (_) {}
  }
}
