import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

/// True only in builds made with `--dart-define=E2E=true` (GUI automation).
const bool kE2E = bool.fromEnvironment('E2E');

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
Widget testId(String id, Widget child) {
  if (!kE2E) return child;
  return Semantics(
    identifier: id,
    container: true,
    explicitChildNodes: true,
    child: child,
  );
}
