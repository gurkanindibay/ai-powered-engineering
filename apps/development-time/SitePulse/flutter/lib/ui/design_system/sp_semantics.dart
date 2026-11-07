import 'package:flutter/widgets.dart';

/// Makes a custom tab, segment or filter chip announce itself to screen
/// readers as one button with its selected state ("Seçili"), the way the
/// Material `FilterChip`/`SegmentedButton` do.
Widget selectableSemantics({required bool selected, required Widget child}) {
  return MergeSemantics(
    child: Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: child,
    ),
  );
}
