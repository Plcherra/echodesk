import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echodesk_mobile/screens/auth/login_screen.dart';
import 'package:echodesk_mobile/screens/auth/signup_screen.dart';

void main() {
  group('LoginScreen', () {
    testWidgets('renders login form with expected elements',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: LoginScreen(),
        ),
      );

      expect(find.text('Log in'), findsOneWidget);
      expect(find.text('AI Receptionist'), findsOneWidget);
      expect(find.byType(TextFormField), findsNWidgets(2));
      expect(find.text('Sign In'), findsOneWidget);
      expect(find.text("Don't have an account? Sign up"), findsOneWidget);
      expect(find.text('Continue with Google'), findsNothing);
    });

    testWidgets('shows validation error when form is submitted empty',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: LoginScreen(),
        ),
      );

      await tester.tap(find.text('Sign In'));
      await tester.pump();

      expect(find.text('Required'), findsAtLeastNWidgets(1));
    });
  });

  group('SignupScreen', () {
    testWidgets('renders signup form with expected elements',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SignupScreen(),
        ),
      );

      expect(find.text('Create account'), findsOneWidget);
      expect(find.text('AI Receptionist'), findsOneWidget);
      expect(find.byType(TextFormField), findsNWidgets(2));
      expect(find.text('Sign Up'), findsOneWidget);
      expect(find.text('Already have an account? Log in'), findsOneWidget);
      expect(find.text('Continue with Google'), findsNothing);
    });

    testWidgets('shows validation error when form is submitted empty',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SignupScreen(),
        ),
      );

      await tester.tap(find.text('Sign Up'));
      await tester.pump();

      expect(find.text('Required'), findsAtLeastNWidgets(1));
    });
  });
}
