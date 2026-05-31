import 'package:flutter/material.dart';

import '../theme/echodesk_theme.dart';

class BrandMark extends StatelessWidget {
  const BrandMark({
    super.key,
    this.size = 36,
    this.radius = EchoDeskRadii.sm,
  });

  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.asset(
        'assets/icon/app_icon.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        alignment: Alignment.center,
        filterQuality: FilterQuality.high,
      ),
    );
  }
}

class BrandLockup extends StatelessWidget {
  const BrandLockup({
    super.key,
    this.markSize = 36,
    this.showName = true,
    this.centered = false,
  });

  final double markSize;
  final bool showName;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final children = [
      BrandMark(size: markSize),
      if (showName) ...[
        const SizedBox(width: 10),
        Text(
          'EchoDesk',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: EchoDeskColors.ink,
                fontWeight: FontWeight.w800,
              ),
        ),
      ],
    ];

    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment:
          centered ? MainAxisAlignment.center : MainAxisAlignment.start,
      children: children,
    );
  }
}
