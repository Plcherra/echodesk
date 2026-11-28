import 'package:echodesk_mobile/widgets/confirm_delete_account.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('apple-billed accounts are told Apple keeps charging', () {
    final message = deleteAccountMessage(appleBilled: true);
    expect(message, contains('does not cancel an Apple subscription'));
    expect(message, contains('App Store'));
    expect(message, isNot(contains('Any subscription is canceled')));
  });

  test('other accounts are told the subscription is canceled', () {
    final message = deleteAccountMessage(appleBilled: false);
    expect(message, contains('Any subscription is canceled'));
    expect(message, isNot(contains('Apple')));
  });
}
