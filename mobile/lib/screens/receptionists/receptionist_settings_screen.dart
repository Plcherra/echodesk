import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/api_client.dart';
import '../../theme/echodesk_theme.dart';
import '../../widgets/constrained_scaffold_body.dart';
import 'settings_tabs/calendar_tab.dart';
import 'settings_tabs/staff_tab.dart';
import 'settings_tabs/locations_tab.dart';
import 'settings_tabs/instructions_tab.dart';
import 'settings_tabs/website_tab.dart';

class ReceptionistSettingsScreen extends StatefulWidget {
  final String receptionistId;

  const ReceptionistSettingsScreen({super.key, required this.receptionistId});

  @override
  State<ReceptionistSettingsScreen> createState() =>
      _ReceptionistSettingsScreenState();
}

class _ReceptionistSettingsScreenState extends State<ReceptionistSettingsScreen>
    with TickerProviderStateMixin {
  late TabController _tabController;
  String? _receptionistName;
  String _mode = 'personal';
  Map<String, dynamic>? _calendarStatus;
  bool _loadingCalendarStatus = false;
  bool _loading = true;
  List<Tab> _tabs = const [];
  int _loadSeq = 0;
  int _calendarStatusLoadSeq = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 0, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final int seq = ++_loadSeq;
    final res = await Supabase.instance.client
        .from('receptionists')
        .select('name, mode')
        .eq('id', widget.receptionistId)
        .maybeSingle();
    _receptionistName = res?['name'] as String?;
    _mode = (res?['mode'] as String?) ?? 'personal';

    // Exact tab order per spec:
    // Personal/Solo: Calendar, Services, Promos, Website, Instructions
    // Business/Team: Calendar, Staff, Services, Locations, Promos, Website, Instructions
    final List<Tab> tabs;
    if (_mode == 'business') {
      tabs = const [
        Tab(text: 'Calendar'),
        Tab(text: 'Staff'),
        Tab(text: 'Services'),
        Tab(text: 'Locations'),
        Tab(text: 'Promos'),
        Tab(text: 'Website'),
        Tab(text: 'Instructions'),
      ];
    } else {
      tabs = const [
        Tab(text: 'Calendar'),
        Tab(text: 'Services'),
        Tab(text: 'Promos'),
        Tab(text: 'Website'),
        Tab(text: 'Instructions'),
      ];
    }

    if (!mounted || seq != _loadSeq) return;

    TabController? nextController;
    TabController? oldController;
    if (_tabController.length != tabs.length) {
      final nextIndex =
          _tabController.index.clamp(0, (tabs.length - 1).clamp(0, 1 << 20));
      nextController = TabController(
          length: tabs.length, vsync: this, initialIndex: nextIndex);
      oldController = _tabController;
    }

    if (nextController != null) {
      oldController?.dispose();
    }

    if (!mounted || seq != _loadSeq) {
      nextController?.dispose();
      return;
    }

    setState(() {
      _tabs = tabs;
      _loading = false;
      if (nextController != null) {
        _tabController = nextController;
      }
    });

    await _loadCalendarStatus();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_receptionistName ?? 'Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.go('/receptionists/${widget.receptionistId}'),
        ),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: _tabs,
        ),
      ),
      body: constrainedScaffoldBody(
        child: TabBarView(
          controller: _tabController,
          children: _buildTabViews(),
        ),
      ),
    );
  }

  Future<void> _loadCalendarStatus() async {
    if (!mounted) return;
    final int seq = ++_calendarStatusLoadSeq;
    setState(() => _loadingCalendarStatus = true);
    try {
      final res = await ApiClient.get(
        '/api/mobile/receptionists/${widget.receptionistId}/calendar-status',
      );
      Map<String, dynamic>? decoded;
      if (res.statusCode >= 200 &&
          res.statusCode < 300 &&
          res.body.trim().isNotEmpty) {
        try {
          final data = jsonDecode(res.body);
          if (data is Map<String, dynamic>) {
            decoded = data;
          }
        } catch (_) {
          // Invalid JSON or wrong shape; leave _calendarStatus as-is or null.
        }
      }
      if (!mounted || seq != _calendarStatusLoadSeq) return;
      setState(() {
        _calendarStatus = decoded;
        _loadingCalendarStatus = false;
      });
    } catch (_) {
      if (!mounted || seq != _calendarStatusLoadSeq) return;
      setState(() => _loadingCalendarStatus = false);
    }
  }

  List<Widget> _buildTabViews() {
    final views = <Widget>[];
    for (final tab in _tabs) {
      switch (tab.text) {
        case 'Calendar':
          views.add(ReceptionistCalendarTab(
            receptionistId: widget.receptionistId,
            status: _calendarStatus,
            loading: _loadingCalendarStatus,
            onRefresh: _loadCalendarStatus,
            onModeChanged: (mode) async {
              setState(() => _mode = mode);
              await _load();
            },
          ));
          break;
        case 'Staff':
          views
              .add(ReceptionistStaffTab(receptionistId: widget.receptionistId));
          break;
        case 'Services':
          views.add(_ServicesTab(receptionistId: widget.receptionistId));
          break;
        case 'Locations':
          views.add(ReceptionistLocationsTab(receptionistId: widget.receptionistId));
          break;
        case 'Promos':
          views.add(_PromosTab(receptionistId: widget.receptionistId));
          break;
        case 'Website':
          views.add(
              ReceptionistWebsiteTab(receptionistId: widget.receptionistId));
          break;
        case 'Instructions':
          views.add(ReceptionistInstructionsTab(
              receptionistId: widget.receptionistId));
          break;
        default:
          views.add(const SizedBox.shrink());
      }
    }
    return views;
  }
}

