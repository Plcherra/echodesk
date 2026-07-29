import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../theme/echodesk_theme.dart';

class ReceptionistStaffTab extends StatefulWidget {
  final String receptionistId;

  const ReceptionistStaffTab({super.key, required this.receptionistId});

  @override
  State<ReceptionistStaffTab> createState() => _ReceptionistStaffTabState();
}

class _ReceptionistStaffTabState extends State<ReceptionistStaffTab> {
  List<Map<String, dynamic>> _staff = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final res = await Supabase.instance.client
        .from('staff')
        .select('id, name, role')
        .eq('receptionist_id', widget.receptionistId)
        .order('name');
    setState(() {
      _staff = (res as List).cast<Map<String, dynamic>>();
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.all(EchoDeskSpacing.lg),
      children: [
        Text(
          'Staff members for this receptionist.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: EchoDeskColors.muted,
              ),
        ),
        const SizedBox(height: EchoDeskSpacing.md),
        _AddStaffForm(
          receptionistId: widget.receptionistId,
          onAdded: _load,
        ),
        const SizedBox(height: EchoDeskSpacing.md),
        ..._staff.map((s) => Card(
              margin: const EdgeInsets.only(bottom: 6),
              child: ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                title: Text(
                  s['name'] ?? '',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                subtitle: Text(
                  s['role'] ?? '',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: EchoDeskColors.muted,
                      ),
                ),
                trailing: IconButton(
                  icon:
                      Icon(Icons.delete_outline, color: EchoDeskColors.danger),
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
                      _load();
                    }
                  },
                ),
              ),
            )),
      ],
    );
  }
}

class _AddStaffForm extends StatefulWidget {
  final String receptionistId;
  final VoidCallback onAdded;

  const _AddStaffForm({
    required this.receptionistId,
    required this.onAdded,
  });

  @override
  State<_AddStaffForm> createState() => _AddStaffFormState();
}

class _AddStaffFormState extends State<_AddStaffForm> {
  final _nameController = TextEditingController();
  final _roleController = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    _roleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Name',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _roleController,
            decoration: const InputDecoration(
              labelText: 'Role',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _saving
              ? null
              : () async {
                  final name = _nameController.text.trim();
                  if (name.isEmpty) return;
                  setState(() => _saving = true);
                  await Supabase.instance.client.from('staff').insert({
                    'receptionist_id': widget.receptionistId,
                    'name': name,
                    'role': _roleController.text.trim().isEmpty
                        ? null
                        : _roleController.text.trim(),
                  });
                  _nameController.clear();
                  _roleController.clear();
                  setState(() => _saving = false);
                  widget.onAdded();
                },
          child: const Text('Add'),
        ),
      ],
    );
  }
}

