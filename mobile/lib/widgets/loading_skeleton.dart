import 'package:flutter/material.dart';

/// Shimmer skeleton for loading states.
class LoadingSkeleton extends StatelessWidget {
  final double width;
  final double height;
  final double borderRadius;

  const LoadingSkeleton({
    super.key,
    this.width = double.infinity,
    this.height = 16,
    this.borderRadius = 4,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
    );
  }
}

/// Card-shaped skeleton for list items.
class SkeletonCard extends StatelessWidget {
  final bool showSubtitle;
  final bool showTrailing;

  const SkeletonCard({
    super.key,
    this.showSubtitle = true,
    this.showTrailing = true,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: LoadingSkeleton(
                    width: 120,
                    height: 14,
                    borderRadius: 4,
                  ),
                ),
                if (showTrailing)
                  LoadingSkeleton(
                    width: 48,
                    height: 14,
                    borderRadius: 4,
                  ),
              ],
            ),
            if (showSubtitle) ...[
              const SizedBox(height: 8),
              LoadingSkeleton(
                width: double.infinity,
                height: 12,
                borderRadius: 4,
              ),
              const SizedBox(height: 4),
              LoadingSkeleton(
                width: 180,
                height: 12,
                borderRadius: 4,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shared list-loading pattern: a few skeleton cards instead of a lone spinner.
class ListLoadingView extends StatelessWidget {
  final int itemCount;
  final EdgeInsetsGeometry padding;

  const ListLoadingView({
    super.key,
    this.itemCount = 4,
    this.padding = const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: padding,
      children: List.generate(itemCount, (_) => const SkeletonCard()),
    );
  }
}
