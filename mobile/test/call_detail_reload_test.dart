import 'package:echodesk_mobile/screens/calls/call_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('replaces the open call when the notification id changes',
      (tester) async {
    Future<void> pumpCall(String callId, String transcript) {
      return tester.pumpWidget(
        MaterialApp(
          home: CallDetailScreen(
            receptionistId: 'rec-1',
            callId: callId,
            callData: {
              'from_number': '',
              'transcript': transcript,
              'recording_status': 'not_recorded',
            },
          ),
        ),
      );
    }

    await pumpCall('log-1', 'first transcript');
    expect(find.text('first transcript'), findsOneWidget);

    await pumpCall('log-2', 'second transcript');
    expect(find.text('second transcript'), findsOneWidget);
    expect(find.text('first transcript'), findsNothing);
  });
}
