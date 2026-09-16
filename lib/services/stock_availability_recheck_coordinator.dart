import 'dart:async';

typedef StockAvailabilityRecheck = Future<void> Function();

/// Connects committed stock-changing commands to the existing order
/// availability calculation.
///
/// Realtime must never call this coordinator: realtime consumers only refresh
/// local projections. Calls are serialized so that every successful canonical
/// stock command gets exactly one post-commit calculation, even when commands
/// overlap.
class StockAvailabilityRecheckCoordinator {
  StockAvailabilityRecheckCoordinator();

  static final StockAvailabilityRecheckCoordinator instance =
      StockAvailabilityRecheckCoordinator();

  Object? _owner;
  StockAvailabilityRecheck? _handler;
  Future<void> _tail = Future<void>.value();

  void register({
    required Object owner,
    required StockAvailabilityRecheck handler,
  }) {
    _owner = owner;
    _handler = handler;
  }

  void unregister(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _handler = null;
  }

  Future<void> afterCommittedStockMutation() {
    final handler = _handler;
    if (handler == null) return Future<void>.value();

    final next = _tail.catchError((Object _) {}).then<void>((_) => handler());
    _tail = next;
    return next;
  }
}
