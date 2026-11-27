import 'package:echodesk_mobile/services/push_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('incoming call notification names the receptionist', () {
    expect(
      incomingCallNotificationText('Front Desk'),
      'New call to Front Desk',
    );
    expect(
      incomingCallNotificationText('  '),
      'New call to your receptionist',
    );
  });

  test('incoming call opens that call detail screen', () {
    expect(
      routeForPushData({
        'type': 'incoming_call',
        'call_sid': 'cc-1',
        'receptionist_id': 'rec-1',
        'call_log_id': 'log-9',
      }),
      '/receptionists/rec-1/calls/log-9',
    );
  });

  test('call ended does not open an active-call screen', () {
    final route = routeForPushData({
      'type': 'call_ended',
      'call_sid': 'cc-1',
      'receptionist_id': 'rec-1',
    });
    expect(route, '/receptionists/rec-1/calls');
    expect(route, isNot(startsWith('/call/')));
  });

  test('deep link to call history is preferred', () {
    expect(
      routeForPushData({
        'type': 'incoming_call',
        'deep_link': '/receptionists/rec-2/calls/log-2',
        'receptionist_id': 'other',
      }),
      '/receptionists/rec-2/calls/log-2',
    );
  });
}
