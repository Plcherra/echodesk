import 'package:flutter/material.dart';

import '../theme/echodesk_theme.dart';

/// Small pill showing an appointment's status (Confirmed, Needs Review,
/// Cancelled, Completed). Shared so the label looks identical everywhere
/// (dashboard cards + appointments list).
class StatusChip extends StatelessWidget {
  final String status;

  const StatusChip({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final (label, color, bgColor) = statusStyle(status);
    final fontSize = MediaQuery.textScalerOf(context)
        .clamp(minScaleFactor: 1.0, maxScaleFactor: 1.4)
        .scale(11)
        .clamp(11.0, 16.0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(EchoDeskRadii.sm),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  /// (label, foreground, background) for a status string.
  static (String, Color, Color) statusStyle(String s) {
    switch (s) {
      case 'confirmed':
        return ('Confirmed', EchoDeskColors.success, EchoDeskColors.successSoft);
      case 'needs_review':
        return ('Needs Review', EchoDeskColors.warning, EchoDeskColors.warningSoft);
      case 'cancelled':
        return ('Cancelled', EchoDeskColors.danger, EchoDeskColors.dangerSoft);
      case 'completed':
        return ('Completed', EchoDeskColors.info, EchoDeskColors.infoSoft);
      default:
        return ('—', EchoDeskColors.muted, EchoDeskColors.surfaceMuted);
    }
  }
}
