import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/api_client.dart';
import '../../strings.dart';
import '../../widgets/confirm_sign_out.dart';
import '../../widgets/constrained_scaffold_body.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _loadingBilling = false;
  bool _loadingCalendar = false;
  Map<String, dynamic>? _calendarInfo;
  String? _firstReceptionistId;

  @override
  void initState() {
    super.initState();
    _loadCalendarInfo();
    _loadFirstReceptionist();
  }

  Future<void> _loadFirstReceptionist() async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;
      final res = await Supabase.instance.client
          .from('receptionists')
          .select('id')
          .eq('user_id', user.id)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      if (mounted) {
        setState(() => _firstReceptionistId = res?['id'] as String?);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: constrainedScaffoldBody(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          children: [
            _SectionHeader(title: 'Business'),
            const SizedBox(height: 4),
            ListTile(
              title: const Text('Business name & address'),
              subtitle: const Text('Update in app or dashboard'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 0),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () => context.push('/settings/business-edit'),
            ),
            ListTile(
              title: const Text('Communication setup'),
              subtitle: const Text('Voice line · SMS & WhatsApp coming soon'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 0),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () => context.push('/settings/communication-setup'),
            ),
            const SizedBox(height: 16),
            _SectionHeader(title: 'Booking & follow-up'),
            const SizedBox(height: 4),
            ListTile(
              title: const Text('Appointment confirmation'),
              subtitle: const Text(
                  'Confirmation message templates per receptionist'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 0),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () => _firstReceptionistId != null
                  ? context
                      .push('/receptionists/$_firstReceptionistId/settings')
                  : context.push('/receptionists'),
            ),
            ListTile(
              title: const Text('Payment link defaults'),
              subtitle: const Text('Default payment links for services'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 0),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () => _firstReceptionistId != null
                  ? context
                      .push('/receptionists/$_firstReceptionistId/settings')
                  : context.push('/receptionists'),
            ),
            ListTile(
              title: const Text('Booking instructions'),
              subtitle: const Text('Templates for AI booking behavior'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 0),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () => _firstReceptionistId != null
                  ? context
                      .push('/receptionists/$_firstReceptionistId/settings')
                  : context.push('/receptionists'),
            ),
            const SizedBox(height: 24),
            _SectionHeader(title: 'Billing'),
            const SizedBox(height: 4),
            ListTile(
              title: const Text('Billing Portal'),
              subtitle: const Text('Manage subscription and payment'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 0),
              trailing: _loadingBilling
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right, size: 20),
              onTap: _loadingBilling
                  ? null
                  : () => _openBillingPortal(context),
            ),
            ListTile(
              title: const Text('Subscribe / Upgrade'),
              subtitle: const Text('Starter, Business'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 0),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () => context.push('/checkout'),
            ),
            const SizedBox(height: 24),
            _SectionHeader(title: 'Integrations'),
            const SizedBox(height: 4),
            if (_calendarInfo != null) ...[
              ListTile(
                title: const Text('Google Calendar'),
                subtitle: Text(
                  _calendarInfo!['calendar_connected'] == true
                      ? (_calendarInfo!['connected_google_email'] != null
                          ? 'Connected as ${_calendarInfo!['connected_google_email']}'
                          : 'Connected')
                      : 'Not connected',
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 0),
              ),
              ListTile(
                title: const Text('Booking calendar'),
                subtitle: Text(
                  _calendarInfo!['booking_calendar_label'] ??
                      _calendarInfo!['booking_calendar_id'] ??
                      'primary',
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 0),
              ),
            ],
            ListTile(
              title: const Text('Connect / change Google Calendar'),
              subtitle: const Text('Required for appointment booking'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 0),
              trailing: _loadingCalendar
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right, size: 20),
              onTap:
                  _loadingCalendar ? null : () => _connectCalendar(context),
            ),
            const SizedBox(height: 24),
            _SectionHeader(title: 'Account'),
            const SizedBox(height: 4),
            ListTile(
              title: const Text('Sign Out'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 0),
              trailing: const Icon(Icons.logout, size: 20),
              onTap: () => confirmSignOut(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openBillingPortal(BuildContext context) async {
    if (_loadingBilling) return;
    setState(() => _loadingBilling = true);
    try {
      final res = await ApiClient.post('/api/mobile/billing-portal', body: {
        'return_scheme': 'echodesk',
      });
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final url = data['url'] as String?;
        if (url != null && await canLaunchUrl(Uri.parse(url))) {
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Opening billing portal...')),
            );
          }
        } else {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text(AppStrings.couldNotOpenBilling)),
            );
          }
        }
      } else {
        final data = (res.body.isNotEmpty
                ? jsonDecode(res.body) as Map<String, dynamic>?
                : null) ??
            {};
        final apiErr = data['error'] as String?;
        final err = res.statusCode == 401
            ? AppStrings.sessionExpired
            : (apiErr == 'No billing account. Complete a subscription first.'
                ? AppStrings.billingPortalNoAccount
                : (apiErr == 'Stripe not configured'
                    ? AppStrings.billingPortalStripeNotConfigured
                    : (apiErr ?? AppStrings.billingError)));
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(err)));
        }
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(AppStrings.couldNotOpenBilling)),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingBilling = false);
    }
  }

  Future<void> _connectCalendar(BuildContext context) async {
    if (_loadingCalendar) return;
    setState(() => _loadingCalendar = true);
    try {
      final res = await ApiClient.get(
        '/api/mobile/google-auth-url',
        queryParams: {'return_to': 'mobile'},
      );
      if (res.statusCode == 200) {
        final data = (res.body.isNotEmpty
                ? jsonDecode(res.body) as Map<String, dynamic>?
                : null) ??
            {};
        final url = data['url'] as String?;
        if (url == null || url.trim().isEmpty) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text(AppStrings.calendarAuthUrlMissing)),
            );
          }
        } else {
          final uri = Uri.tryParse(url);
          if (uri == null || !await canLaunchUrl(uri)) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text(AppStrings.calendarCannotOpenUrl)),
              );
            }
          } else {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content:
                        Text('Opening browser to connect Google Calendar...')),
              );
            }
          }
        }
      } else {
        final data = (res.body.isNotEmpty
                ? jsonDecode(res.body) as Map<String, dynamic>?
                : null) ??
            {};
        final apiErr = data['error'] as String?;
        final err = res.statusCode == 401
            ? AppStrings.sessionExpired
            : (apiErr ?? AppStrings.couldNotConnectCalendar);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(err)),
          );
        }
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(AppStrings.couldNotConnectCalendar)),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loadingCalendar = false);
      }
      // After connect attempt, refresh basic calendar info for the user
      await _loadCalendarInfo();
    }
  }

  Future<void> _loadCalendarInfo() async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;
      final res = await Supabase.instance.client
          .from('users')
          .select('email, calendar_id, calendar_refresh_token')
          .eq('id', user.id)
          .maybeSingle();
      if (!mounted) return;
      final calendarId = res?['calendar_id'] as String?;
      final accountEmail = res?['email'] as String?;
      final hasToken =
          (res?['calendar_refresh_token'] as String?)?.isNotEmpty == true;
      final connected =
          hasToken || (calendarId != null && calendarId.isNotEmpty);
      final googleEmail = _displayGoogleEmail(calendarId, accountEmail);
      setState(() {
        _calendarInfo = {
          'connected_google_email': connected ? googleEmail : null,
          'calendar_connected': connected,
          'booking_calendar_id': calendarId ?? 'primary',
          'booking_calendar_label': _bookingCalendarLabel(calendarId),
        };
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _calendarInfo = null);
    }
  }

  /// Prefer an email-shaped calendar_id (Google account), else signup email.
  static String? _displayGoogleEmail(String? calendarId, String? accountEmail) {
    if (calendarId != null && calendarId.contains('@')) return calendarId;
    if (accountEmail != null && accountEmail.contains('@')) return accountEmail;
    return null;
  }

  static String _bookingCalendarLabel(String? calendarId) {
    if (calendarId == null || calendarId.isEmpty) return 'primary';
    if (calendarId == 'primary') return 'Primary';
    if (calendarId.contains('@')) return calendarId;
    return 'Connected calendar';
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
    );
  }
}
