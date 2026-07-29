import 'dart:convert';

import 'api_client.dart';

/// Load appointments for the current user's receptionists.
/// Optional status filter: confirmed | needs_review | cancelled | completed
/// Optional receptionistId to filter by receptionist.
Future<Map<String, dynamic>> loadAppointments({
  String? status,
  String? receptionistId,
  int limit = 50,
  int offset = 0,
}) async {
  final queryParams = <String, String>{
    'limit': limit.toString(),
    'offset': offset.toString(),
  };
  if (status != null && status.isNotEmpty) {
    queryParams['status'] = status;
  }
  if (receptionistId != null && receptionistId.isNotEmpty) {
    queryParams['receptionist_id'] = receptionistId;
  }
  final qs = queryParams.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
  final res = await ApiClient.get('/api/mobile/appointments?$qs');
  if (res.statusCode >= 200 && res.statusCode < 300 && res.body.isNotEmpty) {
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
  throw Exception(_apiErrorMessage(res.body, fallback: 'Could not load appointments'));
}

/// Today's agenda for one receptionist (local calendar day via [date] + [offsetMinutes]).
Future<Map<String, dynamic>> loadAgendaToday({
  required String receptionistId,
  String? date,
  int? offsetMinutes,
}) async {
  final queryParams = <String, String>{
    'receptionist_id': receptionistId,
  };
  if (date != null && date.isNotEmpty) {
    queryParams['date'] = date;
  }
  if (offsetMinutes != null) {
    queryParams['offset_minutes'] = offsetMinutes.toString();
  }
  final qs = queryParams.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
  final res = await ApiClient.get('/api/mobile/agenda/today?$qs');
  if (res.statusCode >= 200 && res.statusCode < 300 && res.body.isNotEmpty) {
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
  return {'appointments': <Map<String, dynamic>>[]};
}

/// Load single appointment by id.
Future<Map<String, dynamic>?> loadAppointment(String id) async {
  final res = await ApiClient.get('/api/mobile/appointments/$id');
  if (res.statusCode >= 200 && res.statusCode < 300 && res.body.isNotEmpty) {
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
  return null;
}

/// Result of [updateAppointment]. [error] is set when [ok] is false.
typedef AppointmentUpdateResult = ({bool ok, String? error});

/// Update appointment (confirm, cancel, edit service, notes, payment link, etc.)
Future<AppointmentUpdateResult> updateAppointment(
  String id, {
  String? status,
  String? serviceName,
  String? notes,
  String? paymentLink,
  String? locationText,
  String? customerAddress,
  String? internalFollowupNotes,
  String? meetingInstructions,
}) async {
  final body = <String, dynamic>{};
  if (status != null) body['status'] = status;
  if (serviceName != null) body['service_name'] = serviceName;
  if (notes != null) body['notes'] = notes;
  if (paymentLink != null) body['payment_link'] = paymentLink;
  if (locationText != null) body['location_text'] = locationText;
  if (customerAddress != null) body['customer_address'] = customerAddress;
  if (internalFollowupNotes != null) body['internal_followup_notes'] = internalFollowupNotes;
  if (meetingInstructions != null) body['meeting_instructions'] = meetingInstructions;

  if (body.isEmpty) return (ok: true, error: null);

  final res = await ApiClient.patch('/api/mobile/appointments/$id', body: body);
  if (res.statusCode >= 200 && res.statusCode < 300) {
    return (ok: true, error: null);
  }
  return (
    ok: false,
    error: _apiErrorMessage(res.body, fallback: 'Could not update appointment'),
  );
}

String _apiErrorMessage(String body, {required String fallback}) {
  try {
    if (body.isEmpty) return fallback;
    final decoded = jsonDecode(body);
    if (decoded is Map && decoded['error'] != null) {
      return decoded['error'].toString();
    }
  } catch (_) {}
  return body.isNotEmpty ? body : fallback;
}

/// Send confirmation SMS to the appointment caller.
/// [message] optional; if null, backend builds from appointment data.
Future<Map<String, dynamic>> sendConfirmation(String id, {String? message}) async {
  final body = message != null ? {'message': message} : <String, dynamic>{};
  final res = await ApiClient.post(
    '/api/mobile/appointments/$id/send-confirmation',
    body: body.isNotEmpty ? body : null,
  );
  if (res.statusCode >= 200 && res.statusCode < 300) {
    return {'success': true};
  }
  try {
    final decoded = jsonDecode(res.body) as Map<String, dynamic>?;
    return {'success': false, 'error': decoded?['error'] ?? res.body};
  } catch (_) {
    return {'success': false, 'error': res.body.isNotEmpty ? res.body : 'Failed to send'};
  }
}
