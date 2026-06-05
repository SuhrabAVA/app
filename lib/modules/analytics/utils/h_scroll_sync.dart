import 'package:flutter/widgets.dart';

/// Synchronizes horizontal scroll position across multiple [ScrollController]s.
///
/// Create one per table via the [HScrollSync] constructor, call [acquire] to
/// get a linked controller for each header/row/footer section, and call
/// [dispose] when the owning [State] is disposed.
class HScrollSync {
  double _offset = 0.0;
  bool _syncing = false;
  final _controllers = <ScrollController>[];

  ScrollController acquire() {
    final ctrl = ScrollController(initialScrollOffset: _offset);
    ctrl.addListener(() => _onControllerScrolled(ctrl));
    _controllers.add(ctrl);
    return ctrl;
  }

  void _onControllerScrolled(ScrollController source) {
    if (_syncing || !source.hasClients) return;
    final newOffset = source.offset;
    if ((newOffset - _offset).abs() < 0.5) return;
    _offset = newOffset;
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
  }
}
