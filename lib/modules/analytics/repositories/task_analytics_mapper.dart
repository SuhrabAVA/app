import '../../tasks/task_model.dart';
import '../models/analytics_event.dart';

/// A single flattened comment row from tasks.comments that is relevant to analytics.
class TaskCommentRow {
  final String id;
  final String type;
  final String text;
  final String userId;
  final DateTime timestamp;
  final String taskId;
  final String stageId;
  final String orderId;
  final String? capturedByWorkplaceId;
  final String? customer;

  const TaskCommentRow({
    required this.id,
    required this.type,
    required this.text,
    required this.userId,
    required this.timestamp,
    required this.taskId,
    required this.stageId,
    required this.orderId,
    this.capturedByWorkplaceId,
    this.customer,
  });
}

class _QtyRecord {
  final String key;
  final DateTime timestamp;
  final double qty;
  const _QtyRecord({required this.key, required this.timestamp, required this.qty});
}

class _MonthSpeedTotals {
  double qty = 0;
  int minutes = 0;
  void add({required double qty, required int minutes}) {
    this.qty += qty;
    this.minutes += minutes;
  }
}

/// Stateless mapper: converts flat TaskCommentRow list → AnalyticsEvent list.
///
/// Extracted from AnalyticsRepository to be independently testable.
/// Rules:
///   • Every quantity_done / quantity_share / quantity_team_total is counted exactly once.
///   • Quantities within a production interval are attached to that event.
///   • Quantities with no matching production interval create a 1-minute fallback work event.
///   • Deduplication uses comment id (or composite key when id is empty).
class TaskAnalyticsMapper {
  // ── Public API ──────────────────────────────────────────────────────────

