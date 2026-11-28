import 'dart:async';
import 'dart:convert';

import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/apple_plans.dart';
import 'api_client.dart';

final RegExp _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// StoreKit 2 purchases through the official `in_app_purchase` plugin.
///
/// `applicationUserName` is the EchoDesk user id. On StoreKit 2 the plugin
/// sends that UUID as the transaction `appAccountToken`.
class AppleIapService implements ApplePlansController {
  AppleIapService({InAppPurchase? iap}) : _iap = iap ?? InAppPurchase.instance;

  static final AppleIapService instance = AppleIapService();

  final InAppPurchase _iap;
  final StreamController<String> _messages = StreamController<String>.broadcast();
  final Map<String, ProductDetails> _products = {};
  final Set<String> _finished = {};
  StreamSubscription<List<PurchaseDetails>>? _subscription;

  Stream<String> get messages => _messages.stream;

  void ensureListening() {
    if (_subscription != null) return;
    _subscription = _iap.purchaseStream.listen(
      _onPurchases,
      onError: (Object _) {
        _messages.add('The App Store could not complete the purchase.');
      },
    );
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }

  @override
  Future<List<ApplePlanOffer>> loadOffers() async {
    ensureListening();
    final ids = applePlanCatalog.map((plan) => plan.productId).toSet();
    if (!await _iap.isAvailable()) {
      return _offersFromStore(const []);
    }
    final response = await _iap.queryProductDetails(ids);
    return _offersFromStore(response.productDetails);
  }

  List<ApplePlanOffer> _offersFromStore(List<ProductDetails> products) {
    _products
      ..clear()
      ..addEntries(products.map((product) => MapEntry(product.id, product)));
    return [
      for (final plan in applePlanCatalog)
        ApplePlanOffer(
          planId: plan.id,
          productId: plan.productId,
          name: _storeName(plan),
          includedMinutes: plan.includedMinutes,
          durationLabel: appleSubscriptionDuration,
          localizedPrice: _products[plan.productId]?.price,
          storeDescription: _blankToNull(_products[plan.productId]?.description),
          canPurchase: _products.containsKey(plan.productId),
        ),
    ];
  }

  String _storeName(ApplePlanDefinition plan) {
    final title = _products[plan.productId]?.title.trim() ?? '';
    if (title.isEmpty) return plan.name;
    final suffix = title.lastIndexOf(' (');
    if (suffix > 0) return title.substring(0, suffix);
    return title;
  }

  @override
  Future<String?> purchase(ApplePlanOffer offer) async {
    ensureListening();
    final product = _products[offer.productId];
    if (product == null) {
      return 'That plan is not available in the App Store yet.';
    }
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) {
      return 'Sign in before subscribing.';
    }
    if (!_uuid.hasMatch(userId)) {
      return 'This account cannot be linked to an App Store purchase.';
    }
    final started = await _iap.buyNonConsumable(
      purchaseParam: PurchaseParam(
        productDetails: product,
        applicationUserName: userId,
      ),
    );
    if (!started) return 'The App Store could not start the purchase.';
    return null;
  }

  @override
  Future<String?> restore() async {
    ensureListening();
    final userId = Supabase.instance.client.auth.currentUser?.id;
    await _iap.restorePurchases(applicationUserName: userId);
    return null;
  }

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      if (purchase.status == PurchaseStatus.pending) continue;
      if (purchase.status == PurchaseStatus.canceled) {
        _messages.add('Purchase canceled.');
        continue;
      }
      if (purchase.status == PurchaseStatus.error) {
        _messages.add(purchase.error?.message ?? 'Purchase failed.');
        if (purchase.pendingCompletePurchase) {
          await _iap.completePurchase(purchase);
        }
        continue;
      }
      if (purchase.status != PurchaseStatus.purchased &&
          purchase.status != PurchaseStatus.restored) {
        continue;
      }
      await _verify(purchase);
    }
  }

  Future<void> _verify(PurchaseDetails purchase) async {
    final signed = purchase.verificationData.serverVerificationData.trim();
    final key = purchase.purchaseID ?? signed;
    if (key.isNotEmpty && _finished.contains(key)) {
      if (purchase.pendingCompletePurchase) {
        await _iap.completePurchase(purchase);
      }
      return;
    }
    if (signed.isEmpty) {
      _messages.add('The App Store did not return a receipt to verify.');
      return;
    }
    try {
      final response = await ApiClient.post(
        '/api/mobile/apple/verify',
        body: {'signed_transaction': signed},
      );
      final definitive = response.statusCode == 400 ||
          response.statusCode == 403 ||
          response.statusCode == 409;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (key.isNotEmpty) _finished.add(key);
        _messages.add(
          purchase.status == PurchaseStatus.restored
              ? 'Purchases restored.'
              : 'Subscription active.',
        );
        if (purchase.pendingCompletePurchase) {
          await _iap.completePurchase(purchase);
        }
        return;
      }
      if (definitive && purchase.pendingCompletePurchase) {
        await _iap.completePurchase(purchase);
      }
      _messages.add(_errorText(response.body, response.statusCode));
    } catch (_) {
      _messages.add('Could not verify the purchase. Try Restore Purchases.');
    }
  }

  String _errorText(String body, int status) {
    try {
      final data = jsonDecode(body);
      if (data is Map && (data['error'] as String?)?.trim().isNotEmpty == true) {
        return data['error'] as String;
      }
    } catch (_) {}
    if (status == 401) return 'Sign in again, then retry the purchase.';
    return 'Could not activate the subscription.';
  }
}

String? _blankToNull(String? value) {
  final text = value?.trim() ?? '';
  return text.isEmpty ? null : text;
}
