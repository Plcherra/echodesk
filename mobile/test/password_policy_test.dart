import 'package:echodesk_mobile/auth/password_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rejects empty and weak passwords', () {
    expect(PasswordPolicy.validate(null), 'Required');
    expect(PasswordPolicy.validate(''), 'Required');
    expect(PasswordPolicy.isStrong('short1!'), isFalse);
    expect(PasswordPolicy.isStrong('alllowercase1!'), isFalse);
    expect(PasswordPolicy.isStrong('ALLUPPERCASE1!'), isFalse);
    expect(PasswordPolicy.isStrong('NoNumber!aa'), isFalse);
    expect(PasswordPolicy.isStrong('NoSymbol11aa'), isFalse);
  });

  test('accepts a password that meets every rule', () {
    expect(PasswordPolicy.isStrong('EchoDesk1!'), isTrue);
    expect(PasswordPolicy.validate('EchoDesk1!'), isNull);
  });
}
