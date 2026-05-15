import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../models/plan.dart';
import '../../services/api_client.dart';
import '../../services/pending_plan_service.dart';
import '../../strings.dart';

/// Opens Stripe Checkout in WebView. User returns via deep link (echodesk://checkout?session_id=...).
class CheckoutScreen extends StatefulWidget {
  final String? planId;

  const CheckoutScreen({super.key, this.planId});

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  String? _checkoutUrl;
  String? _error;
  String? _currentPlanId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    if (widget.planId != null &&
        PendingPlanService.isValidPlanId(widget.planId)) {
      _loadCheckoutUrl(widget.planId!);
    } else {
      if (widget.planId != null) {
        PendingPlanService.clear();
      }
      _loading = false;
    }
  }

  Future<void> _loadCheckoutUrl(String planId) async {
    if (!PendingPlanService.isValidPlanId(planId)) {
      await PendingPlanService.clear();
      setState(() {
        _loading = false;
        _error = null;
        _checkoutUrl = null;
        _currentPlanId = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _checkoutUrl = null;
      _currentPlanId = planId;
    });
    try {
      await PendingPlanService.clear();
      final res = await ApiClient.post(
        '/api/mobile/checkout',
        body: {'plan_id': planId, 'return_scheme': 'echodesk'},
      );
      if (res.statusCode == 200) {
        final data = _parseJson(res.body);
        final url = data['url'] as String?;
        setState(() {
          _checkoutUrl = url;
          _loading = false;
          _error = url == null ? 'No checkout URL returned' : null;
        });
      } else {
        final data = _parseJson(res.body);
        final apiErr = data['error'] as String?;
        setState(() {
          _error = res.statusCode == 401
              ? AppStrings.sessionExpired
              : (apiErr ?? 'Failed to create checkout');
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Map<String, dynamic> _parseJson(String body) {
    try {
      return body.isNotEmpty
          ? jsonDecode(body) as Map<String, dynamic>
          : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Subscribe')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Subscribe')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FilledButton(
                      onPressed: () {
                        setState(() {
                          _loading = true;
                          _error = null;
                        });
                        _loadCheckoutUrl(
                          _currentPlanId ?? widget.planId ?? 'starter',
                        );
                      },
                      child: const Text('Retry'),
                    ),
                    const SizedBox(width: 16),
                    OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Back'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (_checkoutUrl == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Choose a plan')),
        body: ListView.separated(
          padding: const EdgeInsets.all(24),
          itemCount: Plan.subscriptionPlans.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final plan = Plan.subscriptionPlans[index];
            return Card(
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                title: Text(plan.name),
                subtitle: Text(
                  plan.includedMinutes > 0
                      ? '${plan.includedMinutes} included minutes'
                      : 'Usage-based billing',
                ),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      plan.priceLabel,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    const Icon(Icons.chevron_right, size: 20),
                  ],
                ),
                onTap: () => _loadCheckoutUrl(plan.id),
              ),
            );
          },
        ),
      );
    }
    if (_checkoutUrl != null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Subscribe'),
          actions: [
            TextButton(
              onPressed: () async {
                if (await canLaunchUrl(Uri.parse(_checkoutUrl!))) {
                  await launchUrl(
                    Uri.parse(_checkoutUrl!),
                    mode: LaunchMode.externalApplication,
                  );
                }
              },
              child: const Text('Open in browser'),
            ),
          ],
        ),
        body: WebViewWidget(
          controller: WebViewController()
            ..setJavaScriptMode(JavaScriptMode.unrestricted)
            ..loadRequest(Uri.parse(_checkoutUrl!)),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
