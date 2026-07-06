import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Synchronizes horizontal scroll position across multiple [ScrollController]s.
///
/// Create one per table via the [HScrollSync] constructor, call [acquire] to
/// get a linked controller for each header/row/footer section, and call
/// [dispose] when the owning [State] is disposed.
///
/// Data rows that only need to follow the offset (without owning a scrollable)
/// can listen to [offsetNotifier] and translate their content — one listener
/// per table instead of a controller per row.
class HScrollSync {
  final ValueNotifier<double> _offset = ValueNotifier<double>(0.0);
  bool _syncing = false;
  final _controllers = <ScrollController>[];

  /// Current synchronized horizontal offset. Updated on every scroll of any
  /// acquired controller.
  ValueListenable<double> get offsetNotifier => _offset;

  ScrollController acquire() {
    final ctrl = ScrollController(initialScrollOffset: _offset.value);
    ctrl.addListener(() => _onControllerScrolled(ctrl));
    _controllers.add(ctrl);
    return ctrl;
  }

  void _onControllerScrolled(ScrollController source) {
    if (_syncing || !source.hasClients) return;
    final newOffset = source.offset;
    if ((newOffset - _offset.value).abs() < 0.5) return;
    _offset.value = newOffset;
    _syncing = true;
    for (final c in _controllers) {
      if (c == source || !c.hasClients) continue;
      if ((c.offset - newOffset).abs() > 0.5) c.jumpTo(newOffset);
    }
    _syncing = false;
  }

  void dispose() {
    for (final c in _controllers) c.dispose();
    _controllers.clear();
    _offset.dispose();
  }
}
