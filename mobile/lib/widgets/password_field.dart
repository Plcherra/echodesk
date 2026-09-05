import 'package:flutter/material.dart';

import '../auth/password_policy.dart';

/// Password input with a compact show/hide control.
/// Set [requireStrong] on signup and reset to show live requirements.
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    this.labelText = 'Password',
    this.requireStrong = false,
    this.validator,
    this.textInputAction,
    this.onFieldSubmitted,
  });

  final TextEditingController controller;
  final String labelText;
  final bool requireStrong;
  final FormFieldValidator<String>? validator;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onFieldSubmitted;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    if (widget.requireStrong) {
      widget.controller.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    if (widget.requireStrong) {
      widget.controller.removeListener(_onChanged);
    }
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final password = widget.controller.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: widget.controller,
          obscureText: !_visible,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: widget.textInputAction,
          onFieldSubmitted: widget.onFieldSubmitted,
          decoration: InputDecoration(
            labelText: widget.labelText,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: _visible ? 'Hide password' : 'Show password',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              iconSize: 20,
              onPressed: () => setState(() => _visible = !_visible),
              icon: Icon(
                _visible
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
            ),
          ),
          validator: widget.validator ??
              (widget.requireStrong
                  ? PasswordPolicy.validate
                  : (v) => (v == null || v.isEmpty) ? 'Required' : null),
        ),
        if (widget.requireStrong) ...[
          const SizedBox(height: 10),
          Text(
            'Password must include:',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 6),
          ...PasswordPolicy.requirements.map(
            (rule) => _RequirementRow(
              label: rule.label,
              met: rule.met(password),
            ),
          ),
        ],
      ],
    );
  }
}

class _RequirementRow extends StatelessWidget {
  const _RequirementRow({required this.label, required this.met});

  final String label;
  final bool met;

  @override
  Widget build(BuildContext context) {
    final color = met
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(
            met ? Icons.check_circle : Icons.circle_outlined,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: color,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
