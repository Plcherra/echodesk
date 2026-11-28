import 'package:echodesk_mobile/config/apple_plans.dart';
import 'package:echodesk_mobile/models/plan.dart';
import 'package:echodesk_mobile/screens/billing/apple_plans_screen.dart';
import 'package:echodesk_mobile/screens/billing/stripe_plans_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('public plans match the shared catalog', () {
    expect(
      Plan.publicPlans.map((plan) => (plan.id, plan.priceCents, plan.includedMinutes)),
      [
        ('starter', 6900, 250),
        ('growth', 14900, 750),
        ('business', 24900, 1500),
      ],
    );
    expect(Plan.rankOf('business') > Plan.rankOf('growth'), isTrue);
    expect(Plan.rankOf('growth') > Plan.rankOf('starter'), isTrue);
  });

  testWidgets('subscribed stripe account shows Current and Upgrade', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: StripePlansScreen(
          billing: PlanBillingSnapshot(
            planId: 'starter',
            source: 'stripe',
            entitled: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Current', skipOffstage: false), findsOneWidget);
    expect(find.text('Upgrade', skipOffstage: false), findsNWidgets(2));
    expect(find.text('\$69/month', skipOffstage: false), findsOneWidget);
    expect(find.text('\$149/month'), findsOneWidget);
    expect(find.text('\$249/month'), findsOneWidget);
    expect(find.text('250 minutes per month'), findsOneWidget);
    expect(find.text('750 minutes per month'), findsOneWidget);
    expect(find.text('1500 minutes per month'), findsOneWidget);
    expect(find.text('\$0.25 / extra minute'), findsOneWidget);
    expect(find.text('\$0.18 / extra minute'), findsOneWidget);
    expect(find.textContaining('14 days free'), findsNothing);
  });

  testWidgets('new stripe account offers the 14-day trial', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: StripePlansScreen(billing: PlanBillingSnapshot())),
    );
    await tester.pumpAndSettle();
    expect(find.text('Subscribe', skipOffstage: false), findsNWidgets(3));
    expect(find.text('14 days free, then \$69/month'), findsOneWidget);
    expect(find.text('14 days free, then \$149/month'), findsOneWidget);
    expect(find.text('14 days free, then \$249/month'), findsOneWidget);
  });

  testWidgets('ios stripe subscriber sees Current and no purchase buttons',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ApplePlansScreen(
          billing: PlanBillingSnapshot(
            planId: 'growth',
            source: 'stripe',
            entitled: true,
          ),
          controller: _ReadyStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Current'), findsOneWidget);
    expect(find.text('Upgrade'), findsNothing);
    expect(find.text('Subscribe'), findsNothing);
    expect(find.textContaining('website'), findsNothing);
    expect(find.textContaining('14 days free'), findsNothing);
  });

  testWidgets('ios apple subscriber can upgrade to a higher plan', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ApplePlansScreen(
          billing: PlanBillingSnapshot(
            planId: 'starter',
            source: 'apple',
            entitled: true,
          ),
          controller: _ReadyStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Current'), findsOneWidget);
    expect(find.text('Upgrade'), findsNWidgets(2));
    expect(find.text('Subscribe'), findsNothing);
  });
}

class _ReadyStore implements ApplePlansController {
  const _ReadyStore();

  @override
  Future<List<ApplePlanOffer>> loadOffers() async {
    return const [
      ApplePlanOffer(
        planId: 'starter',
        productId: 'com.echodesk.sub.starter.monthly',
        name: 'Starter',
        includedMinutes: 250,
        durationLabel: '1 month',
        localizedPrice: 'US\$69.99',
        storeDescription: null,
        canPurchase: true,
      ),
      ApplePlanOffer(
        planId: 'growth',
        productId: 'com.echodesk.sub.growth.monthly',
        name: 'Growth',
        includedMinutes: 750,
        durationLabel: '1 month',
        localizedPrice: 'US\$149.99',
        storeDescription: null,
        canPurchase: true,
      ),
      ApplePlanOffer(
        planId: 'business',
        productId: 'com.echodesk.sub.business.monthly',
        name: 'Business',
        includedMinutes: 1500,
        durationLabel: '1 month',
        localizedPrice: 'US\$249.99',
        storeDescription: null,
        canPurchase: true,
      ),
    ];
  }

  @override
  Future<String?> purchase(ApplePlanOffer offer) async => null;

  @override
  Future<String?> restore() async => null;
}
