import 'dart:convert';

import 'api_client.dart';

class CallHistoryApiException implements Exception {
  final int statusCode;
  final String message;

  const CallHistoryApiException(this.statusCode, this.message);

  @override
  String toString() => message;
}

class CallHistoryResult {
  final List<Map<String, dynamic>> calls;
  final bool degraded;
  final String? degradedReason;

  const CallHistoryResult({
    required this.calls,
    required this.degraded,
    this.degradedReason,
  });
}

/// Load call history response with optional degraded metadata.
Future<CallHistoryResult> loadCallHistoryResult(
  String receptionistId, {
  int limit = 50,
  int offset = 0,
}) async {
  final res = await ApiClient.get(
    '/api/mobile/receptionists/$receptionistId/call-history?limit=$limit&offset=$offset',
  );
  if (res.statusCode >= 200 && res.statusCode < 300 && res.body.isNotEmpty) {
    final decoded = jsonDecode(res.body) as Map<String, dynamic>?;
    return CallHistoryResult(
      calls: List<Map<String, dynamic>>.from((decoded?['calls'] as List?) ?? []),
      degraded: (decoded?['degraded'] as bool?) ?? false,
      degradedReason: decoded?['degraded_reason'] as String?,
    );
  }
  String message = 'Failed to load call history';
  if (res.body.isNotEmpty) {
    try {
      final decoded = jsonDecode(res.body) as Map<String, dynamic>?;
      final err = (decoded?['error'] as String?)?.trim();
      if (err != null && err.isNotEmpty) {
        message = err;
      }
    } catch (_) {}
  }
  throw CallHistoryApiException(res.statusCode, message);
}

/// Fresh recording download URL from the backend (Telnyx presigned; use immediately, do not cache).
Future<String> fetchCallRecordingUrl({
  required String receptionistId,
  required String callId,
}) async {
  final res = await ApiClient.get(
    '/api/mobile/receptionists/$receptionistId/calls/$callId/recording-url',
  );
  if (res.statusCode >= 200 && res.statusCode < 300 && res.body.isNotEmpty) {
    final decoded = jsonDecode(res.body) as Map<String, dynamic>?;
    final url = (decoded?['url'] as String?)?.trim();
    if (url != null && url.isNotEmpty) {
      return url;
    }
  }
  var message = 'Could not get recording link';
  if (res.body.isNotEmpty) {
    try {
      final decoded = jsonDecode(res.body) as Map<String, dynamic>?;
      final err = (decoded?['error'] as String?)?.trim();
      if (err != null && err.isNotEmpty) {
        message = err;
      }
    } catch (_) {}
  }
  throw CallHistoryApiException(res.statusCode, message);
}

/// Load a single call by id (cold open / deep link when route extra is missing).
Future<Map<String, dynamic>> loadCallDetail({
  required String receptionistId,
  required String callId,
}) async {
  final res = await ApiClient.get(
    '/api/mobile/receptionists/$receptionistId/calls/$callId',
  );
  if (res.statusCode >= 200 && res.statusCode < 300 && res.body.isNotEmpty) {
    final decoded = jsonDecode(res.body) as Map<String, dynamic>?;
    final call = decoded?['call'];
    if (call is Map<String, dynamic>) {
      return call;
    }
    if (call is Map) {
      return Map<String, dynamic>.from(call);
    }
  }
  var message = 'Call not found';
  if (res.body.isNotEmpty) {
    try {
      final decoded = jsonDecode(res.body) as Map<String, dynamic>?;
      final err = (decoded?['error'] as String?)?.trim();
      if (err != null && err.isNotEmpty) {
        message = err;
      }
    } catch (_) {}
  }
  throw CallHistoryApiException(res.statusCode, message);
}

/// Load call history for a receptionist.
Future<List<Map<String, dynamic>>> loadCallHistory(
  String receptionistId, {
  int limit = 50,
  int offset = 0,
}) async {
  final result = await loadCallHistoryResult(
    receptionistId,
    limit: limit,
    offset: offset,
  );
  return result.calls;
}
