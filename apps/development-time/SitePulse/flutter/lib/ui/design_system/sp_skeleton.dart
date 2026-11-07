import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Placeholder list shown while a list loads (instead of a lone spinner), so
/// the page keeps its shape and the wait feels shorter.
///
/// A soft pulse runs unless the platform asks for reduced motion; screen
/// readers hear one "Yükleniyor" announcement instead of empty boxes.
class SpSkeletonList extends StatefulWidget {
  final int rows;
  final double rowHeight;

  const SpSkeletonList({super.key, this.rows = 3, this.rowHeight = 72});

  @override
  State<SpSkeletonList> createState() => _SpSkeletonListState();
}

class _SpSkeletonListState extends State<SpSkeletonList> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900), lowerBound: 0.45, upperBound: 1);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _pulse.stop();
      _pulse.value = 1;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fill = AppColors.border(context);
    Widget bar(double widthFactor, double height) => FractionallySizedBox(
          widthFactor: widthFactor,
          alignment: Alignment.centerLeft,
          child: Container(
            height: height,
            decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(6)),
          ),
        );
    return Semantics(
      label: 'Yükleniyor',
      liveRegion: true,
      excludeSemantics: true,
      child: FadeTransition(
        opacity: _pulse,
        child: Column(
          children: [
            for (var i = 0; i < widget.rows; i++)
              Container(
                height: widget.rowHeight,
                margin: const EdgeInsets.only(bottom: AppSpacing.md),
                padding: const EdgeInsets.all(AppSpacing.lg),
                decoration: BoxDecoration(
                  color: AppColors.surface(context),
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  border: Border.all(color: AppColors.border(context)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(AppRadius.control)),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [bar(0.6, 12), const SizedBox(height: AppSpacing.sm), bar(0.35, 10)],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
