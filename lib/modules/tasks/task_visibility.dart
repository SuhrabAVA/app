import '../orders/order_model.dart';

/// Returns whether a task may be displayed in an employee workspace.
///
/// Task rows can already exist for orders that were saved/prepared but not yet
/// launched into production. The workspace should only expose tasks once the
/// order is considered launched. If the order is not available locally yet, the
/// caller may keep the task visible to avoid hiding data during provider loading.
bool isTaskOrderLaunchedForWorkspace(OrderModel? order) {
  if (order == null) return true;
  return order.assignmentCreated ||
      order.statusEnum == OrderStatus.in_production;
}
