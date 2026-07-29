import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/appointment_service.dart';
import '../../utils/appointment_formatters.dart';
import '../../widgets/appointment_day_schedule.dart';
import '../../widgets/constrained_scaffold_body.dart';
import '../../widgets/main_shell.dart';
import '../../widgets/state_views.dart';
import '../../widgets/status_chip.dart';

class AppointmentsScreen extends StatefulWidget {
  final String? initialStatus;
  final String? receptionistId;
  /// Query param: today | needs_review | upcoming | completed
  final String? initialTab;

  const AppointmentsScreen({
    super.key,
    this.initialStatus,
    this.receptionistId,
    this.initialTab,
  });

  @override
  State<AppointmentsScreen> createState() => _AppointmentsScreenState();
}

class _AppointmentsScreenState extends State<AppointmentsScreen>
    with SingleTickerProviderStateMixin {
  static const _tabs = ['Today', 'Needs review', 'Upcoming', 'Completed'];

  late TabController _tabController;
  List<Map<String, dynamic>> _appointments = [];
  Map<String, String> _receptionists = {};
  List<Map<String, dynamic>> _todayItems = [];
  String _localDateLabel = '';
  bool _loading = true;
  String? _error;
  int _needsReviewCount = 0;

  String? _effectiveReceptionistIdForToday;
  _TodayContext _todayContext = _TodayContext.resolving;
  /// When multiple assistants exist, Today needs an explicit pick.
  List<({String id, String name})> _todayAssistants = [];
  int? _lastShellTabIndex;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 4,
      vsync: this,
      initialIndex: _initialTabIndex(),
    );
    _tabController.addListener(_onTabChanged);
    _bootstrap();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tabIndex = MainShellTabIndex.maybeOf(context);
    if (tabIndex == null) return;
    // Appointments is shell index 2 — refresh list + badge when tab regains focus.
    if (_lastShellTabIndex != null &&
        tabIndex == 2 &&
        _lastShellTabIndex != 2) {
      _refreshAll();
    }
    _lastShellTabIndex = tabIndex;
  }

  int _initialTabIndex() {
    final t = widget.initialTab?.trim().toLowerCase();
    if (t == 'needs_review') return 1;
    if (t == 'upcoming') return 2;
    if (t == 'completed') return 3;
    if (t == 'today') return 0;
    if (widget.initialStatus == 'needs_review') return 1;
    return 0;
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    setState(() {});
    _load();
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _resolveTodayReceptionist();
    if (!mounted) return;
    await _refreshAll();
  }

  Future<void> _refreshAll() async {
    await _load();
    await _refreshNeedsReviewCount();
  }

  /// Keep the "Needs review" tab badge accurate regardless of the active tab so
  /// pending appointments are impossible to miss.
  Future<void> _refreshNeedsReviewCount() async {
    try {
      final data = await loadAppointments(
        status: 'needs_review',
        receptionistId: widget.receptionistId,
        limit: 100,
      );
      final list = List<Map<String, dynamic>>.from(data['appointments'] ?? []);
      if (mounted) setState(() => _needsReviewCount = list.length);
    } catch (_) {
      // Non-fatal: the badge just won't update.
    }
  }

  Future<void> _resolveTodayReceptionist() async {
    final fromRoute = widget.receptionistId?.trim();
    if (fromRoute != null && fromRoute.isNotEmpty) {
      _effectiveReceptionistIdForToday = fromRoute;
      _todayContext = _TodayContext.ready;
      _todayAssistants = [];
      return;
    }
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      _todayContext = _TodayContext.noUser;
      _todayAssistants = [];
      return;
    }
    try {
      final res = await Supabase.instance.client
          .from('receptionists')
          .select('id, name')
          .eq('user_id', user.id)
          .order('created_at', ascending: false);
      final rows = List<Map<String, dynamic>>.from(res as List? ?? []);
      if (rows.isEmpty) {
        _todayContext = _TodayContext.noAssistant;
        _todayAssistants = [];
        return;
      }
      if (rows.length > 1) {
        _todayAssistants = [
          for (final row in rows)
            (
              id: row['id'] as String,
              name: ((row['name'] as String?)?.trim().isNotEmpty ?? false)
                  ? (row['name'] as String).trim()
                  : 'Assistant',
            ),
        ];
        _todayContext = _TodayContext.multiAssistant;
        return;
      }
      _effectiveReceptionistIdForToday = rows.first['id'] as String?;
      _todayAssistants = [];
      _todayContext = _TodayContext.ready;
    } catch (_) {
      _todayContext = _TodayContext.noAssistant;
      _todayAssistants = [];
    }
  }

  Future<void> _selectTodayAssistant(String receptionistId) async {
    setState(() {
      _effectiveReceptionistIdForToday = receptionistId;
      _todayContext = _TodayContext.ready;
    });
    await _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final idx = _tabController.index;
      if (idx == 0) {
        await _loadToday();
      } else if (idx == 1) {
        await _loadList(status: 'needs_review');
      } else if (idx == 2) {
        await _loadUpcoming();
      } else {
        await _loadList(status: 'completed');
      }
      if (mounted) {
        setState(() => _loading = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadToday() async {
    final now = DateTime.now();
    final date =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    _localDateLabel = date;

    if (_todayContext != _TodayContext.ready ||
        _effectiveReceptionistIdForToday == null ||
        _effectiveReceptionistIdForToday!.isEmpty) {
      _todayItems = [];
      return;
    }

    final offset = now.timeZoneOffset.inMinutes;
    final data = await loadAgendaToday(
      receptionistId: _effectiveReceptionistIdForToday!,
      date: date,
      offsetMinutes: offset,
    );
    _todayItems = List<Map<String, dynamic>>.from(data['appointments'] ?? []);
  }

  Future<void> _loadList({required String status}) async {
    final data = await loadAppointments(
      status: status,
      receptionistId: widget.receptionistId,
      limit: 100,
    );
    _appointments = List<Map<String, dynamic>>.from(data['appointments'] ?? []);
    _receptionists = Map<String, String>.from(data['receptionists'] ?? {});
    if (status == 'needs_review') {
      _needsReviewCount = _appointments.length;
    }
  }

  Future<void> _loadUpcoming() async {
    final data = await loadAppointments(
      receptionistId: widget.receptionistId,
      limit: 100,
    );
    final raw = List<Map<String, dynamic>>.from(data['appointments'] ?? []);
    _receptionists = Map<String, String>.from(data['receptionists'] ?? {});
    _appointments = _filterUpcoming(raw);
  }

  List<Map<String, dynamic>> _filterUpcoming(List<Map<String, dynamic>> list) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    bool isStrictlyAfterToday(DateTime? utc) {
      if (utc == null) return false;
      final l = utc.toLocal();
      final d = DateTime(l.year, l.month, l.day);
      return d.isAfter(today);
    }

    final out = <Map<String, dynamic>>[];
    for (final a in list) {
      final st = DateTime.tryParse(a['start_time'] as String? ?? '');
      final status = a['status'] as String? ?? '';
      if (!isStrictlyAfterToday(st)) continue;
      // Show cancelled here too (with its "Cancelled" label) so a rejected
      // future booking is still visible. Completed lives in its own tab.
      if (status == 'completed') continue;
      out.add(a);
    }
    out.sort((a, b) {
      final sa = DateTime.tryParse(a['start_time'] as String? ?? '');
      final sb = DateTime.tryParse(b['start_time'] as String? ?? '');
      if (sa == null || sb == null) return 0;
      return sa.compareTo(sb);
    });
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Appointments'),
            if (_tabController.index == 0 && _localDateLabel.isNotEmpty)
              Text(
                _localDateLabel,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.normal,
                    ),
              ),
          ],
        ),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            for (int i = 0; i < _tabs.length; i++)
              Tab(child: _buildTabLabel(_tabs[i], i == 1 ? _needsReviewCount : 0)),
          ],
        ),
      ),
      body: constrainedScaffoldBody(
        child: TabBarView(
          controller: _tabController,
          children: [
            _wrapTabContent(0, _buildTodayBody()),
            _wrapTabContent(
              1,
              _buildListBody(emptyMessage: 'No appointments need review right now.'),
            ),
            _wrapTabContent(
              2,
              _buildListBody(
                emptyMessage: 'No upcoming appointments beyond today.',
              ),
            ),
            _wrapTabContent(
              3,
              _buildListBody(emptyMessage: 'No completed appointments yet.'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabLabel(String text, int count) {
    if (count <= 0) return Text(text);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(text),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: Colors.orange.shade600,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '$count',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }

  Widget _wrapTabContent(int tabIndex, Widget child) {
    if (_loading && _tabController.index == tabIndex) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _tabController.index == tabIndex) {
      return _buildError();
    }
    return child;
  }

  Widget _buildTodayBody() {
    if (_todayContext == _TodayContext.multiAssistant &&
        (widget.receptionistId == null || widget.receptionistId!.isEmpty)) {
      return _buildMultiAssistantPicker();
    }
    if (_todayContext == _TodayContext.noAssistant) {
      return _buildTodayGateMessage(
        icon: Icons.support_agent_outlined,
        title: 'No assistant yet',
        subtitle:
            'Add an assistant first. Then you’ll see today’s schedule here.',
        action: FilledButton(
          onPressed: () => context.push('/receptionists'),
          child: const Text('Add assistant'),
        ),
      );
    }
    if (_todayContext == _TodayContext.noUser) {
      return _buildTodayGateMessage(
        icon: Icons.login,
        title: 'Sign in required',
        subtitle: 'Sign in to view your schedule.',
      );
    }

    if (_todayItems.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refreshAll,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.45,
              child: _buildEmptyToday(),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshAll,
      child: AppointmentDayScheduleListView(appointments: _todayItems),
    );
  }

  Widget _buildMultiAssistantPicker() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      children: [
        Icon(
          Icons.groups_outlined,
          size: 48,
          color: Colors.grey.shade400,
        ),
        const SizedBox(height: 12),
        Text(
          'Choose an assistant',
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'You have more than one assistant. Pick whose schedule to show for today.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        for (final a in _todayAssistants)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: const Icon(Icons.support_agent_outlined),
              title: Text(a.name),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _selectTodayAssistant(a.id),
            ),
          ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => context.push('/receptionists'),
          child: const Text('Manage assistants'),
        ),
      ],
    );
  }

  Widget _buildTodayGateMessage({
    required IconData icon,
    required String title,
    required String subtitle,
    Widget? action,
  }) {
    return CustomScrollView(
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 48, color: Colors.grey.shade400),
                const SizedBox(height: 12),
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                  textAlign: TextAlign.center,
                ),
                if (action != null) ...[
                  const SizedBox(height: 16),
                  action,
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyToday() {
    return const EmptyStateView(
      icon: Icons.event_available,
      title: 'Nothing scheduled',
      subtitle: 'No appointments for this day.',
    );
  }

  Widget _buildListBody({required String emptyMessage}) {
    if (_appointments.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refreshAll,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.45,
              child: EmptyStateView(
                icon: Icons.event_outlined,
                title: emptyMessage,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshAll,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        itemCount: _appointments.length,
        itemBuilder: (context, i) {
          final apt = _appointments[i];
          return _AppointmentRow(
            appointment: apt,
            receptionistName: _receptionists[apt['receptionist_id']] ?? '—',
            onTap: () => context.push('/appointments/${apt['id']}').then((_) {
              // Reflect any confirm/cancel made on the detail screen immediately.
              if (mounted) {
                _refreshAll();
              }
            }),
          );
        },
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: ErrorStateView(
        title: 'Could not load appointments',
        message: _error,
        onRetry: _refreshAll,
      ),
    );
  }
}

enum _TodayContext {
  resolving,
  ready,
  noUser,
  noAssistant,
  multiAssistant,
}

class _AppointmentRow extends StatelessWidget {
  final Map<String, dynamic> appointment;
  final String receptionistName;
  final VoidCallback onTap;

  const _AppointmentRow({
    required this.appointment,
    required this.receptionistName,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final start = appointment['start_time'] != null
        ? DateTime.tryParse(appointment['start_time'] as String)
        : null;
    final status = appointment['status'] as String? ?? 'needs_review';
    final serviceName = (appointment['service_name'] as String?)?.trim();
    final displayService = serviceName != null && serviceName.isNotEmpty
        ? serviceName
        : 'Generic appointment';
    final isGeneric = (appointment['booking_mode'] as String?) == 'generic' ||
        (serviceName == null || serviceName.isEmpty);
    final callerNumber = appointment['caller_number'] as String?;
    final paymentLink = appointment['payment_link'] as String?;
    final hasPayment = paymentLink != null && paymentLink.isNotEmpty;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Status accent stripe — status is readable at a glance without
              // hunting for the chip.
              Container(width: 4, color: _accentColor(status)),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      formatAppointmentDateTime(start),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  StatusChip(status: status),
                  if (isGeneric) _GenericBadge(),
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right, size: 20, color: Colors.grey.shade400),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                displayService,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.person_outline, size: 14, color: Colors.grey.shade600),
                  const SizedBox(width: 4),
                  Text(
                    receptionistName,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  if (callerNumber != null && callerNumber.isNotEmpty) ...[
                    const SizedBox(width: 16),
                    Icon(Icons.phone_outlined, size: 14, color: Colors.grey.shade600),
                    const SizedBox(width: 4),
                    Text(
                      maskPhone(callerNumber),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ],
              ),
              if (hasPayment) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.payment, size: 14, color: Colors.green.shade700),
                    const SizedBox(width: 4),
                    Text(
                      'Payment link attached',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.green.shade700,
                          ),
                    ),
                  ],
                ),
              ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _accentColor(String status) {
    switch (status) {
      case 'needs_review':
        return Colors.orange.shade600;
      case 'confirmed':
        return Colors.green.shade600;
      case 'completed':
        return Colors.blue.shade400;
      case 'cancelled':
        return Colors.red.shade300;
      default:
        return Colors.grey.shade300;
    }
  }
}

class _GenericBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.amber.shade100,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.warning_amber, size: 12, color: Colors.amber.shade800),
          const SizedBox(width: 4),
          Text(
            'Generic',
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.amber.shade900),
          ),
        ],
      ),
    );
  }
}
