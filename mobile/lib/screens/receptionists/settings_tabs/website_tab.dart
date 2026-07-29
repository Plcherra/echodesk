import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../services/api_client.dart';
import '../../../strings.dart';
import '../../../theme/echodesk_theme.dart';

class ReceptionistWebsiteTab extends StatefulWidget {
  final String receptionistId;

  const ReceptionistWebsiteTab({super.key, required this.receptionistId});

  @override
  State<ReceptionistWebsiteTab> createState() => _ReceptionistWebsiteTabState();
}

class _ReceptionistWebsiteTabState extends State<ReceptionistWebsiteTab> {
  final _urlController = TextEditingController();
  bool _loadingPage = true;
  bool _fetching = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await Supabase.instance.client
          .from('receptionists')
          .select('website_url')
          .eq('id', widget.receptionistId)
          .maybeSingle();
      final url = (res?['website_url'] as String?)?.trim();
      if (url != null && url.isNotEmpty) {
        _urlController.text = url;
      }
    } catch (_) {
      // Best-effort preload only.
    }
    if (!mounted) return;
    setState(() => _loadingPage = false);
  }

  Future<void> _fetchWebsite() async {
    final url = _urlController.text.trim();
    if (url.isEmpty || _fetching) return;

    setState(() => _fetching = true);
    try {
      final res = await ApiClient.post(
        '/api/mobile/receptionists/${widget.receptionistId}/website',
        body: {'url': url},
      );
      if (!mounted) return;
      if (res.statusCode >= 200 && res.statusCode < 300) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Website content saved')),
        );
      } else {
        final data = jsonDecode(res.body) as Map<String, dynamic>?;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text((data?['error'] as String?) ?? 'Failed'),
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(AppStrings.couldNotFetchWebsite)),
      );
    }
    if (mounted) setState(() => _fetching = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingPage) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      padding: const EdgeInsets.all(EchoDeskSpacing.lg),
      children: [
        Text(
          'Add your website or business links so the assistant can reference them.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: EchoDeskColors.muted,
              ),
        ),
        const SizedBox(height: EchoDeskSpacing.md),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(EchoDeskSpacing.md),
          decoration: BoxDecoration(
            color: EchoDeskColors.surface,
            borderRadius: BorderRadius.circular(EchoDeskRadii.md),
            border: Border.all(color: EchoDeskColors.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Website',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: EchoDeskSpacing.xs),
              Text(
                'Pull in information your assistant can use on calls.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: EchoDeskColors.muted,
                    ),
              ),
              const SizedBox(height: EchoDeskSpacing.sm + 4),
              TextField(
                controller: _urlController,
                decoration: const InputDecoration(
                  labelText: 'Website URL',
                  hintText: 'https://yoursite.com',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _fetchWebsite(),
              ),
            ],
          ),
        ),
        const SizedBox(height: EchoDeskSpacing.lg),
        FilledButton(
          onPressed: _fetching ? null : _fetchWebsite,
          child: _fetching
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Fetch from website'),
        ),
      ],
    );
  }
}
