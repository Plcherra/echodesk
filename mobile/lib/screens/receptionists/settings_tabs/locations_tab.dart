import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../services/api_client.dart';
import '../../../theme/echodesk_theme.dart';

class ReceptionistLocationsTab extends StatefulWidget {
  final String receptionistId;

  const ReceptionistLocationsTab({super.key, required this.receptionistId});

  @override
  State<ReceptionistLocationsTab> createState() =>
      _ReceptionistLocationsTabState();
}

class _ReceptionistLocationsTabState extends State<ReceptionistLocationsTab> {
  List<Map<String, dynamic>> _locations = [];
  List<_GoogleCalendarOption> _calendars = [];
  bool _loading = true;
  bool _showEditor = false;
  Map<String, dynamic>? _editing;
  Key _formKey = const ValueKey('new-location');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      Supabase.instance.client
          .from('locations')
          .select('id, name, address, notes, hours, calendar_id')
          .eq('receptionist_id', widget.receptionistId)
          .order('name'),
      _fetchCalendars(),
    ]);
    if (!mounted) return;
    final locs = (results[0] as List).cast<Map<String, dynamic>>();
    setState(() {
      _locations = locs;
      _calendars = results[1] as List<_GoogleCalendarOption>;
      _loading = false;
      if (locs.isEmpty) {
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

  void _openEditForm(Map<String, dynamic> location) {
    setState(() {
      _showEditor = true;
      _editing = location;
      _formKey = ValueKey(location['id']);
    });
  }

  void _closeEditor() {
    setState(() {
      if (_locations.isEmpty) {
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

  String _hoursText(Map<String, dynamic> loc) {
    final hours = loc['hours'];
    if (hours is Map && hours['text'] != null) {
      return hours['text'].toString();
    }
    return '';
  }

  String _calendarLabel(Map<String, dynamic> loc) {
    final id = (loc['calendar_id'] ?? '').toString().trim();
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

    final isEmpty = _locations.isEmpty;
    final showForm = _showEditor || isEmpty;
    final editing = _editing != null;
    final canCancel = !isEmpty || editing;

    return ListView(
      padding: const EdgeInsets.all(EchoDeskSpacing.lg),
      children: [
        Text(
          'Each store can use a different calendar in your connected Google account.',
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
              label: const Text('Add location'),
            ),
          ),
          const SizedBox(height: EchoDeskSpacing.md),
        ],
        if (showForm) ...[
          _LocationEditor(
            key: _formKey,
            receptionistId: widget.receptionistId,
            location: _editing,
            calendars: _calendars,
            canCancel: canCancel,
            onCancel: _closeEditor,
            onSaved: _onEditorSaved,
          ),
          const SizedBox(height: EchoDeskSpacing.md),
        ],
        ..._locations.map((l) {
          final subtitleParts = <String>[
            if ((l['address'] ?? '').toString().trim().isNotEmpty)
              l['address'].toString().trim(),
            if (_hoursText(l).isNotEmpty) _hoursText(l),
            _calendarLabel(l),
          ];
          return Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              onTap: () => _openEditForm(l),
              title: Text(
                l['name'] ?? '',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              subtitle: Text(
                subtitleParts.join(' · '),
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
                      title: const Text('Delete location?'),
                      content: Text(
                        'Remove "${l['name'] ?? 'this location'}"? This cannot be undone.',
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
                        .from('locations')
                        .delete()
                        .eq('id', l['id'])
                        .eq('receptionist_id', widget.receptionistId);
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          '"${l['name'] ?? 'Location'}" deleted',
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

class _LocationEditor extends StatefulWidget {
  final String receptionistId;
  final Map<String, dynamic>? location;
  final List<_GoogleCalendarOption> calendars;
  final bool canCancel;
  final VoidCallback onCancel;
  final Future<void> Function() onSaved;

  const _LocationEditor({
    super.key,
    required this.receptionistId,
    required this.location,
    required this.calendars,
    required this.canCancel,
    required this.onCancel,
    required this.onSaved,
  });

  @override
  State<_LocationEditor> createState() => _LocationEditorState();
}

class _LocationEditorState extends State<_LocationEditor> {
  late final TextEditingController _nameController;
  late final TextEditingController _addressController;
  late final TextEditingController _hoursController;
  late final TextEditingController _notesController;
  String? _calendarId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final loc = widget.location;
    _nameController = TextEditingController(text: loc?['name']?.toString() ?? '');
    _addressController =
        TextEditingController(text: loc?['address']?.toString() ?? '');
    final hours = loc?['hours'];
    final hoursText =
        hours is Map && hours['text'] != null ? hours['text'].toString() : '';
    _hoursController = TextEditingController(text: hoursText);
    _notesController =
        TextEditingController(text: loc?['notes']?.toString() ?? '');
    final existing = (loc?['calendar_id'] ?? '').toString().trim();
    _calendarId = existing.isEmpty ? null : existing;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _hoursController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  InputDecoration _decoration(String label, {String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      border: const OutlineInputBorder(),
      isDense: true,
    );
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || _saving) return;
    setState(() => _saving = true);

    final hoursText = _hoursController.text.trim();
    final payload = <String, dynamic>{
      'name': name,
      'address': _addressController.text.trim().isEmpty
          ? null
          : _addressController.text.trim(),
      'notes': _notesController.text.trim().isEmpty
          ? null
          : _notesController.text.trim(),
      'hours': hoursText.isEmpty ? null : {'text': hoursText},
      'calendar_id': (_calendarId ?? '').trim().isEmpty ? null : _calendarId,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };

    try {
      if (widget.location == null) {
        await Supabase.instance.client.from('locations').insert({
          ...payload,
          'receptionist_id': widget.receptionistId,
        });
      } else {
        await Supabase.instance.client
            .from('locations')
            .update(payload)
            .eq('id', widget.location!['id'])
            .eq('receptionist_id', widget.receptionistId);
      }
      if (!mounted) return;
      await widget.onSaved();
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save location')),
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
    // Keep current value selectable even if list failed to load.
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
          widget.location == null ? 'Add location' : 'Edit location',
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
          controller: _addressController,
          decoration: _decoration('Address'),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: EchoDeskSpacing.sm),
        TextField(
          controller: _hoursController,
          decoration: _decoration(
            'Hours',
            hint: 'e.g. Mon–Fri 9am–5pm',
          ),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: EchoDeskSpacing.sm),
        TextField(
          controller: _notesController,
          decoration: _decoration('Notes'),
          maxLines: 2,
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
            'Connect Google Calendar in Settings to pick a store calendar.',
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