  /// Build AnalyticsEvents for [currentRows] (comments within the target month).
  static List<AnalyticsEvent> buildEvents(
    List<TaskCommentRow> rows,
    DateTime monthStart,
    DateTime monthEnd,
    DateTime reference,
  ) {
    final events = <AnalyticsEvent>[];

    final rawEventsByGroup = <String, List<TaskTimeEvent>>{};
    final qtyRecordsByGroup = <String, List<_QtyRecord>>{};
    final setupRecordsByGroup = <String, List<_QtyRecord>>{};
    final workplaceByTask = <String, String>{};
    final metaByTask = <String, TaskCommentRow>{};
    final seenQtyKeys = <String>{};

    for (final row in rows) {
      final taskId = row.taskId;
      if (taskId.isEmpty) continue;

      metaByTask[taskId] = row;

      // Best workplace resolution: capturedByWorkplaceId → stageId
      workplaceByTask.putIfAbsent(
        taskId,
        () => row.capturedByWorkplaceId?.isNotEmpty == true
            ? row.capturedByWorkplaceId!
            : row.stageId,
      );

      final type = row.type;

      if (type == 'time_event') {
        final ev = TaskTimeEvent.fromPayload(
          row.text,
          row.id,
          row.timestamp.millisecondsSinceEpoch,
          row.userId,
        );
        if (ev == null) continue;
        final normalized = _normalizeTimeRange(ev.startTime, ev.endTime, reference);
        if (normalized == null) continue;
        if (!_overlapsMonth(normalized.$1, normalized.$2, monthStart, monthEnd)) continue;

        // time_event.workplaceId overrides if non-empty
        if (ev.workplaceId.isNotEmpty) {
          workplaceByTask[taskId] = ev.workplaceId;
        }

        rawEventsByGroup
            .putIfAbsent('$taskId::${ev.subjectUserId}', () => [])
            .add(ev.copyWith(startTime: normalized.$1, endTime: normalized.$2));
      } else {
        final qty = _parseQty(row.text);
        final qtyKey = _makeQtyKey(row, taskId);
        if (seenQtyKeys.contains(qtyKey)) continue; // dedup
        seenQtyKeys.add(qtyKey);

        final groupKey = '$taskId::${row.userId}';
        if (type == 'setup_done') {
          // Явный маркер «приладок: N» (пишется при завершении наладки по
          // режиму рабочего места) имеет приоритет и принимает 0 — «размеры
          // совпали, переналадка не потребовалась». Старые комментарии без
          // маркера — легаси-поведение: 1 приладка.
          final explicit = _parseSetupCount(row.text);
          setupRecordsByGroup.putIfAbsent(groupKey, () => []).add(_QtyRecord(
              key: qtyKey,
              timestamp: row.timestamp,
              qty: explicit ?? (qty > 0 ? qty : 1.0)));
        } else if ((type == 'quantity_done' ||
                type == 'quantity_team_total' ||
                type == 'quantity_share') &&
            qty > 0) {
          qtyRecordsByGroup
              .putIfAbsent(groupKey, () => [])
              .add(_QtyRecord(key: qtyKey, timestamp: row.timestamp, qty: qty));
        }
      }
    }

    rawEventsByGroup.forEach((groupKey, list) {
      final parts = groupKey.split('::');
      final taskId = parts.first;
      final employeeId = parts.length > 1 ? parts[1] : '';
      final meta = metaByTask[taskId];
      final workplaceId = workplaceByTask[taskId] ?? meta?.stageId ?? '';

      list.sort((a, b) => a.startTime.compareTo(b.startTime));

      final qtyQueue = List<_QtyRecord>.from(
          qtyRecordsByGroup[groupKey] ?? const <_QtyRecord>[])
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      final setupQueue = List<_QtyRecord>.from(
          setupRecordsByGroup[groupKey] ?? const <_QtyRecord>[])
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

      for (final raw in list) {
        final eventType = _mapType(raw.type);
        if (eventType == null) continue;
        final effectiveEnd = raw.endTime ?? reference;
        double qty = 0, setupQty = 0;

        if (eventType == AnalyticsEventType.work) {
          while (qtyQueue.isNotEmpty &&
              !qtyQueue.first.timestamp.isAfter(effectiveEnd)) {
            final rec = qtyQueue.removeAt(0);
            if (!rec.timestamp.isBefore(raw.startTime)) qty += rec.qty;
          }
        } else if (eventType == AnalyticsEventType.setup) {
          while (setupQueue.isNotEmpty &&
              !setupQueue.first.timestamp.isAfter(effectiveEnd)) {
            final rec = setupQueue.removeAt(0);
            if (!rec.timestamp.isBefore(raw.startTime)) setupQty += rec.qty;
          }
        }

        events.add(AnalyticsEvent(
          id: raw.id,
          type: eventType,
          startTime: raw.startTime.toLocal(),
          endTime: raw.endTime?.toLocal(),
          employeeId: employeeId,
          workplaceId: raw.workplaceId.isNotEmpty ? raw.workplaceId : workplaceId,
          taskId: taskId,
          orderId: meta?.orderId ?? '',
          customer: meta?.customer,
          note: raw.note,
          qty: qty,
          setupQty: setupQty,
          isActive: raw.endTime == null,
        ));
      }

      // Fallback: any quantity not consumed by a production interval
      // creates a 1-minute work event so nothing is lost.
      while (qtyQueue.isNotEmpty) {
        final rec = qtyQueue.removeAt(0);
        if (rec.qty <= 0) continue;
        events.add(AnalyticsEvent(
          id: 'fallback:$groupKey:${rec.timestamp.millisecondsSinceEpoch}',
          type: AnalyticsEventType.work,
          startTime: rec.timestamp.toLocal(),
          endTime: rec.timestamp.add(const Duration(minutes: 1)).toLocal(),
          employeeId: employeeId,
          workplaceId: workplaceId,
          taskId: taskId,
          orderId: meta?.orderId ?? '',
          customer: meta?.customer,
          note: 'quantity_fallback',
          qty: rec.qty,
          setupQty: 0,
          isActive: false,
        ));
      }
    });

    // Second pass: groups that have quantities but NO time events at all.
    // These are shift-change or helper-removal quantities with no paired
    // production interval in the current month; each gets a 1-minute fallback.
    qtyRecordsByGroup.forEach((groupKey, records) {
      if (rawEventsByGroup.containsKey(groupKey)) return; // already handled above
      final parts = groupKey.split('::');
      final taskId = parts.first;
      final employeeId = parts.length > 1 ? parts[1] : '';
      final meta = metaByTask[taskId];
      final workplaceId = workplaceByTask[taskId] ?? meta?.stageId ?? '';
      for (final rec in records) {
        if (rec.qty <= 0) continue;
        events.add(AnalyticsEvent(
          id: 'fallback:$groupKey:${rec.timestamp.millisecondsSinceEpoch}',
          type: AnalyticsEventType.work,
          startTime: rec.timestamp.toLocal(),
          endTime: rec.timestamp.add(const Duration(minutes: 1)).toLocal(),
          employeeId: employeeId,
          workplaceId: workplaceId,
          taskId: taskId,
          orderId: meta?.orderId ?? '',
          customer: meta?.customer,
          note: 'quantity_fallback',
          qty: rec.qty,
          setupQty: 0,
          isActive: false,
        ));
      }
    });

    events.sort((a, b) => a.startTime.compareTo(b.startTime));
    return events;
  }

