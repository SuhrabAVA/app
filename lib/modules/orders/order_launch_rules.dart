import '../warehouse/tmc_model.dart';
import 'order_model.dart';

/// Returns whether the order can be launched from the orders list UI.
///
/// The UI gates launching by assignment/status, queue build state, and
/// available material. OrdersProvider.launchOrder repeats the queue check
/// against persisted data before creating tasks.
bool canLaunchOrder(OrderModel order, Iterable<TmcModel> allTmc) {
  if (order.assignmentCreated ||
      order.statusEnum != OrderStatus.ready_to_start ||
      QueueBuildStatus.normalize(order.queueBuildStatus) !=
          QueueBuildStatus.built) {
    return false;
  }

  final String? materialId = order.material?.id;
  final double requiredLength = (order.product.length ?? 0).toDouble();
  if (materialId == null || materialId.isEmpty || requiredLength <= 0) {
    return true;
  }

  final matches = allTmc.where((t) => t.id == materialId).toList();
  if (matches.isEmpty) return false;
  return matches.first.quantity >= requiredLength;
}
