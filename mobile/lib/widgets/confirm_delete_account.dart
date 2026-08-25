import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/api_client.dart';
import '../strings.dart';
import '../theme/echodesk_theme.dart';

/// Confirms, then permanently deletes the signed-in account.
Future<void> confirmDeleteAccount(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete account?'),
      content: const Text(
        'This permanently deletes your EchoDesk account, receptionists, '
        'call history, and bookings we stored. Your business number is released. '
        'Any subscription is canceled. This cannot be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Keep account'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: EchoDeskColors.danger,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Delete account'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );

  try {
    final res = await ApiClient.delete('/api/mobile/account');
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    if (res.statusCode >= 200 && res.statusCode < 300) {
      await Supabase.instance.client.auth.signOut();
      if (context.mounted) context.go('/');
      return;
    }
    String message = AppStrings.couldNotDeleteAccount;
    try {
      final data = jsonDecode(res.body);
      if (data is Map && (data['error'] as String?)?.trim().isNotEmpty == true) {
        message = data['error'] as String;
      }
    } catch (_) {}
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  } catch (_) {
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(AppStrings.couldNotDeleteAccount)),
      );
    }
  }
}
