import '../orders/order_model.dart';

/// Returns whether an order should be shown in the production job management
/// module's main datasets.
///
/// Production keeps active orders and finished-but-not-yet-shipped orders so
/// they can be reviewed before shipment. Once shipment is registered, the order
/// leaves the production lists entirely.
bool isOrderVisibleInProductionJobs(OrderModel order) {
  if (order.statusEnum == OrderStatus.in_production) return true;
  if (order.statusEnum != OrderStatus.completed) return false;
  return !order.isShipped;
}
