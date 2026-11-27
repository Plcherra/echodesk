import 'package:flutter/material.dart';

import '../config/env.dart';

/// Shown on iOS when an account has no active subscription.
///
/// Plain text only: no link, no website, and no purchase call to action.
class AccountInactiveNotice extends StatelessWidget {
  const AccountInactiveNotice({super.key, this.textAlign = TextAlign.start});

  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) {
    return Text(
      "Your account isn't active yet. Contact ${Env.supportEmail}.",
      textAlign: textAlign,
      style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.45),
    );
  }
}