class _ServicesTab extends StatefulWidget {
  final String receptionistId;

  const _ServicesTab({required this.receptionistId});

  @override
  State<_ServicesTab> createState() => _ServicesTabState();
}

class _ServicesTabState extends State<_ServicesTab> {
  List<Map<String, dynamic>> _services = [];
  bool _loading = true;
  bool _showEditor = false;
  Map<String, dynamic>? _editingService;
  Key _formKey = const ValueKey('new-service');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final res = await Supabase.instance.client
        .from('services')
        .select(
            'id, name, description, price_cents, duration_minutes, requires_location, default_location_type, followup_mode, followup_message_template, payment_link, meeting_instructions, owner_selected_platform, internal_followup_notes')
        .eq('receptionist_id', widget.receptionistId)
        .order('name');
    if (!mounted) return;
    final services = (res as List).cast<Map<String, dynamic>>();
    setState(() {
      _services = services;
      _loading = false;
      if (services.isEmpty) {
        _showEditor = true;
        _editingService = null;
      }
    });
  }

  void _openAddForm() {
    setState(() {
      _showEditor = true;
      _editingService = null;
      _formKey = UniqueKey();
    });
  }

  void _openEditForm(Map<String, dynamic> service) {
    setState(() {
      _showEditor = true;
      _editingService = service;
      _formKey = ValueKey(service['id']);
    });
  }

  void _closeEditor() {
    setState(() {
      if (_services.isEmpty) {
        // Keep the empty-state form visible; remount to clear fields.
        _showEditor = true;
        _editingService = null;
        _formKey = UniqueKey();
      } else {
        _showEditor = false;
        _editingService = null;
      }
    });
  }

  Future<void> _onEditorSaved() async {
    setState(() {
      _showEditor = false;
      _editingService = null;
    });
    await _load();
  }

  Future<void> _updateService(String id,
      {bool? requiresLocation, String? defaultLocationType}) async {
    final updates = <String, dynamic>{};
    if (requiresLocation != null) {
      updates['requires_location'] = requiresLocation;
    }
    if (defaultLocationType != null) {
      updates['default_location_type'] =
          defaultLocationType.isEmpty ? null : defaultLocationType;
    }
    if (updates.isEmpty) return;
    await Supabase.instance.client
        .from('services')
        .update(updates)
        .eq('id', id)
        .eq('receptionist_id', widget.receptionistId);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final isEmpty = _services.isEmpty;
    final showForm = _showEditor || isEmpty;
    final editing = _editingService != null;
    final canCancel = !isEmpty || editing;

    return ListView(
      padding: const EdgeInsets.all(EchoDeskSpacing.lg),
      children: [
        if (!showForm) ...[
          Text(
            'Service menu with pricing, duration, and optional location.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: EchoDeskColors.muted,
                ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _openAddForm,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add another service'),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
          const SizedBox(height: EchoDeskSpacing.sm),
        ] else ...[
          Text(
            isEmpty
                ? 'Add services so callers can book the right thing automatically.'
                : (editing
                    ? 'Update this service.'
                    : 'Add another service to your menu.'),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: EchoDeskColors.muted,
                ),
          ),
          const SizedBox(height: EchoDeskSpacing.md),
          _InlineServiceForm(
            key: _formKey,
            receptionistId: widget.receptionistId,
            service: _editingService,
            onCancel: canCancel ? _closeEditor : null,
            onSaved: _onEditorSaved,
          ),
          if (_services.isNotEmpty) const SizedBox(height: EchoDeskSpacing.lg),
        ],
        if (_services.isNotEmpty)
          ..._services.map((s) {
            final requiresLocation =
                (s['requires_location'] as bool?) ?? false;
            final rawType = s['default_location_type'] as String?;
            final defaultLocationType =
                (rawType == null || rawType == 'no_location')
                    ? 'customer_address'
                    : rawType;
            return Container(
              margin: const EdgeInsets.only(bottom: EchoDeskSpacing.sm),
              decoration: BoxDecoration(
                color: EchoDeskColors.surface,
                borderRadius: BorderRadius.circular(EchoDeskRadii.md),
                border: Border.all(color: EchoDeskColors.line),
              ),
              child: InkWell(
                onTap: () => _openEditForm(s),
                borderRadius: BorderRadius.circular(EchoDeskRadii.md),
                child: Padding(
                  padding: const EdgeInsets.all(EchoDeskSpacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  s['name'] ?? '',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyMedium
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '\$${(s['price_cents'] ?? 0) / 100} · ${s['duration_minutes'] ?? 0} min',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(color: EchoDeskColors.muted),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: Icon(Icons.delete_outline,
                                color: EchoDeskColors.danger),
                            onPressed: () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('Delete service?'),
                                  content: Text(
                                    'Remove "${s['name'] ?? 'this service'}"? This cannot be undone.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.of(ctx).pop(false),
                                      child: const Text('Cancel'),
                                    ),
                                    FilledButton(
                                      onPressed: () =>
                                          Navigator.of(ctx).pop(true),
                                      style: FilledButton.styleFrom(
                                        backgroundColor:
                                            Theme.of(ctx).colorScheme.error,
                                      ),
                                      child: const Text('Delete'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm == true && mounted) {
                                await Supabase.instance.client
                                    .from('services')
                                    .delete()
                                    .eq('id', s['id'])
                                    .eq('receptionist_id',
                                        widget.receptionistId);
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      '"${s['name'] ?? 'Service'}" deleted',
                                    ),
                                  ),
                                );
                                _load();
                              }
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: EchoDeskSpacing.sm),
                      CheckboxListTile(
                        title: const Text('Requires location',
                            style: TextStyle(fontSize: 14)),
                        value: requiresLocation,
                        onChanged: (v) => _updateService(
                          s['id'] as String,
                          requiresLocation: v ?? false,
                        ),
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                      ),
                      if (requiresLocation) ...[
                        const SizedBox(height: EchoDeskSpacing.sm),
                        DropdownButtonFormField<String>(
                          // ignore: deprecated_member_use -- value is the current selection; initialValue is for uncontrolled form fields
                          value: defaultLocationType,
                          decoration: const InputDecoration(
                            labelText: 'Location type',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          isExpanded: true,
                          items: const [
                            DropdownMenuItem(
                              value: 'customer_address',
                              child: Text('Customer address'),
                            ),
                            DropdownMenuItem(
                                value: 'phone_call',
                                child: Text('Phone call')),
                            DropdownMenuItem(
                                value: 'video_meeting',
                                child: Text('Video meeting')),
                            DropdownMenuItem(
                                value: 'custom', child: Text('Custom text')),
                          ],
                          onChanged: (v) => _updateService(
                            s['id'] as String,
                            defaultLocationType: v ?? 'customer_address',
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          }),
      ],
    );
  }
}

class _InlineServiceForm extends StatefulWidget {
  final String receptionistId;
  final Map<String, dynamic>? service;
  final VoidCallback? onCancel;
  final Future<void> Function() onSaved;

  const _InlineServiceForm({
    super.key,
    required this.receptionistId,
    required this.service,
    required this.onCancel,
    required this.onSaved,
  });

  @override
  State<_InlineServiceForm> createState() => _InlineServiceFormState();
}

class _InlineServiceFormState extends State<_InlineServiceForm> {
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _durationController;
  late final TextEditingController _priceController;
  late final TextEditingController _followupTemplateController;
  late final TextEditingController _paymentLinkController;
  late final TextEditingController _meetingInstructionsController;
  late final TextEditingController _ownerSelectedPlatformController;
  late final TextEditingController _internalFollowupNotesController;
  late String _followupMode;
  late bool _requiresLocation;
  late String _locationType;
  bool _saving = false;

  static const _denseLabelStyle = TextStyle(
    fontSize: 12.5,
    color: EchoDeskColors.muted,
    height: 1.15,
  );

  @override
  void initState() {
    super.initState();
    final service = widget.service;
    _nameController =
        TextEditingController(text: (service?['name'] as String?) ?? '');
    _descriptionController =
        TextEditingController(text: (service?['description'] as String?) ?? '');
    _durationController = TextEditingController(
      text: ((service?['duration_minutes'] as int?)?.toString()) ?? '',
    );
    _priceController = TextEditingController(
      text: ((service?['price_cents'] as int?) != null)
          ? (((service?['price_cents'] as int) / 100).toStringAsFixed(2))
          : '',
    );
    var followupMode =
        ((service?['followup_mode'] as String?) ?? 'under_review');
    if (!['none', 'under_review', 'send_payment_link', 'send_custom_message']
        .contains(followupMode)) {
      followupMode = 'under_review';
    }
    _followupMode = followupMode;
    _followupTemplateController = TextEditingController(
      text: (service?['followup_message_template'] as String?) ?? '',
    );
    _paymentLinkController = TextEditingController(
      text: (service?['payment_link'] as String?) ?? '',
    );
    _meetingInstructionsController = TextEditingController(
      text: (service?['meeting_instructions'] as String?) ?? '',
    );
    _ownerSelectedPlatformController = TextEditingController(
      text: (service?['owner_selected_platform'] as String?) ?? '',
    );
    _internalFollowupNotesController = TextEditingController(
      text: (service?['internal_followup_notes'] as String?) ?? '',
    );
    _requiresLocation = (service?['requires_location'] as bool?) ?? false;
    var locationType =
        ((service?['default_location_type'] as String?) ?? 'customer_address');
    if (locationType == 'no_location') locationType = 'customer_address';
    _locationType = locationType;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _durationController.dispose();
    _priceController.dispose();
    _followupTemplateController.dispose();
    _paymentLinkController.dispose();
    _meetingInstructionsController.dispose();
    _ownerSelectedPlatformController.dispose();
    _internalFollowupNotesController.dispose();
    super.dispose();
  }

  InputDecoration _decoration(String label, {bool filled = false}) {
    return InputDecoration(
      labelText: label,
      labelStyle: _denseLabelStyle,
      floatingLabelStyle: _denseLabelStyle.copyWith(
        fontSize: 12,
        color: EchoDeskColors.muted,
      ),
      floatingLabelBehavior: FloatingLabelBehavior.always,
      alignLabelWithHint: true,
      border: const OutlineInputBorder(),
      isDense: true,
      filled: filled,
      fillColor: filled ? EchoDeskColors.surface : null,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    );
  }

  Widget _settingsSection({
    required String title,
    required String subtitle,
    required List<Widget> children,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(EchoDeskSpacing.md),
      decoration: BoxDecoration(
        color: EchoDeskColors.surface,
        borderRadius: BorderRadius.circular(EchoDeskRadii.md),
        border: Border.all(color: EchoDeskColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: EchoDeskSpacing.xs),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: EchoDeskColors.muted,
                ),
          ),
          const SizedBox(height: EchoDeskSpacing.sm + 4),
          ...children,
        ],
      ),
    );
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || _saving) return;

    setState(() => _saving = true);

    final duration = int.tryParse(_durationController.text.trim());
    final priceDollars = double.tryParse(_priceController.text.trim());
    final priceCents =
        priceDollars != null ? (priceDollars * 100).round() : null;

    final payload = <String, dynamic>{
      'name': name,
      'description': _descriptionController.text.trim(),
      'requires_location': _requiresLocation,
      'default_location_type': _requiresLocation ? _locationType : null,
      'followup_mode': _followupMode,
      'followup_message_template':
          _followupTemplateController.text.trim().isEmpty
              ? null
              : _followupTemplateController.text.trim(),
      'payment_link': _paymentLinkController.text.trim().isEmpty
          ? null
          : _paymentLinkController.text.trim(),
      'meeting_instructions':
          _meetingInstructionsController.text.trim().isEmpty
              ? null
              : _meetingInstructionsController.text.trim(),
      'owner_selected_platform':
          _ownerSelectedPlatformController.text.trim().isEmpty
              ? null
              : _ownerSelectedPlatformController.text.trim(),
      'internal_followup_notes':
          _internalFollowupNotesController.text.trim().isEmpty
              ? null
              : _internalFollowupNotesController.text.trim(),
    };
    if (duration != null) payload['duration_minutes'] = duration;
    if (priceCents != null) payload['price_cents'] = priceCents;

    try {
      if (widget.service == null) {
        await Supabase.instance.client.from('services').insert({
          ...payload,
          'receptionist_id': widget.receptionistId,
        });
      } else {
        await Supabase.instance.client
            .from('services')
            .update(payload)
            .eq('id', widget.service!['id'])
            .eq('receptionist_id', widget.receptionistId);
      }
      if (!mounted) return;
      await widget.onSaved();
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save service')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    const fieldGap = SizedBox(height: EchoDeskSpacing.sm);
    const sectionGap = SizedBox(height: EchoDeskSpacing.md);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _settingsSection(
          title: 'Basics',
          subtitle: 'Name, description, duration, and price.',
          children: [
            TextField(
              controller: _nameController,
              decoration: _decoration('Name'),
              textInputAction: TextInputAction.next,
            ),
            fieldGap,
            TextField(
              controller: _descriptionController,
              decoration: _decoration('Description'),
              maxLines: 2,
            ),
            fieldGap,
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _durationController,
                    decoration: _decoration('Duration (min)'),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: EchoDeskSpacing.sm),
                Expanded(
                  child: TextField(
                    controller: _priceController,
                    decoration: _decoration(r'Price ($)'),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        sectionGap,
        _settingsSection(
          title: 'Location',
          subtitle: 'Whether this service needs a place or meeting type.',
          children: [
            CheckboxListTile(
              title: const Text(
                'Requires location',
                style: TextStyle(fontSize: 14),
              ),
              value: _requiresLocation,
              onChanged: (v) =>
                  setState(() => _requiresLocation = v ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
            if (_requiresLocation) ...[
              fieldGap,
              DropdownButtonFormField<String>(
                // ignore: deprecated_member_use -- value is the current selection; initialValue is for uncontrolled form fields
                value: _locationType,
                decoration: _decoration('Location type'),
                isExpanded: true,
                items: const [
                  DropdownMenuItem(
                    value: 'customer_address',
                    child: Text('Customer address'),
                  ),
                  DropdownMenuItem(
                    value: 'phone_call',
                    child: Text('Phone call'),
                  ),
                  DropdownMenuItem(
                    value: 'video_meeting',
                    child: Text('Video meeting'),
                  ),
                  DropdownMenuItem(
                    value: 'custom',
                    child: Text('Custom text'),
                  ),
                ],
                onChanged: (v) => setState(
                  () => _locationType = v ?? 'customer_address',
                ),
              ),
            ],
          ],
        ),
        sectionGap,
        _settingsSection(
          title: 'Follow-up',
          subtitle: 'Owner-controlled actions after a booking.',
          children: [
            DropdownButtonFormField<String>(
              initialValue: _followupMode,
              decoration: _decoration('Follow-up mode'),
              isExpanded: true,
              items: const [
                DropdownMenuItem(value: 'none', child: Text('None')),
                DropdownMenuItem(
                  value: 'under_review',
                  child: Text('Under review'),
                ),
                DropdownMenuItem(
                  value: 'send_payment_link',
                  child: Text('Send payment link'),
                ),
                DropdownMenuItem(
                  value: 'send_custom_message',
                  child: Text('Send custom message'),
                ),
              ],
              onChanged: (v) =>
                  setState(() => _followupMode = v ?? 'under_review'),
            ),
            fieldGap,
            TextField(
              controller: _followupTemplateController,
              decoration: _decoration(
                'Follow-up message template (optional)',
              ),
              maxLines: 3,
            ),
            fieldGap,
            TextField(
              controller: _paymentLinkController,
              decoration: _decoration('Payment link (optional)'),
            ),
            fieldGap,
            TextField(
              controller: _ownerSelectedPlatformController,
              decoration: _decoration('Owner-selected platform (optional)'),
            ),
            fieldGap,
            TextField(
              controller: _meetingInstructionsController,
              decoration: _decoration('Meeting instructions (optional)'),
              maxLines: 2,
            ),
            fieldGap,
            TextField(
              controller: _internalFollowupNotesController,
              decoration: _decoration('Internal follow-up notes (optional)'),
              maxLines: 2,
            ),
          ],
        ),
        const SizedBox(height: EchoDeskSpacing.lg),
        if (widget.onCancel != null)
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _saving ? null : widget.onCancel,
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: EchoDeskSpacing.sm),
              Expanded(
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(widget.service == null ? 'Save service' : 'Save'),
                ),
              ),
            ],
          )
        else
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save service'),
          ),
      ],
    );
  }
}

