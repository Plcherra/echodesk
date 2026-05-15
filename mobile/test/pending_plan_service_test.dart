import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echodesk_mobile/services/pending_plan_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('saves and reads valid subscription plans', () async {
    await PendingPlanService.save('dev_test');

    expect(await PendingPlanService.peekValid(), 'dev_test');
  });

  test('ignores invalid plan ids', () async {
    await PendingPlanService.save('enterprise');

    expect(await PendingPlanService.peekValid(), isNull);
  });

  test('clears invalid persisted plan ids', () async {
    SharedPreferences.setMockInitialValues({'pending_plan_id': 'payg'});

    expect(await PendingPlanService.peekValid(), isNull);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('pending_plan_id'), isFalse);
  });

  test('clears pending plan', () async {
    await PendingPlanService.save('starter');
    await PendingPlanService.clear();

    expect(await PendingPlanService.peekValid(), isNull);
  });
}
