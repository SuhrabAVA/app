import '../../orders/order_model.dart';
import '../../tasks/task_model.dart';
import '../models/analytics_event.dart';
import '../models/analytics_month.dart';

/// Превращает `tasks.comments` в сырой поток `AnalyticsEvent`.
///
/// Источники:
///  - TaskTimeEvent (тип comment == 'time_event'): время начала/окончания,
///    тип (production / pause / problem / setup), сотрудник, рабочее место,
///    задача и причина.
///  - quantity_done / quantity_team_total / quantity_share — количество
///    продукции, привязываемое к ближайшему завершившемуся work-событию
///    того же сотрудника на той же задаче.
///  - setup_done — количество приладки, привязываемое к ближайшему setup-
///    событию того же сотрудника на той же задаче.
class AnalyticsRepository {
  /// Готовит события на месяц.
  ///
  /// [tasks]      — все задачи проекта (TaskProvider.tasks)
  /// [ordersById] — карта заказов (для получения customer)
  /// [month]      — выбранный месяц
  /// [now]        — текущее время для расчёта активных событий
  List<AnalyticsEvent> buildEvents({
    required List<TaskModel> tasks,
    required Map<String, OrderModel> ordersById,
    required AnalyticsMonth month,
    DateTime? now,
  }) {
    final reference = now ?? DateTime.now();
    final monthFirst = month.firstDay;
    final monthEnd = month.nextMonthFirstDay;
    final events = <AnalyticsEvent>[];

    // 1. Сначала вытаскиваем все TaskTimeEvent из задач, группируя по (task,user).
    //    Параллельно собираем количество и наладки в очередь по той же группе.
    final Map<String, List<TaskTimeEvent>> rawEventsByGroup = {};
    final Map<String, List<_QtyRecord>> qtyRecordsByGroup = {};
    final Map<String, List<_QtyRecord>> setupRecordsByGroup = {};

    for (final task in tasks) {
      for (final comment in task.comments) {
        final type = comment.type;
        if (type == 'time_event') {
          final ev = TaskTimeEvent.fromPayload(
            comment.text,
            comment.id,
            comment.timestamp,
            comment.userId,
          );
          if (ev == null) continue;
          // оставляем только события, попадающие в месяц
          if (!_overlapsMonth(ev.startTime, ev.endTime, monthFirst, monthEnd)) {
            continue;
          }
          final groupKey = '${task.id}::${ev.subjectUserId}';
          rawEventsByGroup.putIfAbsent(groupKey, () => []).add(ev);
        } else if (type == 'quantity_done' ||
            type == 'quantity_team_total' ||
            type == 'quantity_share') {
          final qty = _parseQty(comment.text);
          if (qty <= 0) continue;
          final ts = DateTime.fromMillisecondsSinceEpoch(
              comment.timestamp,
              isUtc: true);
          if (ts.isBefore(monthFirst) || !ts.isBefore(monthEnd)) continue;
          final groupKey = '${task.id}::${comment.userId}';
          qtyRecordsByGroup.putIfAbsent(groupKey, () => []).add(
                _QtyRecord(timestamp: ts, qty: qty),
              );
        } else if (type == 'setup_done') {
          final qty = _parseQty(comment.text);
          // приладка может быть «штучной» — учитываем как 1, если qty не задано
          final double setupQty = qty > 0 ? qty : 1.0;
          final ts = DateTime.fromMillisecondsSinceEpoch(
              comment.timestamp,
              isUtc: true);
          if (ts.isBefore(monthFirst) || !ts.isBefore(monthEnd)) continue;
          final groupKey = '${task.id}::${comment.userId}';
          setupRecordsByGroup.putIfAbsent(groupKey, () => []).add(
                _QtyRecord(timestamp: ts, qty: setupQty),
              );
        }
        // claim создаётся отдельной таблицей; здесь не обрабатывается.
      }
    }

    // 2. Преобразуем каждую группу в AnalyticsEvent'ы и привязываем qty.
    rawEventsByGroup.forEach((groupKey, list) {
      // task/user id
      final parts = groupKey.split('::');
      final taskId = parts.isNotEmpty ? parts[0] : '';
      final employeeId = parts.length > 1 ? parts[1] : '';

      // Находим саму задачу — она нужна для orderId и workplaceId fallback.
      TaskModel? task;
      try {
        task = tasks.firstWhere((t) => t.id == taskId);
      } catch (_) {
        task = null;
      }
      final orderId = task?.orderId ?? '';
      final order = ordersById[orderId];
      final customer = order?.customer;

      // Сортируем raw events по времени старта.
      list.sort((a, b) => a.startTime.compareTo(b.startTime));

      // Подготовим очереди qty/setup, отсортированные по времени.
      final qtyQueue = List<_QtyRecord>.from(qtyRecordsByGroup[groupKey] ?? const [])
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      final setupQueue = List<_QtyRecord>.from(setupRecordsByGroup[groupKey] ?? const [])
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

      for (final raw in list) {
        final type = _mapType(raw.type);
        if (type == null) continue;

        final isActive = raw.endTime == null;
        final effectiveEnd = raw.endTime ?? reference;

        double qty = 0;
        double setupQty = 0;

        if (type == AnalyticsEventType.work) {
          // Берём все qty-записи в пределах [start, end].
          while (qtyQueue.isNotEmpty &&
              !qtyQueue.first.timestamp.isAfter(effectiveEnd)) {
            final rec = qtyQueue.removeAt(0);
            if (rec.timestamp.isBefore(raw.startTime)) continue;
            qty += rec.qty;
          }
        } else if (type == AnalyticsEventType.setup) {
          while (setupQueue.isNotEmpty &&
              !setupQueue.first.timestamp.isAfter(effectiveEnd)) {
            final rec = setupQueue.removeAt(0);
            if (rec.timestamp.isBefore(raw.startTime)) continue;
            setupQty += rec.qty;
          }
        }

        events.add(AnalyticsEvent(
          id: raw.id,
          type: type,
          startTime: raw.startTime.toLocal(),
          endTime: raw.endTime?.toLocal(),
          employeeId: employeeId,
          workplaceId: raw.workplaceId.isNotEmpty
              ? raw.workplaceId
              : (task?.stageId ?? ''),
          taskId: taskId,
          orderId: orderId,
          customer: customer,
          note: raw.note,
          qty: qty,
          setupQty: setupQty,
          isActive: isActive,
        ));
      }

      // Если qty или setup остались «висящими» (нет привязанного work-события),
      // оставим их без события — они не повлияют на timeline, но смогут
      // быть подсчитаны в общих агрегатах через TaskProvider напрямую.
    });

    // 3. Сортируем итоговый список по времени.
    events.sort((a, b) => a.startTime.compareTo(b.startTime));
    return events;
  }

