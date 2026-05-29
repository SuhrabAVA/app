import 'package:supabase_flutter/supabase_flutter.dart';

import '../../tasks/task_model.dart';
import '../models/analytics_event.dart';
import '../models/analytics_month.dart';

class AnalyticsRepository {
  AnalyticsRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Future<List<AnalyticsEvent>> loadEventsForMonth(AnalyticsMonth month,
      {DateTime? now}) async {
    final monthStart = month.firstDay.toUtc();
    final monthEnd = month.nextMonthFirstDay.toUtc();
    final reference = (now ?? DateTime.now()).toUtc();

    final List<dynamic> rows = await _client
        .from('comments')
        .select(
            'id, type, text, user_id, timestamp, task_id, tasks!inner(id, stage_id, order_id, orders(id, customer))')
        .inFilter('type', [
      'time_event',
      'quantity_done',
      'quantity_team_total',
      'quantity_share',
      'setup_done',
    ])
        .gte('timestamp', monthStart.toIso8601String())
        .lt('timestamp', monthEnd.toIso8601String());

    final events = <AnalyticsEvent>[];
    final Map<String, List<TaskTimeEvent>> rawEventsByGroup = {};
    final Map<String, List<_QtyRecord>> qtyRecordsByGroup = {};
    final Map<String, List<_QtyRecord>> setupRecordsByGroup = {};
    final Map<String, _TaskJoinData> taskDataById = {};

    for (final row in rows) {
      if (row is! Map) continue;
      final map = Map<String, dynamic>.from(row);
      final type = (map['type'] ?? '').toString();
      final taskId = (map['task_id'] ?? '').toString();
      if (taskId.isEmpty) continue;

      final taskMap = map['tasks'] is Map ? Map<String, dynamic>.from(map['tasks']) : const <String, dynamic>{};
      final orderMap = taskMap['orders'] is Map ? Map<String, dynamic>.from(taskMap['orders']) : const <String, dynamic>{};
      taskDataById[taskId] = _TaskJoinData(
        stageId: (taskMap['stage_id'] ?? '').toString(),
        orderId: (taskMap['order_id'] ?? '').toString(),
        customer: orderMap['customer']?.toString(),
      );

      final timestamp = DateTime.tryParse((map['timestamp'] ?? '').toString())?.toUtc();
      if (timestamp == null) continue;
      final commentId = (map['id'] ?? '').toString();
      final userId = (map['user_id'] ?? '').toString();

      if (type == 'time_event') {
        final ev = TaskTimeEvent.fromPayload(
          (map['text'] ?? '').toString(),
          commentId,
          timestamp.millisecondsSinceEpoch,
          userId,
        );
        if (ev == null) continue;
        final normalized = _normalizeTimeRange(ev.startTime, ev.endTime, reference);
        if (normalized == null) continue;
        if (!_overlapsMonth(normalized.$1, normalized.$2, monthStart, monthEnd)) continue;
        rawEventsByGroup.putIfAbsent('$taskId::${ev.subjectUserId}', () => []).add(
              ev.copyWith(startTime: normalized.$1, endTime: normalized.$2),
            );
      } else if (type == 'setup_done' || type == 'quantity_done' || type == 'quantity_team_total' || type == 'quantity_share') {
        final qty = _parseQty((map['text'] ?? '').toString());
        final groupKey = '$taskId::$userId';
        if (type == 'setup_done') {
          final setupQty = qty > 0 ? qty : 1.0;
          setupRecordsByGroup.putIfAbsent(groupKey, () => []).add(_QtyRecord(timestamp: timestamp, qty: setupQty));
        } else if (qty > 0) {
          qtyRecordsByGroup.putIfAbsent(groupKey, () => []).add(_QtyRecord(timestamp: timestamp, qty: qty));
        }
      }
    }

    rawEventsByGroup.forEach((groupKey, list) {
      final parts = groupKey.split('::');
      final taskId = parts.first;
      final employeeId = parts.length > 1 ? parts[1] : '';
      final taskData = taskDataById[taskId];

      list.sort((a, b) => a.startTime.compareTo(b.startTime));
      final qtyQueue = List<_QtyRecord>.from(qtyRecordsByGroup[groupKey] ?? const [])..sort((a,b)=>a.timestamp.compareTo(b.timestamp));
      final setupQueue = List<_QtyRecord>.from(setupRecordsByGroup[groupKey] ?? const [])..sort((a,b)=>a.timestamp.compareTo(b.timestamp));

      for (final raw in list) {
        final eventType = _mapType(raw.type);
        if (eventType == null) continue;
        final effectiveEnd = raw.endTime ?? reference;
        double qty = 0, setupQty = 0;
        if (eventType == AnalyticsEventType.work) {
          while (qtyQueue.isNotEmpty && !qtyQueue.first.timestamp.isAfter(effectiveEnd)) {
            final rec = qtyQueue.removeAt(0);
            if (!rec.timestamp.isBefore(raw.startTime)) qty += rec.qty;
          }
        } else if (eventType == AnalyticsEventType.setup) {
          while (setupQueue.isNotEmpty && !setupQueue.first.timestamp.isAfter(effectiveEnd)) {
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
          workplaceId: raw.workplaceId.isNotEmpty ? raw.workplaceId : (taskData?.stageId ?? ''),
          taskId: taskId,
          orderId: taskData?.orderId ?? '',
          customer: taskData?.customer,
          note: raw.note,
          qty: qty,
          setupQty: setupQty,
          isActive: raw.endTime == null,
        ));
      }
    });

    events.sort((a,b)=>a.startTime.compareTo(b.startTime));
    return events;
  }