  /// Build workplace speed baselines from previous-month comment rows.
  static Map<String, List<double>> buildPreviousSpeeds(
    List<TaskCommentRow> rows,
    DateTime monthStart,
    DateTime reference,
  ) {
    final rawEventsByGroup = <String, List<TaskTimeEvent>>{};
    final qtyRecordsByGroup = <String, List<_QtyRecord>>{};
    final workplaceByTask = <String, String>{};
    final metaByTask = <String, TaskCommentRow>{};

    for (final row in rows) {
      final taskId = row.taskId;
      if (taskId.isEmpty) continue;
      metaByTask[taskId] = row;
      workplaceByTask.putIfAbsent(
        taskId,
        () => row.capturedByWorkplaceId?.isNotEmpty == true
            ? row.capturedByWorkplaceId!
            : row.stageId,
      );

      final type = row.type;
      if (type == 'time_event') {
        final ev = TaskTimeEvent.fromPayload(
          row.text, row.id,
          row.timestamp.millisecondsSinceEpoch, row.userId,
        );
        if (ev == null || ev.type != TaskTimeType.production) continue;
        final normalized = _normalizeTimeRange(ev.startTime, ev.endTime, reference);
        if (normalized == null) continue;
        final start = normalized.$1;
        final end = normalized.$2;
        if (!start.isBefore(monthStart) || end == null || end.isAfter(monthStart)) continue;
        if (ev.workplaceId.isNotEmpty) workplaceByTask[taskId] = ev.workplaceId;
        rawEventsByGroup
            .putIfAbsent('$taskId::${ev.subjectUserId}', () => [])
            .add(ev.copyWith(startTime: start, endTime: end));
      } else if (type == 'quantity_done' ||
          type == 'quantity_team_total' ||
          type == 'quantity_share') {
        final qty = _parseQty(row.text);
        if (qty <= 0) continue;
        final qtyKey = _makeQtyKey(row, taskId);
        qtyRecordsByGroup
            .putIfAbsent('$taskId::${row.userId}', () => [])
            .add(_QtyRecord(key: qtyKey, timestamp: row.timestamp, qty: qty));
      }
    }

    final totalsByWorkplace = <String, Map<DateTime, _MonthSpeedTotals>>{};

    rawEventsByGroup.forEach((groupKey, list) {
      final parts = groupKey.split('::');
      final taskId = parts.first;
      list.sort((a, b) => a.startTime.compareTo(b.startTime));
      final qtyQueue = List<_QtyRecord>.from(
          qtyRecordsByGroup[groupKey] ?? const <_QtyRecord>[])
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

      for (final raw in list) {
        final effectiveEnd = raw.endTime;
        if (effectiveEnd == null) continue;
        final minutes = effectiveEnd.difference(raw.startTime).inMinutes;
        if (minutes <= 0) continue;
        double qty = 0;
        while (qtyQueue.isNotEmpty &&
            !qtyQueue.first.timestamp.isAfter(effectiveEnd)) {
          final rec = qtyQueue.removeAt(0);
          if (!rec.timestamp.isBefore(raw.startTime)) qty += rec.qty;
        }
        final workplaceId = raw.workplaceId.isNotEmpty
            ? raw.workplaceId
            : (workplaceByTask[taskId] ?? '');
        if (workplaceId.isEmpty) continue;
        final monthKey = DateTime.utc(raw.startTime.year, raw.startTime.month);
        totalsByWorkplace
            .putIfAbsent(workplaceId, () => {})
            .putIfAbsent(monthKey, () => _MonthSpeedTotals())
            .add(qty: qty, minutes: minutes);
      }
    });

    final speedsByWorkplace = <String, List<double>>{};
    totalsByWorkplace.forEach((workplaceId, byMonth) {
      final monthKeys = byMonth.keys.toList()..sort();
      for (final monthKey in monthKeys) {
        final totals = byMonth[monthKey]!;
        if (totals.minutes <= 0) continue;
        final speed = totals.qty / totals.minutes;
        if (!speed.isFinite) continue;
        speedsByWorkplace.putIfAbsent(workplaceId, () => []).add(speed);
      }
    });
    return speedsByWorkplace;
  }

