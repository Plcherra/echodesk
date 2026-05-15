import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: const Text('Help'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Guides and support for your AI receptionist.',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          _HelpCard(
            title: 'Getting started',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Complete onboarding: connect Google Calendar, choose a plan, then create your first receptionist from My Receptionists. Your receptionist answers calls on your business number.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => context.push('/settings'),
                      child: const Text('Settings'),
                    ),
                    TextButton(
                      onPressed: () => context.push('/receptionists'),
                      child: const Text('My Receptionists'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _HelpCard(
            title: 'Connect Google Calendar',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Go to Settings and tap Connect Google Calendar. Authorize with the account that holds the calendar you use for appointments.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => context.push('/settings'),
                  child: const Text('Open Settings'),
                ),
              ],
            ),
          ),
          _HelpCard(
            title: 'Billing and plans',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Subscription plans include a fixed monthly price and included minutes. Usage is tracked per receptionist; you can see "Minutes this period" on the dashboard. Overage may be billed if you exceed your included minutes.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => context.push('/settings'),
                  child: const Text('Manage subscription'),
                ),
              ],
            ),
          ),
          _HelpCard(
            title: 'Contact support',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Email us with questions or issues.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => launchUrl(
                    Uri.parse(
                      'mailto:echodesk2@gmail.com?subject=AI%20Receptionist%20Support',
                    ),
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.email_outlined),
                  label: const Text('echodesk2@gmail.com'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HelpCard extends StatelessWidget {
  final String title;
  final Widget child;

  const _HelpCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}
