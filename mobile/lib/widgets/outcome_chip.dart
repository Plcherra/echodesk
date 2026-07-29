import 'package:flutter/material.dart';

import '../theme/echodesk_theme.dart';

/// Call-outcome pill (Booked, Completed, Short Call, Missed).
/// Shared across call history, receptionist detail, and call detail.
class OutcomeChip extends StatelessWidget {
  final String label;

  /// Slightly larger chip for detail headers.
  final bool prominent;

  const OutcomeChip({
    super.key,
    required this.label,
    this.prominent = false,
  });

  @override
  Widget build(BuildContext context) {
    final (color, bgColor) = colorsForOutcome(label);
    final baseSize = prominent ? 13.0 : 11.0;
    final fontSize = MediaQuery.textScalerOf(context)
        .clamp(minScaleFactor: 1.0, maxScaleFactor: 1.4)
        .scale(baseSize)
        .clamp(11.0, 18.0);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: prominent ? 10 : 8,
        vertical: prominent ? 4 : 2,
      ),
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

  static (Color, Color) colorsForOutcome(String label) {
    switch (label) {
      case 'Booked':
        return (EchoDeskColors.success, EchoDeskColors.successSoft);
      case 'Completed':
        return (EchoDeskColors.info, EchoDeskColors.infoSoft);
      case 'Short Call':
        return (EchoDeskColors.warning, EchoDeskColors.warningSoft);
      case 'Missed':
        return (EchoDeskColors.danger, EchoDeskColors.dangerSoft);
      default:
        return (EchoDeskColors.muted, EchoDeskColors.surfaceMuted);
    }
  }
}
