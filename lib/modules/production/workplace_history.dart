import '../orders/order_model.dart';
import '../tasks/task_model.dart';

/// Заказ, уже пройденный рабочим местом, — строка ленты «История».
class WorkplaceHistoryEntry {
  const WorkplaceHistoryEntry({
    required this.order,
    required this.doneAt,
    required this.stageIds,
  });

  final OrderModel order;

  /// Когда рабочее место закончило с этим заказом, мс эпохи.
  final int doneAt;

  /// Рабочие места, чьи этапы этого заказа закрыты (для подписи строки).
  final List<String> stageIds;
}

/// Сколько заказов держим в ленте. Больше не нужно: история здесь — чтобы
/// вернуться к тому, что только что сдал, а не заменять архив заказов.
const int kWorkplaceHistoryLimit = 10;

/// Когда задача была закрыта, мс эпохи, или null если следов не осталось.
///
/// `tasks.completed_at` появился позже самих задач, и у закрытых до миграции
/// он пустой. Поэтому вторым источником берём последний комментарий: этап
/// закрывается с комментарием (количество, пропуск, проблема), и его отметка
/// времени показывает момент закрытия достаточно точно для сортировки.
int? taskDoneAt(TaskModel task) {
  final completedAt = task.completedAt;
  if (completedAt != null && completedAt > 0) return completedAt;
  int? latestComment;
  for (final comment in task.comments) {
    final ts = comment.timestamp;
    if (ts <= 0) continue;
    if (latestComment == null || ts > latestComment) latestComment = ts;
  }
  return latestComment;
}

/// Последние заказы, пройденные рабочим местом [workplaceId], — новые сверху.
///
/// Берём завершённые задачи именно этого рабочего места, а не заказы целиком:
/// печатник должен видеть то, что напечатал, даже если заказ ещё идёт дальше
/// по маршруту или уже отгружен.
List<WorkplaceHistoryEntry> workplaceHistory({
  required String workplaceId,
  required Iterable<OrderModel> orders,
  required Iterable<TaskModel> tasks,
  int limit = kWorkplaceHistoryLimit,
}) {
  final id = workplaceId.trim();
  if (id.isEmpty) return const <WorkplaceHistoryEntry>[];

  final doneByOrder = <String, int>{};
  final stagesByOrder = <String, List<String>>{};
  for (final task in tasks) {
    if (task.status != TaskStatus.completed) continue;
    final belongs = task.stageId.trim() == id ||
        (task.capturedByWorkplaceId?.trim() ?? '') == id;
    if (!belongs) continue;
    final orderId = task.orderId.trim();
    if (orderId.isEmpty) continue;
    final at = taskDoneAt(task) ?? 0;
    final current = doneByOrder[orderId];
    if (current == null || at > current) doneByOrder[orderId] = at;
    final stages = stagesByOrder.putIfAbsent(orderId, () => <String>[]);
    if (!stages.contains(task.stageId.trim())) stages.add(task.stageId.trim());
  }

  return _sortedEntries(orders, doneByOrder, stagesByOrder, limit);
}

/// Последние полностью пройденные заказы — для вкладок «Все» и «Завершенные»,
/// где конкретного рабочего места нет.
List<WorkplaceHistoryEntry> completedOrdersHistory({
  required Iterable<OrderModel> orders,
  required Iterable<TaskModel> tasks,
  int limit = kWorkplaceHistoryLimit,
}) {
  final tasksByOrder = <String, List<TaskModel>>{};
  for (final task in tasks) {
    final orderId = task.orderId.trim();
    if (orderId.isEmpty) continue;
    tasksByOrder.putIfAbsent(orderId, () => <TaskModel>[]).add(task);
  }

  final doneByOrder = <String, int>{};
  final stagesByOrder = <String, List<String>>{};
  for (final entry in tasksByOrder.entries) {
    final orderTasks = entry.value;
    if (orderTasks.isEmpty) continue;
    if (orderTasks.any((task) => task.status != TaskStatus.completed)) continue;
    var latest = 0;
    final stages = <String>[];
    for (final task in orderTasks) {
      final at = taskDoneAt(task) ?? 0;
      if (at > latest) latest = at;
      final stageId = task.stageId.trim();
      if (stageId.isNotEmpty && !stages.contains(stageId)) stages.add(stageId);
    }
    doneByOrder[entry.key] = latest;
    stagesByOrder[entry.key] = stages;
  }

  return _sortedEntries(orders, doneByOrder, stagesByOrder, limit);
}

List<WorkplaceHistoryEntry> _sortedEntries(
  Iterable<OrderModel> orders,
  Map<String, int> doneByOrder,
  Map<String, List<String>> stagesByOrder,
  int limit,
) {
  final entries = <WorkplaceHistoryEntry>[];
  for (final order in orders) {
    final at = doneByOrder[order.id.trim()];
    if (at == null) continue;
    entries.add(WorkplaceHistoryEntry(
      order: order,
      // Задача без отметки времени и без комментариев всё равно должна попасть
      // в ленту — просто в самый её конец, а не выпасть совсем.
      doneAt: at,
      stageIds: stagesByOrder[order.id.trim()] ?? const <String>[],
    ));
  }
  entries.sort((a, b) => b.doneAt.compareTo(a.doneAt));
  if (entries.length <= limit) return entries;
  return entries.sublist(0, limit);
}
