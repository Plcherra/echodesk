import 'package:echodesk_mobile/config/apple_plans.dart';
import 'package:echodesk_mobile/screens/billing/apple_plans_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePlans implements ApplePlansController {
  _FakePlans(this.offers);

  final List<ApplePlanOffer> offers;
  String? purchased;
  bool restored = false;

  @override
  Future<List<ApplePlanOffer>> loadOffers() async => offers;

  @override
  Future<String?> purchase(ApplePlanOffer offer) async {
    purchased = offer.planId;
    return null;
  }

  @override
  Future<String?> restore() async {
    restored = true;
    return 'Purchases restored.';
  }
}

ApplePlanOffer _offer({
  required String id,
  required String name,
  required int minutes,
  required String price,
}) {
  return ApplePlanOffer(
    planId: id,
    productId: 'com.echodesk.sub.$id.monthly',
    name: name,
    includedMinutes: minutes,
    durationLabel: appleSubscriptionDuration,
    localizedPrice: price,
    storeDescription: '$name from the App Store',
    canPurchase: true,
  );
}

void main() {
  test('catalog matches the Apple minute entitlements and hides dev_test', () {
    expect(applePlanCatalog.map((plan) => plan.id), ['starter', 'growth', 'business']);
    expect(applePlanCatalog.map((plan) => plan.includedMinutes), [250, 750, 1500]);
    expect(applePlanCatalog.map((plan) => plan.productId), [
      'com.echodesk.sub.starter.monthly',
      'com.echodesk.sub.growth.monthly',
      'com.echodesk.sub.business.monthly',
    ]);
    expect(appleRenewalDisclosure('Starter', null), contains('App Store'));
    expect(appleRenewalDisclosure('Starter', null), isNot(contains('\$')));
  });

  testWidgets('paywall shows StoreKit prices and the required disclosures',
      (tester) async {
    final plans = _FakePlans([
      _offer(id: 'starter', name: 'Starter', minutes: 250, price: 'US\$69.99'),
      _offer(id: 'growth', name: 'Growth', minutes: 750, price: '€4.00'),
      _offer(id: 'business', name: 'Business', minutes: 1500, price: '¥100'),
    ]);
    await tester.pumpWidget(
      MaterialApp(home: ApplePlansScreen(controller: plans)),
    );
    await tester.pumpAndSettle();

    Finder text(String value) => find.text(value, skipOffstage: false);
    expect(text('Starter'), findsWidgets);
    expect(text('Growth'), findsWidgets);
    expect(text('Business'), findsWidgets);
    expect(text('1 month'), findsNWidgets(3));
    expect(text('US\$69.99'), findsWidgets);
    expect(text('€4.00'), findsOneWidget);
    expect(text('¥100'), findsOneWidget);
    expect(text('250 minutes per month'), findsOneWidget);
    expect(text('750 minutes per month'), findsOneWidget);
    expect(text('1,500 minutes per month'), findsOneWidget);
    expect(text('Restore Purchases'), findsOneWidget);
    expect(text('Manage subscription'), findsOneWidget);
    expect(text('Privacy Policy'), findsOneWidget);
    expect(text('Terms'), findsOneWidget);
    expect(text('14 days free, then US\$69.99/month'), findsWidgets);
    expect(find.textContaining('renews automatically', skipOffstage: false), findsWidgets);
    expect(find.textContaining('Apple ID', skipOffstage: false), findsWidgets);

    final visible = tester
        .widgetList<Text>(find.byType(Text, skipOffstage: false))
        .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '')
        .join('\n')
        .toLowerCase();
    expect(visible, isNot(contains('stripe')));
    expect(visible, isNot(contains('website')));
    expect(visible, isNot(contains('echodesk.us')));
    expect(visible, isNot(contains('\$149.99')));
    expect(visible, isNot(contains('\$249.99')));
    expect(visible, isNot(contains('dev_test')));

    await tester.ensureVisible(find.text('Subscribe').first);
    await tester.tap(find.text('Subscribe').first);
    await tester.pump();
    expect(plans.purchased, 'starter');

    await tester.ensureVisible(find.text('Restore Purchases'));
    await tester.tap(find.text('Restore Purchases'));
    await tester.pump();
    await tester.pump();
    expect(plans.restored, isTrue);
  });
}