  // ── Static helpers (also used by analytics_repository) ─────────────────

  static final _allCommentTypes = const {
    'time_event',
    'quantity_done',
    'quantity_team_total',
    'quantity_share',
    'setup_done',
  };

  static bool isAnalyticsCommentType(String type) =>
      _allCommentTypes.contains(type);

  static List<Map<String, dynamic>> normalizeComments(dynamic value) {
    final comments = <Map<String, dynamic>>[];
    if (value is List) {
      for (final item in value) {
        if (item is Map) comments.add(Map<String, dynamic>.from(item));
      }
    } else if (value is Map) {
      value.forEach((key, item) {
        if (item is Map) {
          final comment = Map<String, dynamic>.from(item);
          comment.putIfAbsent('id', () => key.toString());
          comments.add(comment);
        }
      });
    }
    return comments;
  }

  static DateTime? parseCommentTimestamp(dynamic value) {
    // Единицы в tasks.comments смешанные: старые метки в секундах, новые в
    // миллисекундах. Без нормализации секундная метка (~1.79e9) читалась как
    // миллисекунды и давала январь 1970-го — такие комментарии выпадали из
    // выборки месяца в аналитике.
    DateTime fromEpoch(int raw) => DateTime.fromMillisecondsSinceEpoch(
          normalizeEpochToMillis(raw),
          isUtc: true,
        );

    if (value == null) return null;
    if (value is DateTime) return value.toUtc();
    if (value is int) return fromEpoch(value);
    if (value is num) return fromEpoch(value.toInt());
    if (value is String) {
      final raw = value.trim();
      if (raw.isEmpty) return null;
      final intValue = int.tryParse(raw);
      if (intValue != null) return fromEpoch(intValue);
      final doubleValue = double.tryParse(raw);
      if (doubleValue != null) return fromEpoch(doubleValue.toInt());
      return DateTime.tryParse(raw)?.toUtc();
    }
    return null;
  }

  // ── Private helpers ─────────────────────────────────────────────────────

  static String _makeQtyKey(TaskCommentRow row, String taskId) {
    final id = row.id.isNotEmpty ? row.id : '';
    if (id.isNotEmpty) return '$taskId|$id|${row.type}|${row.userId}';
    return '$taskId|${row.type}|${row.userId}'
        '|${row.timestamp.millisecondsSinceEpoch}|${row.text}';
  }

  static final _setupCountRe =
      RegExp(r'приладок:\s*([0-9]+(?:[.,][0-9]+)?)', caseSensitive: false);

  /// Явное количество приладок из текста setup_done («приладок: N»).
  /// null — маркера нет (старый формат комментария).
  static double? _parseSetupCount(String raw) {
    final match = _setupCountRe.firstMatch(raw);
    if (match == null) return null;
    return double.tryParse(match.group(1)!.replaceAll(',', '.'));
  }

  static double _parseQty(String raw) {
    final normalized = raw.replaceAll(',', '.').trim();
    final match = RegExp(r'-?[0-9]+(?:\.[0-9]+)?').firstMatch(normalized);
    if (match != null) return double.tryParse(match.group(0)!) ?? 0;
    return double.tryParse(normalized) ?? 0;
  }

  static (DateTime, DateTime?)? _normalizeTimeRange(
      DateTime start, DateTime? end, DateTime reference) {
    final utcStart = start.toUtc();
    DateTime? utcEnd = end?.toUtc();
    if (utcEnd == null) return (utcStart, null);
    if (utcEnd.isBefore(utcStart)) {
      final crossedMidnight = utcEnd.difference(utcStart).inHours.abs() <= 18;
      if (crossedMidnight) {
        utcEnd = utcEnd.add(const Duration(days: 1));
      } else {
        return null;
      }
    }
    if (utcEnd.isAfter(reference.add(const Duration(days: 31)))) return null;
    return (utcStart, utcEnd);
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
    final endEffective = end ?? DateTime.now().toUtc();
    return start.isBefore(monthEnd) && !endEffective.isBefore(monthFirst);
  }
}