  static AnalyticsEventType? _mapType(TaskTimeType raw) {
    switch (raw) {
      case TaskTimeType.production:
        return AnalyticsEventType.work;
      case TaskTimeType.pause:
        return AnalyticsEventType.pause;
      case TaskTimeType.problem:
        return AnalyticsEventType.problem;
      case TaskTimeType.setup:
        return AnalyticsEventType.setup;
      case TaskTimeType.shiftChange:
        return null;
    }
  }

  static bool _overlapsMonth(
      DateTime start, DateTime? end, DateTime monthFirst, DateTime monthEnd) {
    final endEffective = end ?? DateTime.now();
    // overlap, если start < monthEnd && end >= monthFirst
    return start.toLocal().isBefore(monthEnd) &&
        !endEffective.toLocal().isBefore(monthFirst);
  }

  static double _parseQty(String raw) {
    final normalized = raw.replaceAll(',', '.').trim();
    final match =
        RegExp(r'-?[0-9]+(?:\.[0-9]+)?').firstMatch(normalized);
    if (match != null) {
      return double.tryParse(match.group(0)!) ?? 0;
    }
    return double.tryParse(normalized) ?? 0;
  }
}

class _QtyRecord {
  final DateTime timestamp;
  final double qty;
  const _QtyRecord({required this.timestamp, required this.qty});
}
