import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Shared UI defaults that avoid transient framework assertions from visual
/// effects whose owner widget can be removed during fast navigation/rebuilds.
///
/// Keep accessibility-affecting widgets (for example [Tooltip], [SnackBar],
/// [FocusNode], and [Semantics]) enabled by default. If a specific control
/// needs investigation, gate that control locally with an explicit diagnostic
/// flag instead of changing global theme behavior.
final ThemeData appTheme = ThemeData(
  splashFactory: NoSplash.splashFactory,
  splashColor: Colors.transparent,
  highlightColor: Colors.transparent,
);

/// Some Flutter builds can still finish a paint/build pass for an ink feature
/// or tooltip overlay after the source render box has already been detached.
/// These assertions are produced by framework-only visual affordances and can
/// otherwise flood logs with repeated "Another exception was thrown" messages.
bool isTransientFlutterVisualAssertion(FlutterErrorDetails details) {
  final exceptionText = details.exceptionAsString();
  return exceptionText.contains("'referenceBox.attached': is not true") ||
      exceptionText.contains("'!_skipMarkNeedsLayout': is not true");
}
