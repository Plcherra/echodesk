import 'package:flutter/material.dart';

import '../constants/layout.dart';

/// Wraps scaffold body content in a centered, max-width container for tablet/web/desktop.
/// On narrow screens (phone), content uses full width. On wide screens, content is
/// centered with [LayoutConstants.maxContentWidth].
Widget constrainedScaffoldBody({
  required Widget child,
  EdgeInsets? padding,
  double maxWidth = LayoutConstants.maxContentWidth,
}) {
  return LayoutBuilder(
    builder: (context, constraints) {
      final useConstraint = constraints.maxWidth > maxWidth;
      return Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: useConstraint ? maxWidth : double.infinity,
          ),
          child:
              padding != null ? Padding(padding: padding, child: child) : child,
        ),
      );
    },
  );
}
