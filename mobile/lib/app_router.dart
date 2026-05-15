import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'screens/landing/landing_screen.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/signup_screen.dart';
import 'screens/dashboard/dashboard_screen.dart';
import 'screens/onboarding/onboarding_screen.dart';
import 'screens/receptionists/receptionists_screen.dart';
import 'screens/receptionists/receptionist_detail_screen.dart';
import 'screens/receptionists/receptionist_settings_screen.dart';
import 'screens/receptionists/create_receptionist_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'screens/settings/edit_business_screen.dart';
import 'screens/settings/communication_setup_screen.dart';
import 'screens/checkout/checkout_screen.dart';
import 'screens/help/help_screen.dart';
import 'screens/call/active_call_screen.dart';
import 'screens/calls/call_history_screen.dart';
import 'screens/calls/call_detail_screen.dart';
import 'screens/appointments/appointments_screen.dart';
import 'screens/appointments/appointment_detail_screen.dart';
import 'widgets/main_shell.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();
final _dashboardNavigatorKey = GlobalKey<NavigatorState>();
final _receptionistsNavigatorKey = GlobalKey<NavigatorState>();
final _appointmentsNavigatorKey = GlobalKey<NavigatorState>();
final _settingsNavigatorKey = GlobalKey<NavigatorState>();

GoRouter createAppRouter() {
  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/',
    redirect: (context, state) async {
      final session = Supabase.instance.client.auth.currentSession;
      final isLoggedIn = session != null;
      final isLanding = state.matchedLocation == '/' ||
          state.matchedLocation.startsWith('/login') ||
          state.matchedLocation.startsWith('/signup');
      final isAuthRoute = state.matchedLocation.startsWith('/login') ||
          state.matchedLocation.startsWith('/signup');

      if (!isLoggedIn && !isLanding) {
        return '/';
      }
      if (isLoggedIn && isAuthRoute) {
        return '/dashboard';
      }
      if (isLoggedIn && state.matchedLocation == '/') {
        return '/dashboard';
      }
      // Redirect to onboarding if not yet complete.
      if (isLoggedIn) {
        final loc = state.matchedLocation;
        final allowlist = loc == '/onboarding' ||
            loc == '/receptionists/create' ||
            loc.startsWith('/settings') ||
            loc.startsWith('/checkout') ||
            loc == '/help' ||
            loc.startsWith('/call/');
        if (!allowlist) {
          try {
            final user = Supabase.instance.client.auth.currentUser;
            if (user != null) {
              final res = await Supabase.instance.client
                  .from('users')
                  .select('onboarding_completed_at')
                  .eq('id', user.id)
                  .maybeSingle();
              final completedAt = res?['onboarding_completed_at'] as String?;
              final onboardingComplete = (completedAt ?? '').trim().isNotEmpty;
              if (!onboardingComplete) {
                return '/onboarding';
              }
            }
          } catch (_) {
            // On error (e.g. network), don't block navigation
          }
        }
      }
      return null;
    },
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const LandingScreen(),
      ),
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/signup',
        builder: (context, state) => SignupScreen(
          planId: state.uri.queryParameters['plan'],
        ),
      ),
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),
      GoRoute(
        path: '/checkout',
        builder: (context, state) => CheckoutScreen(
          planId: state.uri.queryParameters['plan'],
        ),
      ),
      GoRoute(
        path: '/help',
        builder: (context, state) => const HelpScreen(),
      ),
      GoRoute(
        path: '/call/:callSid',
        builder: (context, state) {
          final callSid = state.pathParameters['callSid'] ?? '';
          final receptionistId =
              state.uri.queryParameters['receptionist_id'] ?? '';
          final caller = state.uri.queryParameters['caller'] ?? '';
          return ActiveCallScreen(
            callSid: callSid,
            receptionistId: receptionistId,
            caller: caller,
          );
        },
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            MainShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            navigatorKey: _dashboardNavigatorKey,
            routes: [
              GoRoute(
                path: '/dashboard',
                builder: (context, state) => const DashboardScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _receptionistsNavigatorKey,
            routes: [
              GoRoute(
                path: '/receptionists',
                builder: (context, state) => const ReceptionistsScreen(),
                routes: [
                  GoRoute(
                    path: 'create',
                    builder: (context, state) =>
                        const CreateReceptionistScreen(),
                  ),
                  GoRoute(
                    path: ':id',
                    builder: (context, state) => ReceptionistDetailScreen(
                      receptionistId: state.pathParameters['id']!,
                    ),
                    routes: [
                      GoRoute(
                        path: 'settings',
                        builder: (context, state) => ReceptionistSettingsScreen(
                          receptionistId: state.pathParameters['id']!,
                        ),
                      ),
                      GoRoute(
                        path: 'calls',
                        builder: (context, state) => CallHistoryScreen(
                          receptionistId: state.pathParameters['id']!,
                          receptionistName: state.uri.queryParameters['name'],
                        ),
                        routes: [
                          GoRoute(
                            path: ':callId',
                            builder: (context, state) => CallDetailScreen(
                              receptionistId: state.pathParameters['id']!,
                              callId: state.pathParameters['callId']!,
                              callData: state.extra as Map<String, dynamic>?,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _appointmentsNavigatorKey,
            routes: [
              GoRoute(
                path: '/appointments',
                builder: (context, state) => AppointmentsScreen(
                  initialStatus: state.uri.queryParameters['status'],
                  receptionistId: state.uri.queryParameters['receptionist_id'],
                  initialTab: state.uri.queryParameters['tab'],
                ),
                routes: [
                  GoRoute(
                    path: 'agenda',
                    redirect: (context, state) {
                      final rid = state.uri.queryParameters['receptionist_id'];
                      final q = <String>['tab=today'];
                      if (rid != null && rid.isNotEmpty) {
                        q.add(
                          'receptionist_id=${Uri.encodeQueryComponent(rid)}',
                        );
                      }
                      return '/appointments?${q.join('&')}';
                    },
                  ),
                  GoRoute(
                    path: ':id',
                    builder: (context, state) => AppointmentDetailScreen(
                      appointmentId: state.pathParameters['id']!,
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _settingsNavigatorKey,
            routes: [
              GoRoute(
                path: '/settings',
                builder: (context, state) => const SettingsScreen(),
                routes: [
                  GoRoute(
                    path: 'business-edit',
                    builder: (context, state) => const EditBusinessScreen(),
                  ),
                  GoRoute(
                    path: 'communication-setup',
                    builder: (context, state) =>
                        const CommunicationSetupScreen(),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );
}
