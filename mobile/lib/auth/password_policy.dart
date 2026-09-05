class PasswordRequirement {
  const PasswordRequirement({required this.label, required this.met});

  final String label;
  final bool Function(String password) met;
}

/// Shared rules for new passwords (signup + reset).
class PasswordPolicy {
  static const minLength = 8;

  static const requirements = <PasswordRequirement>[
    PasswordRequirement(
      label: 'At least 8 characters',
      met: _hasMinLength,
    ),
    PasswordRequirement(
      label: 'One uppercase letter',
      met: _hasUppercase,
    ),
    PasswordRequirement(
      label: 'One lowercase letter',
      met: _hasLowercase,
    ),
    PasswordRequirement(
      label: 'One number',
      met: _hasDigit,
    ),
    PasswordRequirement(
      label: 'One symbol (like ! @ # %)',
      met: _hasSymbol,
    ),
  ];

  static bool _hasMinLength(String password) => password.length >= minLength;

  static bool _hasUppercase(String password) =>
      password.contains(RegExp(r'[A-Z]'));

  static bool _hasLowercase(String password) =>
      password.contains(RegExp(r'[a-z]'));

  static bool _hasDigit(String password) => password.contains(RegExp(r'[0-9]'));

  static bool _hasSymbol(String password) =>
      password.contains(RegExp(r'[^A-Za-z0-9]'));

  static bool isStrong(String password) =>
      requirements.every((rule) => rule.met(password));

  static String? validate(String? value) {
    if (value == null || value.isEmpty) return 'Required';
    if (!isStrong(value)) {
      return 'Use a stronger password. Meet every requirement below.';
    }
    return null;
  }
}
