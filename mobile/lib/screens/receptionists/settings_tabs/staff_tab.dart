import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../services/api_client.dart';
import '../../../theme/echodesk_theme.dart';

class ReceptionistStaffTab extends StatefulWidget {
  final String receptionistId;

  const ReceptionistStaffTab({super.key, required this.receptionistId});

  @override
  State<ReceptionistStaffTab> createState() => _ReceptionistStaffTabState();
}

class _ReceptionistStaffTabState extends State<ReceptionistStaffTab> {
  List<Map<String, dynamic>> _staff = [];
  List<_GoogleCalendarOption> _calendars = [];
  bool _loading = true;
  bool _showEditor = false;
  Map<String, dynamic>? _editing;
  Key _formKey = const ValueKey('new-staff');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final staffFuture = Supabase.instance.client
        .from('staff')
        .select('id, name, role, calendar_id')
        .eq('receptionist_id', widget.receptionistId)
        .order('name');
    final calendarsFuture = _fetchCalendars();
    final staffRaw = await staffFuture;
    final calendars = await calendarsFuture;
    if (!mounted) return;
    final staff = (staffRaw as List).cast<Map<String, dynamic>>();
    setState(() {
      _staff = staff;
      _calendars = calendars;
      _loading = false;
      if (staff.isEmpty) {
        _showEditor = true;
        _editing = null;
      }
    });
  }

  Future<List<_GoogleCalendarOption>> _fetchCalendars() async {
    try {
      final res = await ApiClient.get('/api/mobile/google/calendars');
      if (res.statusCode < 200 || res.statusCode >= 300) return [];
      final body = jsonDecode(res.body);
      if (body is! Map) return [];
      final list = body['calendars'];
      if (list is! List) return [];
      return list
          .whereType<Map>()
          .map((c) => _GoogleCalendarOption(
                id: (c['id'] ?? '').toString(),
                summary: (c['summary'] ?? c['id'] ?? '').toString(),
                primary: c['primary'] == true,
              ))
          .where((c) => c.id.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  void _openAddForm() {
    setState(() {
      _showEditor = true;
      _editing = null;
      _formKey = UniqueKey();
    });
  }

  void _openEditForm(Map<String, dynamic> member) {
    setState(() {
      _showEditor = true;
      _editing = member;
      _formKey = ValueKey(member['id']);
    });
  }

  void _closeEditor() {
    setState(() {
      if (_staff.isEmpty) {
        _showEditor = true;
        _editing = null;
        _formKey = UniqueKey();
      } else {
        _showEditor = false;
        _editing = null;
      }
    });
  }

  Future<void> _onEditorSaved() async {
    setState(() {
      _showEditor = false;
      _editing = null;
    });
    await _load();
  }

  String _calendarLabel(Map<String, dynamic> member) {
    final id = (member['calendar_id'] ?? '').toString().trim();
    if (id.isEmpty) return 'Default calendar';
    for (final c in _calendars) {
      if (c.id == id) return c.summary;
    }
    return id.contains('@') ? id : 'Custom calendar';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final isEmpty = _staff.isEmpty;
    final showForm = _showEditor || isEmpty;
    final editing = _editing != null;
    final canCancel = !isEmpty || editing;

    return ListView(
      padding: const EdgeInsets.all(EchoDeskSpacing.lg),
      children: [
        Text(
          'Each employee can use a different calendar in your connected Google account. '
          'Callers can book with a specific person (e.g. Bianca or Sabrina).',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: EchoDeskColors.muted,
              ),
        ),
        const SizedBox(height: EchoDeskSpacing.md),
        if (!showForm) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: _openAddForm,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add staff'),
            ),
          ),
          const SizedBox(height: EchoDeskSpacing.md),
        ],
        if (showForm) ...[
          _StaffEditor(
            key: _formKey,
            receptionistId: widget.receptionistId,
            member: _editing,
            calendars: _calendars,
            canCancel: canCancel,
            onCancel: _closeEditor,
            onSaved: _onEditorSaved,
          ),
          const SizedBox(height: EchoDeskSpacing.md),
        ],
        ..._staff.map((s) {
          final role = (s['role'] ?? '').toString().trim();
          final subtitle = [
            if (role.isNotEmpty) role,
            _calendarLabel(s),
          ].join(' · ');
          return Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              onTap: () => _openEditForm(s),
              title: Text(
                s['name'] ?? '',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              subtitle: Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: EchoDeskColors.muted,
                    ),
              ),
              trailing: IconButton(
                icon: Icon(Icons.delete_outline, color: EchoDeskColors.danger),
                onPressed: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Delete staff member?'),
                      content: Text(
                        'Remove "${s['name'] ?? 'this person'}"? This cannot be undone.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.of(ctx).pop(true),
                          style: FilledButton.styleFrom(
                            backgroundColor: Theme.of(ctx).colorScheme.error,
                          ),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true && mounted) {
                    await Supabase.instance.client
                        .from('staff')
                        .delete()
                        .eq('id', s['id'])
                        .eq('receptionist_id', widget.receptionistId);
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('"${s['name'] ?? 'Staff'}" deleted'),
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

class _GoogleCalendarOption {
  final String id;
  final String summary;
  final bool primary;

  const _GoogleCalendarOption({
    required this.id,
    required this.summary,
    required this.primary,
  });
}

class _StaffEditor extends StatefulWidget {
  final String receptionistId;
  final Map<String, dynamic>? member;
  final List<_GoogleCalendarOption> calendars;
  final bool canCancel;
  final VoidCallback onCancel;
  final Future<void> Function() onSaved;

  const _StaffEditor({
    super.key,
    required this.receptionistId,
    required this.member,
    required this.calendars,
    required this.canCancel,
    required this.onCancel,
    required this.onSaved,
  });

  @override
  State<_StaffEditor> createState() => _StaffEditorState();
}

class _StaffEditorState extends State<_StaffEditor> {
  late final TextEditingController _nameController;
  late final TextEditingController _roleController;
  String? _calendarId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final m = widget.member;
    _nameController = TextEditingController(text: m?['name']?.toString() ?? '');
    _roleController = TextEditingController(text: m?['role']?.toString() ?? '');
    final existing = (m?['calendar_id'] ?? '').toString().trim();
    _calendarId = existing.isEmpty ? null : existing;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _roleController.dispose();
    super.dispose();
  }

  InputDecoration _decoration(String label) {
    return InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
      isDense: true,
    );
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || _saving) return;
    setState(() => _saving = true);

    final payload = <String, dynamic>{
      'name': name,
      'role':
          _roleController.text.trim().isEmpty ? null : _roleController.text.trim(),
      'calendar_id': (_calendarId ?? '').trim().isEmpty ? null : _calendarId,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };

    try {
      if (widget.member == null) {
        await Supabase.instance.client.from('staff').insert({
          ...payload,
          'receptionist_id': widget.receptionistId,
        });
      } else {
        await Supabase.instance.client
            .from('staff')
            .update(payload)
            .eq('id', widget.member!['id'])
            .eq('receptionist_id', widget.receptionistId);
      }
      if (!mounted) return;
      await widget.onSaved();
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save staff member')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final calendarItems = <DropdownMenuItem<String?>>[
      const DropdownMenuItem<String?>(
        value: null,
        child: Text('Default (receptionist calendar)'),
      ),
      ...widget.calendars.map(
        (c) => DropdownMenuItem<String?>(
          value: c.id,
          child: Text(
            c.primary ? '${c.summary} (primary)' : c.summary,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    ];
    if (_calendarId != null &&
        !widget.calendars.any((c) => c.id == _calendarId)) {
      calendarItems.add(
        DropdownMenuItem<String?>(
          value: _calendarId,
          child: Text(_calendarId!, overflow: TextOverflow.ellipsis),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.member == null ? 'Add staff' : 'Edit staff',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: EchoDeskSpacing.sm),
        TextField(
          controller: _nameController,
          decoration: _decoration('Name'),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: EchoDeskSpacing.sm),
        TextField(
          controller: _roleController,
          decoration: _decoration('Role'),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: EchoDeskSpacing.sm),
        DropdownButtonFormField<String?>(
          // ignore: deprecated_member_use -- value is the current selection
          value: _calendarId,
          decoration: _decoration('Google calendar'),
          isExpanded: true,
          items: calendarItems,
          onChanged: (v) => setState(() => _calendarId = v),
        ),
        if (widget.calendars.isEmpty) ...[
          const SizedBox(height: EchoDeskSpacing.xs),
          Text(
            'Connect Google Calendar in Settings to pick a staff calendar.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: EchoDeskColors.muted,
                ),
          ),
        ],
        const SizedBox(height: EchoDeskSpacing.md),
        Row(
          children: [
            if (widget.canCancel)
              TextButton(
                onPressed: _saving ? null : widget.onCancel,
                child: const Text('Cancel'),
              ),
            const Spacer(),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save'),
            ),
          ],
        ),
      ],
    );
  }
}
