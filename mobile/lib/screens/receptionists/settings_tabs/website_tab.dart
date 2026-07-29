import 'dart:convert';

import 'package:flutter/material.dart';

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
  bool _loading = false;
  bool _showForm = false;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_showForm) {
      return ListView(
        padding: const EdgeInsets.all(EchoDeskSpacing.lg),
        children: [
          const Text(
            'Add your website or business links so the assistant can reference them.',
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => setState(() => _showForm = true),
            child: const Text('Add website info'),
          ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.all(EchoDeskSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Add your website URL to pull in information your assistant can use.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _urlController,
            decoration: const InputDecoration(
              labelText: 'Website URL',
              hintText: 'https://yoursite.com',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _loading
                ? null
                : () async {
                    final url = _urlController.text.trim();
                    if (url.isEmpty) return;
                    setState(() => _loading = true);
                    try {
                      final res = await ApiClient.post(
                        '/api/mobile/receptionists/${widget.receptionistId}/website',
                        body: {'url': url},
                      );
                      if (res.statusCode >= 200 && res.statusCode < 300) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Website content saved')),
                          );
                        }
                      } else {
                        final data = jsonDecode(res.body) as Map<String, dynamic>?;
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content:
                                  Text((data?['error'] as String?) ?? 'Failed'),
                            ),
                          );
                        }
                      }
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text(AppStrings.couldNotFetchWebsite)),
                        );
                      }
                    }
                    if (mounted) setState(() => _loading = false);
                  },
            child: _loading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Fetch from website'),
          ),
        ],
      ),
    );
  }
}