class _PromosTab extends StatefulWidget {
  final String receptionistId;

  const _PromosTab({required this.receptionistId});

  @override
  State<_PromosTab> createState() => _PromosTabState();
}

class _PromosTabState extends State<_PromosTab> {
  List<Map<String, dynamic>> _promos = [];
  bool _loading = true;
  bool _showEditor = false;
  Map<String, dynamic>? _editingPromo;
  Key _formKey = const ValueKey('new-promo');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final res = await Supabase.instance.client
        .from('promos')
        .select('id, description, code')
        .eq('receptionist_id', widget.receptionistId);
    if (!mounted) return;
    final promos = (res as List).cast<Map<String, dynamic>>();
    setState(() {
      _promos = promos;
      _loading = false;
      if (promos.isEmpty) {
        _showEditor = true;
        _editingPromo = null;
      }
    });
  }

  void _openAddForm() {
    setState(() {
      _showEditor = true;
      _editingPromo = null;
      _formKey = UniqueKey();
    });
  }

  void _openEditForm(Map<String, dynamic> promo) {
    setState(() {
      _showEditor = true;
      _editingPromo = promo;
      _formKey = ValueKey(promo['id']);
    });
  }

  void _closeEditor() {
    setState(() {
      if (_promos.isEmpty) {
        _showEditor = true;
        _editingPromo = null;
        _formKey = UniqueKey();
      } else {
        _showEditor = false;
        _editingPromo = null;
      }
    });
  }

  Future<void> _onEditorSaved() async {
    setState(() {
      _showEditor = false;
      _editingPromo = null;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final isEmpty = _promos.isEmpty;
    final showForm = _showEditor || isEmpty;
    final editing = _editingPromo != null;
    final canCancel = !isEmpty || editing;

    return ListView(
      padding: const EdgeInsets.all(EchoDeskSpacing.lg),
      children: [
        if (!showForm) ...[
          Text(
            'Discount codes and promotions.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: EchoDeskColors.muted,
                ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _openAddForm,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add another promo'),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
          const SizedBox(height: EchoDeskSpacing.sm),
        ] else ...[
          Text(
            isEmpty
                ? 'Add an offer, package, or seasonal promotion.'
                : (editing
                    ? 'Update this promo.'
                    : 'Add another promo to your list.'),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: EchoDeskColors.muted,
                ),
          ),
          const SizedBox(height: EchoDeskSpacing.md),
          _InlinePromoForm(
            key: _formKey,
            receptionistId: widget.receptionistId,
            promo: _editingPromo,
            onCancel: canCancel ? _closeEditor : null,
            onSaved: _onEditorSaved,
          ),
          if (_promos.isNotEmpty) const SizedBox(height: EchoDeskSpacing.lg),
        ],
        if (_promos.isNotEmpty)
          ..._promos.map((p) {
            final code = (p['code'] as String?)?.trim() ?? '';
            final description = (p['description'] as String?)?.trim() ?? '';
            final title = [
              if (code.isNotEmpty) code,
              if (description.isNotEmpty) description,
            ].join(' · ');
            return Container(
              margin: const EdgeInsets.only(bottom: EchoDeskSpacing.sm),
              decoration: BoxDecoration(
                color: EchoDeskColors.surface,
                borderRadius: BorderRadius.circular(EchoDeskRadii.md),
                border: Border.all(color: EchoDeskColors.line),
              ),
              child: ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                title: Text(
                  title.isEmpty ? 'Promo' : title,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                onTap: () => _openEditForm(p),
                trailing: IconButton(
                  icon: Icon(Icons.delete_outline,
                      color: EchoDeskColors.danger),
                  onPressed: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Delete promotion?'),
                        content: Text(
                          'Remove "${code.isNotEmpty ? code : 'this promo'}"? This cannot be undone.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.of(ctx).pop(true),
                            style: FilledButton.styleFrom(
                              backgroundColor:
                                  Theme.of(ctx).colorScheme.error,
                            ),
                            child: const Text('Delete'),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true && mounted) {
                      await Supabase.instance.client
                          .from('promos')
                          .delete()
                          .eq('id', p['id'])
                          .eq('receptionist_id', widget.receptionistId);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            '"${code.isNotEmpty ? code : 'Promotion'}" deleted',
                          ),
                        ),
                      );
                      _load();
                    }
                  },
                ),
              ),
            );
          }),
      ],
    );
  }
}

