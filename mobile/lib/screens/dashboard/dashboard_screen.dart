import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/receptionist.dart';
import '../../models/user_profile.dart';
import '../../services/appointment_service.dart';
import '../../services/dashboard_service.dart';
import '../../utils/appointment_formatters.dart';
import '../../utils/call_formatters.dart';
import '../../widgets/confirm_sign_out.dart';
import '../../widgets/constrained_scaffold_body.dart';
import '../../widgets/loading_skeleton.dart';
import '../../widgets/main_shell.dart';
import '../../widgets/state_views.dart';
import '../../widgets/status_chip.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final DashboardService _dashboardService = const DashboardService();
  Map<String, dynamic>? _profile;
  List<Receptionist> _receptionists = [];
  int _totalReceptionists = 0;
  int _activeReceptionists = 0;
  int _totalUsageMinutes = 0;
  int? _includedMinutes;
  int _overageMinutes = 0;
  int _totalCalls = 0;
  double _totalCallMinutes = 0.0;
  List<Map<String, dynamic>> _recentCalls = [];
  List<Map<String, dynamic>> _upcomingAppointments = [];
  int _needsReviewCount = 0;
  Map<String, String> _receptionistNames = {};
  int? _remainingMinutes;
  bool _loading = true;
  String? _error;
  /// Non-blocking: dashboard shell loaded, but appointments request failed.
  String? _appointmentsError;
  int? _lastShellTabIndex;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tabIndex = MainShellTabIndex.maybeOf(context);
    if (tabIndex == null) return;
    // Refresh when the user switches back to the Dashboard tab.
    if (_lastShellTabIndex != null &&
        tabIndex == 0 &&
        _lastShellTabIndex != 0) {
      _load(quiet: true);
    }
    _lastShellTabIndex = tabIndex;
  }

  Future<void> _pushAndRefresh(String location) async {
    await context.push(location);
    if (mounted) await _load(quiet: true);
  }

  Future<void> _load({bool quiet = false}) async {
    if (!quiet) {
      setState(() {
        _loading = true;
        _error = null;
        _appointmentsError = null;
      });
    } else if (mounted) {
      setState(() => _appointmentsError = null);
    }
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) throw Exception('Not authenticated');
      final data = await _dashboardService.loadForUser(user.id);

      List<Map<String, dynamic>> upcoming = [];
      int needsReview = 0;
      Map<String, String> recNames = {};
      String? appointmentsError;
      try {
        final aptData = await loadAppointments(limit: 30);
        final allApts =
            List<Map<String, dynamic>>.from(aptData['appointments'] ?? []);
        recNames = Map<String, String>.from(aptData['receptionists'] ?? {});
        final now = DateTime.now().toUtc();
        for (final a in allApts) {
          final status = a['status'] as String? ?? '';
          if (status == 'needs_review') needsReview++;
          final start = a['start_time'] != null
              ? DateTime.tryParse(a['start_time'] as String)
              : null;
          // Upcoming = future bookings. Cancelled ones stay visible (shown with a
          // "Cancelled" label); Completed lives in its own tab. Matches the
          // Appointments > Upcoming filter.
          if (start != null && start.isAfter(now) && status != 'completed') {
            upcoming.add(a);
          }
        }
        upcoming.sort((a, b) {
          final sa = DateTime.tryParse(a['start_time'] as String? ?? '');
          final sb = DateTime.tryParse(b['start_time'] as String? ?? '');
          if (sa == null || sb == null) return 0;
          return sa.compareTo(sb);
        });
      } catch (e) {
        appointmentsError = e.toString();
      }

      if (!mounted) return;
      setState(() {
        _profile = data.profile;
        _receptionists = data.receptionists.take(6).toList();
        _totalReceptionists = data.totalReceptionists;
        _activeReceptionists = data.activeReceptionists;
        _totalUsageMinutes = data.totalUsageMinutes;
        _includedMinutes = data.includedMinutes;
        _overageMinutes = data.overageMinutes;
        _remainingMinutes = data.remainingMinutes;
        _totalCalls = data.totalCalls;
        _totalCallMinutes = data.totalCallMinutes;
        _recentCalls = data.recentCalls;
        _upcomingAppointments = upcoming.take(5).toList();
        _needsReviewCount = needsReview;
        _receptionistNames = recNames;
        _appointmentsError = appointmentsError;
        _loading = false;
      });
      if (!_loading && _error == null) {
        _maybeShowWelcomeOverlay();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  static const _kWelcomeSeenKey = 'dashboard_welcome_seen';

  Future<void> _maybeShowWelcomeOverlay() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_kWelcomeSeenKey) == true) return;
      if (!mounted) return;
      _showWelcomeDialog(prefs);
    } catch (_) {}
  }

  void _showWelcomeDialog(SharedPreferences prefs) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Welcome to Echodesk'),
        content: const Text(
          'Create your first receptionist to answer on your business line. '
          'Your AI will answer calls and book appointments into your calendar.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              prefs.setBool(_kWelcomeSeenKey, true);
              Navigator.of(ctx).pop();
            },
            child: const Text('Got it'),
          ),
          FilledButton(
            onPressed: () {
              prefs.setBool(_kWelcomeSeenKey, true);
              Navigator.of(ctx).pop();
              if (mounted) _pushAndRefresh('/receptionists/create');
            },
            child: const Text('Create receptionist'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Dashboard')),
        body: constrainedScaffoldBody(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            children: [
              ...List.generate(3, (_) => const SkeletonCard()),
              const SizedBox(height: 24),
              LoadingSkeleton(width: 100, height: 16),
              const SizedBox(height: 12),
              ...List.generate(2, (_) => const SkeletonCard()),
              const SizedBox(height: 24),
              LoadingSkeleton(width: 140, height: 16),
              const SizedBox(height: 12),
              ...List.generate(
                  3, (_) => const SkeletonCard(showTrailing: false)),
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Dashboard')),
        body: Center(
          child: ErrorStateView(
            message: _error,
            onRetry: _load,
          ),
        ),
      );
    }

    final profile = UserProfile.fromJson(_profile ?? {});
    final isActive = profile.isActive;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: () => _pushAndRefresh('/help'),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => _pushAndRefresh('/settings'),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => confirmSignOut(context),
          ),
        ],
      ),
      body: constrainedScaffoldBody(
        child: RefreshIndicator(
          onRefresh: () => _load(quiet: true),
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            children: [
              if (!profile.onboardingComplete && isActive)
                _buildOnboardingAlert(context),
              if (isActive) _buildAppointmentsCard(context),
              if (!isActive) ...[
                _buildUpgradeCard(context),
              ] else ...[
                _buildStatsGrid(profile),
                const SizedBox(height: 24),
                _buildRecentCallsSection(context),
                const SizedBox(height: 24),
                _buildUpcomingAppointmentsSection(context),
                const SizedBox(height: 24),
                _buildRecentReceptionistsSection(context),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAppointmentsCard(BuildContext context) {
    final hasNeedsReview = _needsReviewCount > 0;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: ListTile(
        leading: Icon(Icons.event_available,
            color: Theme.of(context).colorScheme.primary),
        title: Row(
          children: [
            const Text('Appointments'),
            if (hasNeedsReview) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.orange.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$_needsReviewCount need review',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.orange.shade800),
                ),
              ),
            ],
          ],
        ),
        subtitle: const Text(
          'Review, confirm, or edit appointments booked by your AI.',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _pushAndRefresh(hasNeedsReview
            ? '/appointments?status=needs_review'
            : '/appointments'),
      ),
    );
  }

  Widget _buildOnboardingAlert(BuildContext context) {
    return Card(
      color: Colors.blue.shade50,
      child: ListTile(
        title: const Text('Finish setup'),
        subtitle: const Text(
          'Connect calendar and create your first receptionist to set up your business line.',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _pushAndRefresh('/onboarding'),
      ),
    );
  }

  Widget _buildUpgradeCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Subscribe to continue',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Connect calendar to start. Upgrade for your AI assistant.',
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => _pushAndRefresh('/checkout'),
              child: const Text('Subscribe'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsGrid(UserProfile profile) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Overview',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Spacer(),
            if (profile.isActive)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.green.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Active',
                  style: TextStyle(
                    color: Colors.green.shade800,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _StatCard(
              label: 'Total Calls',
              value: '$_totalCalls',
            ),
            _StatCard(
              label: 'Total Minutes',
              value: _totalCallMinutes.toStringAsFixed(1),
            ),
            _StatCard(
              label: 'Total Receptionists',
              value: '$_totalReceptionists',
            ),
            _StatCard(
              label: 'Active Receptionists',
              value: '$_activeReceptionists',
            ),
            _StatCard(
              label: 'Calendar',
              value: profile.hasCalendar ? 'Connected' : 'Not connected',
            ),
            _StatCard(
              label: 'Default phone',
              value: profile.hasPhone ? (profile.phone ?? '') : 'Not set',
            ),
            _StatCard(
              label: 'Minutes this period',
              value: _includedMinutes != null
                  ? '$_totalUsageMinutes / $_includedMinutes'
                  : '$_totalUsageMinutes',
              remainingSubtext:
                  _remainingMinutes != null && _remainingMinutes! > 0
                      ? '$_remainingMinutes min remaining'
                      : null,
              overageSubtext:
                  _overageMinutes > 0 ? '$_overageMinutes overage' : null,
              overageWarning: _includedMinutes != null &&
                  _totalUsageMinutes >= _includedMinutes! &&
                  _totalUsageMinutes > 0,
              lowMinutesWarning: _remainingMinutes != null &&
                  _remainingMinutes! > 0 &&
                  _remainingMinutes! <= 30,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRecentCallsSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Recent Calls', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        if (_recentCalls.isEmpty)
          const EmptyStateView(
            icon: Icons.phone_missed_outlined,
            title: 'No calls yet',
            subtitle:
                "When customers call your AI receptionist, they'll appear here.",
            asCard: true,
          )
        else
          ..._recentCalls.take(5).map((call) {
            final start = call['started_at'] != null
                ? DateTime.tryParse(call['started_at'] as String)
                : null;
            final dur = call['duration_seconds'] as int?;
            final fromNum = call['from_number'] as String? ??
                call['to_number'] as String? ??
                '';
            final recId = call['receptionist_id'] as String?;
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                title: Text(
                  formatPhoneForDisplay(fromNum, mask: true),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                subtitle: Text(
                  '${formatCallTimestamp(start)} · ${formatCallDuration(dur)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: recId != null
                    ? () async {
                        await context.push(
                          '/receptionists/$recId/calls/${call['id']}',
                          extra: call,
                        );
                        if (mounted) await _load(quiet: true);
                      }
                    : null,
              ),
            );
          }),
      ],
    );
  }

  Widget _buildUpcomingAppointmentsSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Upcoming Appointments',
                style: Theme.of(context).textTheme.titleMedium),
            if (_upcomingAppointments.isNotEmpty)
              TextButton(
                onPressed: () => _pushAndRefresh('/appointments'),
                child: const Text('View all'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (_appointmentsError != null)
          Card(
            color: Colors.red.shade50,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: Colors.red.shade700),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Could not load appointments',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Colors.red.shade900,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _appointmentsError!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.red.shade800,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => _load(quiet: true),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          )
        else if (_upcomingAppointments.isEmpty)
          const EmptyStateView(
            icon: Icons.event_available,
            title: 'No upcoming appointments',
            subtitle: 'Appointments booked by your AI will appear here.',
            asCard: true,
          )
        else
          ..._upcomingAppointments.map((apt) {
            final start = apt['start_time'] != null
                ? DateTime.tryParse(apt['start_time'] as String)
                : null;
            final serviceName = (apt['service_name'] as String?)?.trim();
            final displayService = serviceName != null && serviceName.isNotEmpty
                ? serviceName
                : 'Generic appointment';
            final recName = _receptionistNames[apt['receptionist_id']] ?? '—';
            final status = (apt['status'] as String?) ?? 'needs_review';
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        formatAppointmentDateTime(start),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    StatusChip(status: status),
                  ],
                ),
                subtitle: Text(
                  '$displayService · $recName',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: () => _pushAndRefresh('/appointments/${apt['id']}'),
              ),
            );
          }),
      ],
    );
  }

  Widget _buildRecentReceptionistsSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Recent Receptionists',
                style: Theme.of(context).textTheme.titleMedium),
            TextButton(
              onPressed: () => _pushAndRefresh('/receptionists'),
              child: const Text('View all'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_receptionists.isEmpty)
          EmptyStateView(
            icon: Icons.support_agent,
            title: 'No receptionists yet',
            subtitle:
                'Create your first AI receptionist to answer on your business line.',
            asCard: true,
            action: TextButton(
              onPressed: () => _pushAndRefresh('/receptionists/create'),
              child: const Text('Add one'),
            ),
          )
        else
          ..._receptionists.map((r) => Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  title: Text(r.name,
                      style: Theme.of(context).textTheme.titleSmall),
                  subtitle: Text(
                    formatPhoneForDisplay(r.displayPhone),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 20),
                  onTap: () => _pushAndRefresh('/receptionists/${r.id}'),
                ),
              )),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final String? remainingSubtext;
  final String? overageSubtext;
  final bool overageWarning;
  final bool lowMinutesWarning;

  const _StatCard({
    required this.label,
    required this.value,
    this.remainingSubtext,
    this.overageSubtext,
    this.overageWarning = false,
    this.lowMinutesWarning = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 160,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 4),
              Text(
                value,
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (overageSubtext != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    overageSubtext!,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.amber.shade700,
                    ),
                  ),
                )
              else if (overageWarning)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Over cap; overage may be billed at \$0.25/min.',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.amber.shade700,
                    ),
                  ),
                )
              else if (remainingSubtext != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    remainingSubtext!,
                    style: TextStyle(
                      fontSize: 11,
                      color: lowMinutesWarning
                          ? Colors.orange.shade700
                          : Colors.green.shade700,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