  /// Загружает помесячную базу скоростей по рабочим местам до выбранного
  /// месяца: учитываются только производственные события с ненулевой
  /// длительностью и timestamp строго раньше [month.firstDay].
  Future<Map<String, List<double>>> loadPreviousWorkplaceMonthSpeeds(
    AnalyticsMonth month, {
    DateTime? now,
  }) async {
    final monthStart = month.firstDay.toUtc();
    final reference = (now ?? monthStart).toUtc();

    final List<dynamic> rows = await _client
        .from('comments')
        .select(
            'id, type, text, user_id, timestamp, task_id, tasks!inner(id, stage_id, order_id, orders(id, customer))')
        .inFilter('type', [
      'time_event',
      'quantity_done',
      'quantity_team_total',
      'quantity_share',
    ])
        .lt('timestamp', monthStart.toIso8601String())
        .order('timestamp', ascending: true);

    final Map<String, List<TaskTimeEvent>> rawEventsByGroup = {};
    final Map<String, List<_QtyRecord>> qtyRecordsByGroup = {};
    final Map<String, _TaskJoinData> taskDataById = {};

    for (final row in rows) {
      if (row is! Map) continue;
      final map = Map<String, dynamic>.from(row);
      final type = (map['type'] ?? '').toString();
      final taskId = (map['task_id'] ?? '').toString();
      if (taskId.isEmpty) continue;

      final taskMap = map['tasks'] is Map
          ? Map<String, dynamic>.from(map['tasks'])
          : const <String, dynamic>{};
      final orderMap = taskMap['orders'] is Map
          ? Map<String, dynamic>.from(taskMap['orders'])
          : const <String, dynamic>{};
      taskDataById[taskId] = _TaskJoinData(
        stageId: (taskMap['stage_id'] ?? '').toString(),
        orderId: (taskMap['order_id'] ?? '').toString(),
        customer: orderMap['customer']?.toString(),
      );

      final timestamp =
          DateTime.tryParse((map['timestamp'] ?? '').toString())?.toUtc();
      if (timestamp == null) continue;
      final commentId = (map['id'] ?? '').toString();
      final userId = (map['user_id'] ?? '').toString();

      if (type == 'time_event') {
        final ev = TaskTimeEvent.fromPayload(
          (map['text'] ?? '').toString(),
          commentId,
          timestamp.millisecondsSinceEpoch,
          userId,
        );
        if (ev == null || ev.type != TaskTimeType.production) continue;
        final normalized =
            _normalizeTimeRange(ev.startTime, ev.endTime, reference);
        if (normalized == null) continue;
        final start = normalized.$1;
        final end = normalized.$2;
        if (!start.isBefore(monthStart) ||
            end == null ||
            end.isAfter(monthStart)) {
          continue;
        }
        rawEventsByGroup
            .putIfAbsent('$taskId::${ev.subjectUserId}', () => [])
            .add(ev.copyWith(startTime: start, endTime: end));
      } else if (type == 'quantity_done' ||
          type == 'quantity_team_total' ||
          type == 'quantity_share') {
        final qty = _parseQty((map['text'] ?? '').toString());
        if (qty <= 0) continue;
        final groupKey = '$taskId::$userId';
        qtyRecordsByGroup
            .putIfAbsent(groupKey, () => [])
            .add(_QtyRecord(timestamp: timestamp, qty: qty));
      }
    }

    final totalsByWorkplace = <String, Map<DateTime, _MonthSpeedTotals>>{};

    rawEventsByGroup.forEach((groupKey, list) {
      final parts = groupKey.split('::');
      final taskId = parts.first;
      final taskData = taskDataById[taskId];

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
            : (taskData?.stageId ?? '');
        if (workplaceId.isEmpty) continue;
        final monthKey = DateTime.utc(raw.startTime.year, raw.startTime.month);
        final byMonth = totalsByWorkplace.putIfAbsent(
          workplaceId,
          () => <DateTime, _MonthSpeedTotals>{},
        );
        byMonth
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

  static double _parseQty(String raw) {
    final normalized = raw.replaceAll(',', '.').trim();
    final match = RegExp(r'-?[0-9]+(?:\.[0-9]+)?').firstMatch(normalized);
    if (match != null) return double.tryParse(match.group(0)!) ?? 0;
    return double.tryParse(normalized) ?? 0;
  }
}

class _QtyRecord {
  final DateTime timestamp;
  final double qty;

  const _QtyRecord({required this.timestamp, required this.qty});
}

class _MonthSpeedTotals {
  double qty = 0;
  int minutes = 0;

  void add({required double qty, required int minutes}) {
    this.qty += qty;
    this.minutes += minutes;
  }
}

class _TaskJoinData {
  final String stageId;
  final String orderId;
  final String? customer;

  const _TaskJoinData({
    required this.stageId,
    required this.orderId,
    this.customer,
  });
}