class _InlinePromoForm extends StatefulWidget {
  final String receptionistId;
  final Map<String, dynamic>? promo;
  final VoidCallback? onCancel;
  final Future<void> Function() onSaved;

  const _InlinePromoForm({
    super.key,
    required this.receptionistId,
    required this.promo,
    required this.onCancel,
    required this.onSaved,
  });

  @override
  State<_InlinePromoForm> createState() => _InlinePromoFormState();
}

class _InlinePromoFormState extends State<_InlinePromoForm> {
  late final TextEditingController _codeController;
  late final TextEditingController _descriptionController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _codeController =
        TextEditingController(text: (widget.promo?['code'] as String?) ?? '');
    _descriptionController = TextEditingController(
      text: (widget.promo?['description'] as String?) ?? '',
    );
  }

  @override
  void dispose() {
    _codeController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final code = _codeController.text.trim();
    final description = _descriptionController.text.trim();
    if ((code.isEmpty && description.isEmpty) || _saving) return;

    setState(() => _saving = true);

    final payload = <String, dynamic>{
      'code': code.isEmpty ? null : code,
      'description': description.isEmpty ? null : description,
      'receptionist_id': widget.receptionistId,
    };

    try {
      if (widget.promo == null) {
        await Supabase.instance.client.from('promos').insert(payload);
      } else {
        await Supabase.instance.client
            .from('promos')
            .update(payload)
            .eq('id', widget.promo!['id'])
            .eq('receptionist_id', widget.receptionistId);
      }
      if (!mounted) return;
      await widget.onSaved();
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save promo')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(EchoDeskSpacing.md),
          decoration: BoxDecoration(
            color: EchoDeskColors.surface,
            borderRadius: BorderRadius.circular(EchoDeskRadii.md),
            border: Border.all(color: EchoDeskColors.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.promo == null ? 'Promo details' : 'Edit promo',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: EchoDeskSpacing.xs),
              Text(
                'Code and description callers can hear about.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: EchoDeskColors.muted,
                    ),
              ),
              const SizedBox(height: EchoDeskSpacing.sm + 4),
              TextField(
                controller: _codeController,
                decoration: const InputDecoration(
                  labelText: 'Code',
                  hintText: 'e.g. WELCOME20',
                  border: OutlineInputBorder(),
                ),
                textCapitalization: TextCapitalization.characters,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: EchoDeskSpacing.sm),
              TextField(
                controller: _descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  hintText: 'e.g. 20% off first visit',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
                maxLines: 2,
              ),
            ],
          ),
        ),
        const SizedBox(height: EchoDeskSpacing.lg),
        if (widget.onCancel != null)
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _saving ? null : widget.onCancel,
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: EchoDeskSpacing.sm),
              Expanded(
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(widget.promo == null ? 'Save promo' : 'Save'),
                ),
              ),
            ],
          )
        else
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save promo'),
          ),
      ],
    );
  }
}

// moved tab widgets to settings_tabs/*
