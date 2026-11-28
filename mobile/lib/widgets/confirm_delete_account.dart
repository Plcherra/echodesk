import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/api_client.dart';
import '../strings.dart';
import '../theme/echodesk_theme.dart';

const _deleteAccountIntro =
    'This permanently deletes your EchoDesk account, receptionists, '
    'call history, and bookings we stored. Your business number is released. ';

/// Copy for the delete confirmation. Apple billing continues after the
/// EchoDesk account is gone, on every platform.
String deleteAccountMessage({required bool appleBilled}) {
  if (appleBilled) {
    return '${_deleteAccountIntro}Deleting the account does not cancel an Apple subscription. '
        'Cancel it in your App Store account settings or Apple will keep charging. '
        'This cannot be undone.';
  }
  return '${_deleteAccountIntro}Any subscription is canceled. This cannot be undone.';
}

Future<bool> _accountIsAppleBilled() async {
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) return false;
  try {
    final row = await Supabase.instance.client
        .from('users')
        .select('billing_plan_metadata')
        .eq('id', user.id)
        .maybeSingle();
    final meta = row?['billing_plan_metadata'];
    return meta is Map && meta['billing_source'] == 'apple';
  } catch (_) {
    // Don't promise that billing stopped when the source couldn't be read.
    return true;
  }
}

/// Confirms, then permanently deletes the signed-in account.
Future<void> confirmDeleteAccount(BuildContext context) async {
  final appleBilled = await _accountIsAppleBilled();
  if (!context.mounted) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete account?'),
      content: Text(deleteAccountMessage(appleBilled: appleBilled)),
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
