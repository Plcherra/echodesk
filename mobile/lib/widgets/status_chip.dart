import 'package:flutter/material.dart';

/// Small pill showing an appointment's status (Confirmed, Needs Review,
/// Cancelled, Completed). Shared so the label looks identical everywhere
/// (dashboard cards + appointments list).
class StatusChip extends StatelessWidget {
  final String status;

  const StatusChip({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final (label, color, bgColor) = statusStyle(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style:
            TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  /// (label, foreground, background) for a status string.
  static (String, Color, Color) statusStyle(String s) {
    switch (s) {
      case 'confirmed':
        return ('Confirmed', Colors.green.shade800, Colors.green.shade100);
      case 'needs_review':
        return ('Needs Review', Colors.orange.shade800, Colors.orange.shade100);
      case 'cancelled':
        return ('Cancelled', Colors.red.shade800, Colors.red.shade100);
      case 'completed':
        return ('Completed', Colors.blue.shade800, Colors.blue.shade100);
      default:
        return ('—', Colors.grey.shade700, Colors.grey.shade200);
    }
  }
}
