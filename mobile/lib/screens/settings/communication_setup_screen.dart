import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/api_client.dart';
import '../../widgets/constrained_scaffold_body.dart';

/// Voice / SMS / WhatsApp onboarding: business-owned line first; assistant context is secondary.
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

  Future<void> _openHandoff(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !(uri.hasScheme && (uri.scheme == 'http' || uri.scheme == 'https'))) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid handoff link')),
      );
      return;
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open link')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _post(String path) async {
    try {
      final res = await ApiClient.post(path, body: const {});
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(body['error']?.toString() ?? 'Request failed')),
        );
        return;
      }
      if (!mounted) return;
      final msg = body['message']?.toString();
      if (msg != null && msg.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved')),
        );
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  String _s(Map<String, dynamic>? m, String key) =>
      m?[key]?.toString().trim() ?? '';

  Future<void> _openReceptionistCreate() async {
    await context.push('/receptionists/create');
    if (!mounted) return;
    await _load();
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
                      _channelCard(
                        context,
                        title: _s(_setup, 'sms_setup_title').isEmpty
                            ? 'SMS'
                            : _s(_setup, 'sms_setup_title'),
                        badge: _setup?['sms_status']?.toString() ?? '—',
                        description: _s(_setup, 'sms_setup_description'),
                        detail: _s(_setup, 'sms_failure_reason'),
                        help: _s(_setup, 'sms_help_text'),
                        journey: _journeyTriplet(
                          context,
                          user: _s(_setup, 'sms_user_action_summary'),
                          echoDesk:
                              _s(_setup, 'sms_echo_desk_automation_summary'),
                          waiting: _s(_setup, 'sms_provider_waiting_summary'),
                        ),
                        actions: _smsActions(_setup),
                      ),
                      const SizedBox(height: 12),
                      _channelCard(
                        context,
                        title: _s(_setup, 'whatsapp_setup_title').isEmpty
                            ? 'WhatsApp'
                            : _s(_setup, 'whatsapp_setup_title'),
                        badge: _setup?['whatsapp_status']?.toString() ?? '—',
                        description: _s(_setup, 'whatsapp_setup_description'),
                        detail: _s(_setup, 'whatsapp_failure_reason'),
                        help: _s(_setup, 'whatsapp_help_text'),
                        journey: _journeyTriplet(
                          context,
                          user: _s(_setup, 'whatsapp_user_action_summary'),
                          echoDesk: _s(
                              _setup, 'whatsapp_echo_desk_automation_summary'),
                          waiting:
                              _s(_setup, 'whatsapp_provider_waiting_summary'),
                        ),
                        actions: _waActions(_setup),
                      ),
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
            const SizedBox(height: 8),
            Text(
              'SMS and WhatsApp use this same business number where enabled.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _nextStepBanner(BuildContext context, Map<String, dynamic> s) {
    final next = s['next_recommended_action']?.toString() ?? '';
    if (next.isEmpty || next == 'none') return const SizedBox.shrink();
    String msg;
    switch (next) {
      case 'create_receptionist':
        msg =
            'Next: create your first receptionist to set up the business line.';
        break;
      case 'check_voice':
        msg = 'Voice line setup is in progress — refresh to check status.';
        break;
      case 'activate_sms':
        msg = 'Next: start SMS setup for this business line.';
        break;
      case 'submit_sms':
        msg = 'Next: review and submit SMS registration.';
        break;
      case 'check_sms':
        msg =
            'SMS is awaiting carrier approval — pull to refresh or use Refresh status.';
        break;
      case 'retry_sms':
        msg = 'Next: fix SMS registration.';
        break;
      case 'connect_whatsapp':
        msg = 'Next: start WhatsApp setup.';
        break;
      case 'continue_whatsapp':
        msg = 'Next: finish Meta / Telnyx connection for WhatsApp.';
        break;
      case 'check_whatsapp':
        msg =
            'WhatsApp is in progress with your provider — refresh to check status.';
        break;
      case 'retry_whatsapp':
        msg = 'Next: retry WhatsApp setup.';
        break;
      default:
        msg = 'Next: $next';
    }
    return Text(
      msg,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.primary,
          ),
    );
  }

  List<Widget> _smsActions(Map<String, dynamic>? s) {
    if (s == null) return [];
    final st = s['sms_status']?.toString() ?? '';
    final primary = _s(s, 'sms_primary_action');
    final out = <Widget>[];
    if (st == 'not_started') {
      out.add(
        FilledButton(
          onPressed: () => _post('/api/mobile/communication/sms/activate'),
          child: Text(primary.isEmpty ? 'Start SMS setup' : primary),
        ),
      );
    } else if (st == 'needs_submission') {
      out.add(
        FilledButton(
          onPressed: () => _post('/api/mobile/communication/sms/submit'),
          child: Text(primary.isEmpty ? 'Review SMS details' : primary),
        ),
      );
    } else if (st == 'pending_review') {
      out.add(
        OutlinedButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh, size: 18),
          label: Text(primary.isEmpty ? 'Refresh status' : primary),
        ),
      );
    } else if (st == 'failed') {
      out.add(
        FilledButton(
          onPressed: () => _post('/api/mobile/communication/sms/retry'),
          child: Text(primary.isEmpty ? 'Fix SMS setup' : primary),
        ),
      );
    }
    return out;
  }

  List<Widget> _waActions(Map<String, dynamic>? s) {
    if (s == null) return [];
    final st = s['whatsapp_status']?.toString() ?? '';
    final primary = _s(s, 'whatsapp_primary_action');
    final handoff = _s(s, 'whatsapp_handoff_url');
    final out = <Widget>[];
    if (handoff.isNotEmpty && (st == 'needs_connection' || st == 'pending')) {
      out.add(
        OutlinedButton.icon(
          onPressed: () => _openHandoff(handoff),
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('Open Telnyx / Meta'),
        ),
      );
    }
    if (st == 'not_connected') {
      out.add(
        FilledButton(
          onPressed: () => _post('/api/mobile/communication/whatsapp/connect'),
          child: Text(primary.isEmpty ? 'Start WhatsApp setup' : primary),
        ),
      );
    } else if (st == 'needs_connection') {
      out.add(
        FilledButton(
          onPressed: () => _post('/api/mobile/communication/whatsapp/continue'),
          child: Text(primary.isEmpty ? 'Continue WhatsApp setup' : primary),
        ),
      );
    } else if (st == 'pending') {
      out.add(
        OutlinedButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh, size: 18),
          label: Text(primary.isEmpty ? 'Check status' : primary),
        ),
      );
    } else if (st == 'failed') {
      out.add(
        FilledButton(
          onPressed: () => _post('/api/mobile/communication/whatsapp/retry'),
          child: Text(primary.isEmpty ? 'Retry WhatsApp setup' : primary),
        ),
      );
    }
    return out;
  }

  List<Widget>? _journeyTriplet(
    BuildContext context, {
    required String user,
    required String echoDesk,
    required String waiting,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(context).textTheme.labelLarge?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        );
    final bodyStyle = Theme.of(context).textTheme.bodySmall;
    final blocks = <Widget>[];
    void add(String heading, String text) {
      if (text.isEmpty) return;
      blocks.add(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(heading, style: labelStyle),
            const SizedBox(height: 2),
            Text(text, style: bodyStyle),
          ],
        ),
      );
    }

    add('What you need to do', user);
    add('What EchoDesk does automatically', echoDesk);
    add('Waiting on provider / Meta', waiting);
    if (blocks.isEmpty) return null;
    final spaced = <Widget>[];
    for (var i = 0; i < blocks.length; i++) {
      if (i > 0) spaced.add(const SizedBox(height: 10));
      spaced.add(blocks[i]);
    }
    return spaced;
  }

  Widget _channelCard(
    BuildContext context, {
    required String title,
    required String badge,
    required String description,
    String? detail,
    String? help,
    List<Widget>? journey,
    required List<Widget> actions,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                    child: Text(title,
                        style: Theme.of(context).textTheme.titleMedium)),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(badge,
                      style: Theme.of(context).textTheme.labelSmall),
                ),
              ],
            ),
            if (description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(description, style: Theme.of(context).textTheme.bodyMedium),
            ],
            if (detail != null && detail.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(detail,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.error)),
            ],
            if (help != null && help.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(help, style: Theme.of(context).textTheme.bodySmall),
            ],
            if (journey != null && journey.isNotEmpty) ...[
              const SizedBox(height: 12),
              ...journey,
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: actions),
            ],
          ],
        ),
      ),
    );
  }
}
