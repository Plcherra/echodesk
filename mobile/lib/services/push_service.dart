// Push notification service using Firebase Cloud Messaging.
// Handles token registration, foreground/background messages, and call alerts.

import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'api_client.dart';
import 'call_service.dart';
import '../firebase_options.dart';

// Background message handler - must be top-level
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  final data = message.data;
  if (data.isEmpty) return;
  final type = data['type'] ?? data['notification_type'];
  if (type != 'incoming_call' && type != 'call_ended') return;
  final callSid = data['call_sid'] ?? data['callSid'];
  final receptionistName = data['receptionist_name'] ?? data['receptionistName'];
  final receptionistId = data['receptionist_id'] ?? data['receptionistId'] ?? '';
  final caller = data['caller'] ?? data['callerNumber'] ?? '';
  if (callSid != null && callSid.isNotEmpty) {
    await CallService().handlePushCallEvent(
      type!,
      callSid,
      receptionistName,
      receptionistId: receptionistId?.toString() ?? '',
      caller: caller?.toString() ?? '',
    );
  }
}

class PushService {
  static final PushService _instance = PushService._();
  factory PushService() => _instance;

  PushService._();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  String? _fcmToken;
  String? get fcmToken => _fcmToken;

  bool _initialized = false;
  bool get isInitialized => _initialized;

  void Function(String title, String body)? onForegroundNotification;

  /// Navigate when an appointment (or other non-call) notification is opened.
  void Function(String route)? onNavigate;

  Future<void> initialize() async {
    if (_initialized) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;

    try {
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

      const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
      );
      const initSettings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
        macOS: iosSettings,
      );
      await _localNotifications.initialize(
        settings: initSettings,
        onDidReceiveNotificationResponse: _onNotificationTapped,
      );

      if (Platform.isAndroid) {
        const callChannel = AndroidNotificationChannel(
          'echodesk_calls',
          'Call Alerts',
          description: 'Notifications for incoming and ended calls',
          importance: Importance.high,
        );
        const appointmentChannel = AndroidNotificationChannel(
          'echodesk_appointments',
          'Appointment Alerts',
          description: 'Notifications for new appointments needing review',
          importance: Importance.high,
        );
        final androidPlugin = _localNotifications
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();
        await androidPlugin?.createNotificationChannel(callChannel);
        await androidPlugin?.createNotificationChannel(appointmentChannel);
        // Android 13+: request POST_NOTIFICATIONS at runtime
        await androidPlugin?.requestNotificationsPermission();
      }

      await _requestPermission();
      await _getToken();
      _setupListeners();
      _setupAuthListener();
      await _handleInitialMessage();
      _initialized = true;
    } catch (e) {
      // Firebase may not be configured - allow app to run without push
      if (kDebugMode) print('[PushService] init (non-fatal): $e');
    }
  }

  void _setupAuthListener() {
    Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      if (data.session != null && _fcmToken != null) {
        _registerTokenWithBackend(_fcmToken!);
      }
    });
  }

  /// Handle notification that launched app from terminated state.
  Future<void> _handleInitialMessage() async {
    final message = await _messaging.getInitialMessage();
    if (message?.data != null && message!.data.isNotEmpty) {
      _handleNotificationData(message.data);
    }
  }

  void _setupListeners() {
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final notification = message.notification;
      if (notification != null) {
        if (onForegroundNotification != null) {
          onForegroundNotification!(
            notification.title ?? 'EchoDesk',
            notification.body ?? '',
          );
        } else {
          _showLocalNotification(
            notification.title ?? 'EchoDesk',
            notification.body ?? '',
            message.data,
          );
        }
      }
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      _handleNotificationData(message.data);
    });
  }

  Future<void> _onNotificationTapped(NotificationResponse response) async {
    if (response.payload != null && response.payload!.isNotEmpty) {
      try {
        final decoded = _parsePayload(response.payload!);
        if (decoded.isNotEmpty) _handleNotificationData(decoded);
      } catch (_) {}
    }
  }

  Map<String, dynamic> _parsePayload(String payload) {
    try {
      return Map<String, dynamic>.from(
        jsonDecode(payload) as Map<String, dynamic>,
      );
    } catch (_) {
      return {};
    }
  }

  void _handleNotificationData(Map<String, dynamic> data) {
    final type = data['type'] as String? ?? data['notification_type'] as String?;
    if (type != null && (type == 'incoming_call' || type == 'call_ended')) {
      final callSid = data['call_sid'] as String? ?? data['callSid'] as String?;
      final receptionistName =
          data['receptionist_name'] as String? ?? data['receptionistName'] as String?;
      final receptionistId = (data['receptionist_id'] ?? data['receptionistId'] ?? '') as String;
      final caller = (data['caller'] ?? data['callerNumber'] ?? '') as String;
      CallService().handlePushCallEvent(
        type,
        callSid,
        receptionistName,
        receptionistId: receptionistId,
        caller: caller,
      );
      return;
    }

    if (type == 'appointment_created' || type == 'new_appointment') {
      final deepLink = data['deep_link'] as String?;
      final appointmentId = data['appointment_id'] as String?;
      final status = data['status'] as String?;
      final route = (deepLink != null && deepLink.isNotEmpty)
          ? deepLink
          : (status == 'needs_review' || status == null)
              ? '/appointments?status=needs_review'
              : (appointmentId != null && appointmentId.isNotEmpty)
                  ? '/appointments/$appointmentId'
                  : '/appointments';
      onNavigate?.call(route);
    }
  }

  Future<void> _showLocalNotification(
    String title,
    String body,
    Map<String, dynamic> data,
  ) async {
    final type = data['type'] as String? ?? data['notification_type'] as String?;
    final isAppointment =
        type == 'appointment_created' || type == 'new_appointment';
    final androidDetails = AndroidNotificationDetails(
      isAppointment ? 'echodesk_appointments' : 'echodesk_calls',
      isAppointment ? 'Appointment Alerts' : 'Call Alerts',
      channelDescription: isAppointment
          ? 'Notifications for new appointments needing review'
          : 'Notifications for incoming and ended calls',
      importance: Importance.high,
      priority: Priority.high,
    );
    const iosDetails = DarwinNotificationDetails();
    final details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );
    await _localNotifications.show(
      id: data.hashCode & 0x7FFFFFFF,
      title: title,
      body: body,
      notificationDetails: details,
      payload: jsonEncode(data),
    );
  }

  Future<void> _requestPermission() async {
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    if (kDebugMode) print('[PushService] FCM permission: ${settings.authorizationStatus}');
  }

  Future<void> _getToken() async {
    try {
      _fcmToken = await _messaging.getToken();
      if (kDebugMode) print('[PushService] FCM token: ${_fcmToken?.substring(0, 20)}...');
      if (_fcmToken != null) {
        await _registerTokenWithBackend(_fcmToken!);
      }
    } catch (e) {
      if (kDebugMode) print('[PushService] FCM getToken: $e');
    }

    _messaging.onTokenRefresh.listen((token) {
      _fcmToken = token;
      _registerTokenWithBackend(token);
    });
  }

  Future<void> _registerTokenWithBackend(String token) async {
    try {
      await ApiClient.post('/api/mobile/push-token', body: {'token': token});
    } catch (e) {
      if (kDebugMode) print('[PushService] Register push token: $e');
      // Backend may not have the endpoint yet - non-fatal
    }
  }
}

