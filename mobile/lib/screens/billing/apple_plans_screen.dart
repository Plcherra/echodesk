import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../config/apple_plans.dart';
import '../../services/apple_iap_service.dart';
import '../../services/apple_subscription_management.dart';
import '../../theme/echodesk_theme.dart';
import '../../widgets/legal_links.dart';

/// Plans screen for accounts with no active subscription.
///
/// Prices come from [ApplePlansController], which reads StoreKit. This widget
/// does not contain a dollar amount.
class ApplePlansScreen extends StatefulWidget {
  const ApplePlansScreen({super.key, this.controller});

  final ApplePlansController? controller;

  @override
  State<ApplePlansScreen> createState() => _ApplePlansScreenState();
}

class _ApplePlansScreenState extends State<ApplePlansScreen> {
  late final ApplePlansController _controller =
      widget.controller ?? AppleIapService.instance;
  StreamSubscription<String>? _messages;
  List<ApplePlanOffer> _offers = const [];
  bool _loading = true;
  String? _error;
  String? _busyPlanId;
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    final controller = _controller;
    if (controller is AppleIapService) {
      controller.ensureListening();
      _messages = controller.messages.listen(_showMessage);
    }
    _load();
  }

  @override
  void dispose() {
    _messages?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final offers = await _controller.loadOffers();
      if (!mounted) return;
      setState(() {
        _offers = offers;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'The App Store could not load plans. Pull to refresh.';
      });
    }
  }

  void _showMessage(String message) {
    if (!mounted || message.trim().isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    final router = GoRouter.maybeOf(context);
    if (router != null &&
        (message == 'Subscription active.' || message == 'Purchases restored.')) {
      router.go('/dashboard');
    }
  }

  Future<void> _purchase(ApplePlanOffer offer) async {
    setState(() => _busyPlanId = offer.planId);
    try {
      final message = await _controller.purchase(offer);
      if (message != null) _showMessage(message);
    } finally {
      if (mounted) setState(() => _busyPlanId = null);
    }
  }

  Future<void> _restore() async {
    setState(() => _restoring = true);
    try {
      final message = await _controller.restore();
      if (message != null) _showMessage(message);
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final offers = _offers.isEmpty && !_loading
        ? [
            for (final plan in applePlanCatalog)
              ApplePlanOffer(
                planId: plan.id,
                productId: plan.productId,
                name: plan.name,
                includedMinutes: plan.includedMinutes,
                durationLabel: appleSubscriptionDuration,
                localizedPrice: null,
                storeDescription: null,
                canPurchase: false,
              ),
          ]
        : _offers;

    return Scaffold(
      appBar: AppBar(title: const Text('Choose a plan')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
            Text(
              'Subscribe in the app. Plans renew monthly through Apple.',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: EchoDeskColors.muted,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Included minutes are a hard cap. Answering pauses when they are used, and you can upgrade to a higher plan.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: EchoDeskColors.muted,
                  ),
            ),
            if (_loading) ...[
              const SizedBox(height: 32),
              const Center(child: CircularProgressIndicator()),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: TextStyle(color: EchoDeskColors.danger)),
            ],
            const SizedBox(height: 16),
            for (final offer in offers) ...[
              _PlanCard(
                offer: offer,
                busy: _busyPlanId == offer.planId,
                onSubscribe: offer.canPurchase && _busyPlanId == null
                    ? () => _purchase(offer)
                    : null,
              ),
              const SizedBox(height: 16),
            ],
            const SizedBox(height: 8),
            Text(
              'Subscriptions automatically renew until you cancel. Cancel at least 24 hours before the period ends to avoid the next charge.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: EchoDeskColors.muted,
                    height: 1.4,
                  ),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: _restoring ? null : _restore,
              child: Text(_restoring ? 'Restoring…' : 'Restore Purchases'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: openAppleSubscriptionManagement,
              child: const Text('Manage subscription'),
            ),
            const SizedBox(height: 8),
            const LegalLinks(),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.offer,
    required this.busy,
    required this.onSubscribe,
  });

  final ApplePlanOffer offer;
  final bool busy;
  final VoidCallback? onSubscribe;

  @override
  Widget build(BuildContext context) {
    final price = offer.localizedPrice;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(offer.name, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              offer.durationLabel,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: EchoDeskColors.brand,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              price == null || price.isEmpty
                  ? 'Price unavailable from the App Store'
                  : price,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(offer.includedLabel),
            if (offer.storeDescription != null) ...[
              const SizedBox(height: 8),
              Text(
                offer.storeDescription!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: EchoDeskColors.muted,
                    ),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              appleRenewalDisclosure(offer.name, price),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: EchoDeskColors.muted,
                    height: 1.35,
                  ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onSubscribe,
                child: Text(busy ? 'Working…' : 'Subscribe'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
