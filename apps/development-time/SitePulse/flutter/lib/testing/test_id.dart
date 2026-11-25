import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

/// True only in builds made with `--dart-define=E2E=true` (GUI automation).
const bool kE2E = bool.fromEnvironment('E2E');

/// Developer-only controls (offline simulator, demo personas, quick login).
/// Shown in debug and E2E builds, or with `--dart-define=SITEPULSE_DEV_TOOLS=true`;
/// hidden in release builds that real residents use.
const bool kShowDevTools = kE2E || kDebugMode || bool.fromEnvironment('SITEPULSE_DEV_TOOLS');

/// Turns on the semantics tree so Flutter web renders DOM nodes that a
/// browser automation tool (Playwright) can find. No-op outside E2E builds.
void enableE2ESemantics() {
  if (kE2E) {
    SemanticsBinding.instance.ensureSemantics();
  }
}

/// Tags [child] with a stable automation id.
///
/// In E2E builds Flutter web renders it as the DOM attribute
/// `flt-semantics-identifier="<id>"`. Use the same string as the widget's
/// `Key` where one exists, so widget tests and browser tests share one name.
/// Outside E2E builds the child is returned unchanged, so production
/// semantics (screen readers) are not affected.
///
/// [label] exposes a value the widget itself does not put in the semantics
/// tree (e.g. `SelectableText`, which renders as an empty text area), so a
/// test can read it from the node's `aria-label`.
Widget testId(
  String id,
  Widget child, {
  String? label,
  bool? enabled,
  bool? button,
  VoidCallback? onTap,
}) {
  if (!kE2E) return child;
  return Semantics(
    identifier: id,
    label: label,
    enabled: enabled,
    button: button,
    onTap: onTap,
    container: true,
    explicitChildNodes: true,
    child: child,
  );
}
