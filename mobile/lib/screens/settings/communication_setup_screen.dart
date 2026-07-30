import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/env.dart';
import '../../services/api_client.dart';
import '../../widgets/constrained_scaffold_body.dart';

/// Voice onboarding: business-owned line first; assistant context is secondary.
/// SMS and WhatsApp setup are hidden (coming soon).
class CommunicationSetupScreen extends StatefulWidget {
  const CommunicationSetupScreen({super.key});

  @override
  State<CommunicationSetupScreen> createState() =>
      _CommunicationSetupScreenState();
}

class _CommunicationSetupScreenState extends State<CommunicationSetupScreen> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _setup;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiClient.get('/api/mobile/communication/setup');
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200) {
        setState(() {
          _error = body['error']?.toString() ?? 'Could not load setup';
          _setup = null;
          _loading = false;
        });
        return;
      }
      setState(() {
        _setup = body;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _setup = null;
        _loading = false;
      });
    }
  }

  String _s(Map<String, dynamic>? m, String key) =>
      m?[key]?.toString().trim() ?? '';

  Future<void> _openReceptionistCreate() async {
    await context.push('/receptionists/create');
    if (!mounted) return;
    await _load();
  }

  Future<void> _emailSupport() async {
    final email = Env.supportEmail;
    final uri = Uri.parse(
      'mailto:$email?subject=EchoDesk%20SMS%20%2F%20WhatsApp',
    );
    try {
      final ok = await launchUrl(uri);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Email us at $email')),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Email us at $email')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Communication setup'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: constrainedScaffoldBody(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!, textAlign: TextAlign.center),
                          const SizedBox(height: 16),
                          FilledButton(
                              onPressed: _load, child: const Text('Retry')),
                        ],
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 16),
                    children: [
                      if (_setup != null) _businessLineHero(context, _setup!),
                      const SizedBox(height: 16),
                      if (_setup != null) _nextStepBanner(context, _setup!),
                      const SizedBox(height: 12),
                      _comingSoonChannels(context),
                      const SizedBox(height: 24),
                    ],
                  ),
      ),
    );
  }

  /// Business line is the visual hero; assistant is secondary context.
  Widget _businessLineHero(BuildContext context, Map<String, dynamic> s) {
    final scheme = Theme.of(context).colorScheme;
    final bizName = s['business_name']?.toString();
    final isDefault = s['is_default_business'] == true;
    final e164 = s['phone_number_e164']?.toString();
    final voice = s['voice_status']?.toString() ?? '—';
    final voiceTitle = _s(s, 'voice_setup_title');
    final voiceDescription = _s(s, 'voice_setup_description');
    final voiceHelp = _s(s, 'voice_help_text');
    final voiceAction = _s(s, 'voice_primary_action');
    final assistant = s['primary_receptionist_name']?.toString();
    final lineText = (e164 != null && e164.isNotEmpty)
        ? e164
        : (voice == 'failed'
            ? 'Phone setup failed'
            : voice == 'provisioning'
                ? 'Provisioning...'
                : 'No number yet');

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.phone_in_talk, color: scheme.primary, size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    (bizName != null && bizName.isNotEmpty)
                        ? bizName
                        : 'Your business',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (isDefault)
                  Text(
                    'Default',
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: scheme.secondary),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Business line',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              lineText,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 6),
            Text(
              voiceTitle.isNotEmpty
                  ? '$voiceTitle · $voice'
                  : 'Voice calls · $voice',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (voiceDescription.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                voiceDescription,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            if (voiceHelp.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                voiceHelp,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.error),
              ),
            ],
            if (voiceAction.isNotEmpty) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: voice == 'provisioning'
                    ? OutlinedButton.icon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: Text(voiceAction),
                      )
                    : FilledButton(
                        onPressed: _openReceptionistCreate,
                        child: Text(voiceAction),
                      ),
              ),
            ],
            if (assistant != null && assistant.isNotEmpty) ...[
              const SizedBox(height: 16),
              Divider(color: scheme.outlineVariant),
              const SizedBox(height: 12),
              Text(
                'Primary assistant',
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 2),
              Text(
                assistant,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              Text(
                'Answers calls on this shared business line.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Voice-only next steps. SMS / WhatsApp prompts are suppressed while those
  /// channels are coming soon.
  Widget _nextStepBanner(BuildContext context, Map<String, dynamic> s) {
    final next = s['next_recommended_action']?.toString() ?? '';
    if (next.isEmpty || next == 'none') return const SizedBox.shrink();

    final String? msg;
    switch (next) {
      case 'create_receptionist':
        msg =
            'Next: create your first receptionist to set up the business line.';
        break;
      case 'check_voice':
        msg = 'Voice line setup is in progress — refresh to check status.';
        break;
      case 'activate_sms':
      case 'submit_sms':
      case 'check_sms':
      case 'retry_sms':
      case 'connect_whatsapp':
      case 'continue_whatsapp':
      case 'check_whatsapp':
      case 'retry_whatsapp':
        return const SizedBox.shrink();
      default:
        // Unknown actions that mention sms/whatsapp stay hidden.
        final lower = next.toLowerCase();
        if (lower.contains('sms') || lower.contains('whatsapp')) {
          return const SizedBox.shrink();
        }
        msg = 'Next: $next';
    }
    return Text(
      msg,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.primary,
          ),
    );
  }

  Widget _comingSoonChannels(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final supportEmail = Env.supportEmail;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'SMS & WhatsApp',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Coming soon',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Text messaging and WhatsApp for your business line are on the way. '
              'Voice calls work today — we’ll let you know when SMS and WhatsApp are ready.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Text(
              'Questions? Email $supportEmail',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _emailSupport,
                icon: const Icon(Icons.email_outlined, size: 18),
                label: Text(supportEmail),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
