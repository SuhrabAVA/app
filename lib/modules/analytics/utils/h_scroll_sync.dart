import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
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
  bool _disposed = false;
  bool _postFrameScheduled = false;
  double? _pendingOffset;
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
    // ScrollPosition умеет уведомлять листенеры прямо из layout-фазы
    // (клампинг offset в applyContentDimensions при изменении ширины).
    // Синхронная реакция в этот момент — markNeedsBuild у
    // ValueListenableBuilder'ов и jumpTo() по соседним viewport'ам посреди
    // layout: '!_debugDoingThisLayout' / «RenderBox was not laid out».
    // Поэтому из layout/paint-фазы синхронизацию откладываем на конец кадра.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      _pendingOffset = newOffset;
      if (!_postFrameScheduled) {
        _postFrameScheduled = true;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          _postFrameScheduled = false;
          final pending = _pendingOffset;
          _pendingOffset = null;
          if (_disposed || pending == null) return;
          _applyOffset(pending);
        });
      }
      return;
    }
    _applyOffset(newOffset, except: source);
  }

  void _applyOffset(double offset, {ScrollController? except}) {
    if ((offset - _offset.value).abs() < 0.5) return;
    _offset.value = offset;
    _syncing = true;
    for (final c in _controllers) {
      if (c == except || !c.hasClients) continue;
      if ((c.offset - offset).abs() < 0.5) continue;
      c.jumpTo(offset);
    }
    _syncing = false;
  }

  void dispose() {
    _disposed = true;
    for (final c in _controllers) {
      c.dispose();
    }
    _controllers.clear();
    _offset.dispose();
  }
}
