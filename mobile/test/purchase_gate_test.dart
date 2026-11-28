import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:echodesk_mobile/config/purchases.dart';
import 'package:echodesk_mobile/screens/help/help_screen.dart';
import 'package:echodesk_mobile/screens/landing/landing_screen.dart';
import 'package:echodesk_mobile/screens/landing/welcome_screen.dart';
import 'package:echodesk_mobile/screens/auth/login_screen.dart';
import 'package:echodesk_mobile/screens/auth/signup_screen.dart';
import 'package:echodesk_mobile/screens/settings/settings_screen.dart';
import 'package:echodesk_mobile/widgets/account_inactive_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Purchase copy that must not appear in the iOS store UI.
final _banned = RegExp(
  r'(\$|trial|subscribe|upgrade|\bplans?\b|pricing|checkout|billing|starter|growth|0\.20|0\.25|stripe)',
  caseSensitive: false,
);

void main() {
  testWidgets('store build UI has no purchase calls to action', (tester) async {
    if (kPurchasesEnabled) {
      // Purchases stay on: Stripe on Android/web, Apple IAP on iOS.
      // Re-run with --dart-define=PURCHASES_ENABLED=false to check the kill switch.
      return;
    }

    final screens = <String, Widget>{
      'welcome': const WelcomeScreen(),
      'learn-more': const LandingScreen(),
      'help': const HelpScreen(),
      'login': const LoginScreen(),
      'signup': const SignupScreen(),
    };

    for (final entry in screens.entries) {
      await tester.pumpWidget(MaterialApp(home: entry.value));
      await tester.pump();
      final text = _visibleText(tester);
      expect(
        _banned.hasMatch(text),
        isFalse,
        reason: '${entry.key} showed purchase copy:\n$text',
      );
      expect(text.toLowerCase(), isNot(contains('echodesk.us')));
    }

    expect(find.text('Create account'), findsWidgets);
    expect(find.text('Privacy Policy'), findsOneWidget);
    expect(find.text('Terms'), findsOneWidget);
  });

  testWidgets('captures store-safe welcome, inactive dashboard, and settings',
      (tester) async {
    if (kPurchasesEnabled) return;

    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    try {
      await tester.runAsync(_loadScreenshotFonts);
    } catch (_) {
      // Screenshot fonts are optional. The text assertions do not need them.
    }

    await _capture(
      tester,
      const WelcomeScreen(),
      'ios_welcome.png',
    );

    await _capture(
      tester,
      Scaffold(
        appBar: AppBar(title: const Text('Dashboard')),
        body: const Padding(
          padding: EdgeInsets.all(24),
          child: Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: AccountInactiveNotice(),
            ),
          ),
        ),
      ),
      'ios_dashboard_inactive.png',
    );
    expect(
      find.text("Your account isn't active yet. Contact echodesk2@gmail.com."),
      findsOneWidget,
    );
    expect(_banned.hasMatch(_visibleText(tester)), isFalse);

    await _capture(tester, const SettingsScreen(), 'ios_settings.png');
    await tester.pump();
    final settingsText = _visibleText(tester);
    expect(_banned.hasMatch(settingsText), isFalse, reason: settingsText);
    expect(find.text('Privacy Policy'), findsOneWidget);
    expect(find.text('Billing Portal'), findsNothing);
    expect(find.text('Subscribe / Upgrade'), findsNothing);
  });
}

Future<void> _loadScreenshotFonts() async {
  final base =
      '${Platform.environment['HOME']}/flutter/bin/cache/artifacts/material_fonts';
  Future<ByteData> load(String name) async {
    final bytes = File('$base/$name').readAsBytesSync();
    return ByteData.view(Uint8List.fromList(bytes).buffer);
  }

  final roboto = FontLoader('Roboto')
    ..addFont(load('Roboto-Regular.ttf'))
    ..addFont(load('Roboto-Medium.ttf'))
    ..addFont(load('Roboto-Bold.ttf'));
  await roboto.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(load('MaterialIcons-Regular.otf'));
  await icons.load();
}

String _visibleText(WidgetTester tester) {
  return tester
      .widgetList<Text>(find.byType(Text))
      .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '')
      .join('\n');
}

Future<void> _capture(WidgetTester tester, Widget home, String filename) async {
  await tester.pumpWidget(
    MaterialApp(
      home: RepaintBoundary(child: home),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byType(RepaintBoundary).first,
  );
  final size = boundary.size;
  // ignore: avoid_print
  print('capture $filename size=$size');
  if (!size.width.isFinite ||
      !size.height.isFinite ||
      size.width <= 0 ||
      size.height <= 0 ||
      size.width > 2000 ||
      size.height > 4000) {
    // ignore: avoid_print
    print('skip capture $filename');
    return;
  }
  final png = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  });
  if (png == null) return;
  final dir = Directory('/tmp/echodesk-screens');
  dir.createSync(recursive: true);
  File('${dir.path}/$filename').writeAsBytesSync(png);
  // ignore: avoid_print
  print('wrote $filename ${png.length} bytes');
}
