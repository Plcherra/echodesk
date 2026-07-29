import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Confirms before signing out — same AlertDialog pattern as destructive
/// appointment actions.
Future<void> confirmSignOut(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Sign out?'),
      content: const Text(
        'You will need to sign in again to manage your AI receptionist.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Stay signed in'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Sign out'),
        ),
      ],
    ),
  );
  if (ok == true) {
    await Supabase.instance.client.auth.signOut();
  }
}
