import '../warehouse/tmc_model.dart';
import 'order_model.dart';

/// Returns whether the order can be launched from the orders list UI.
///
/// The UI only gates launching by assignment/status and available material.
/// Presence of a persisted stage queue is validated by OrdersProvider.launchOrder
/// so orders without a legacy [OrderModel.stageTemplateId] can still be
/// launched when their stages are saved in production plan tables.
bool canLaunchOrder(OrderModel order, Iterable<TmcModel> allTmc) {
  if (order.assignmentCreated ||
      order.statusEnum != OrderStatus.ready_to_start) {
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
