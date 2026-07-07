# Analytics Quantity Fix & Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix all quantity loss bugs (shift change, helper removal), prevent double-counting, and eliminate analytics scroll lag by reducing 50+ horizontal scroll controllers to 3.

**Architecture:** Extract `TaskAnalyticsMapper` (testable, independent) from `analytics_repository.dart`. Fix analytics_repository to filter by date + cache by month. Fix tasks_screen for helper attribution. Refactor table widgets to use `ValueListenableBuilder + Transform.translate` instead of per-row `ScrollController`.

**Tech Stack:** Flutter, Dart, Supabase, provider pattern.

---

## DATA FLOW MAP (as discovered)

| Action | Written by | Comment type | userId in comment |
|--------|-----------|--------------|-------------------|
| Task start | tasks_screen → task_provider.recordTimeEvent | time_event (production) | subjectUserId |
| Pause | tasks_screen → task_provider.recordTimeEvent | time_event (pause) | subjectUserId |
| Problem | tasks_screen → task_provider.recordTimeEvent | time_event (problem) | subjectUserId |
| Finish (individual) | tasks_screen → orders_repository.complete_task_stage RPC | quantity_done | employeeId |
| Finish (joint) | tasks_screen → orders_repository | quantity_team_total | employeeId |
| Shift change qty | tasks_screen.onShift() line 6664 | quantity_share | widget.employeeId |
| Shift change (helpers) | tasks_screen.onShift() line 6670 | quantity_share | helperId |
| Helper removed | tasks_screen.onRemoveHelper() line 6548 | helper_removed_qty | widget.employeeId ← BUG |
| Setup done | tasks_screen | setup_done | userId |

**Analytics reads from:** `tasks.comments` JSONB field, types: time_event, quantity_done, quantity_team_total, quantity_share, setup_done.

**Analytics does NOT read:** helper_removed_qty (not in `_allCommentTypes`).

---

## FILES TO CHANGE

| File | Change type |
|------|------------|
| `lib/modules/analytics/repositories/analytics_repository.dart` | Major: add cache, date filter, captured_by_wp_id, chunk customers, delegate to mapper |
| `lib/modules/analytics/repositories/task_analytics_mapper.dart` | New: extracted + fixed mapper with fallback events |
| `lib/modules/tasks/tasks_screen.dart` | Small: add quantity_share for helper in onRemoveHelper |
| `lib/modules/tasks/task_provider.dart` | Small: add quantity_share fallback in _sumLastStageQuantity |
| `lib/modules/analytics/utils/h_scroll_sync.dart` | Small: add offsetNotifier |
| `lib/modules/analytics/widgets/employees_table.dart` | Medium: body uses ValueListenableBuilder+Transform |
| `lib/modules/analytics/widgets/workplaces_table.dart` | Medium: same as employees_table |
| `lib/modules/analytics/widgets/schedule_grid.dart` | Medium: same |
| `test/analytics/task_analytics_mapper_test.dart` | New: 7 tests |

---

## Task 1: Create `TaskAnalyticsMapper` (extracted + fixed)

**Files:**
- Create: `lib/modules/analytics/repositories/task_analytics_mapper.dart`

- [ ] **Step 1: Write the new mapper file**

```dart
// lib/modules/analytics/repositories/task_analytics_mapper.dart
import 'package:flutter/foundation.dart';

import '../../tasks/task_model.dart';
import '../models/analytics_event.dart';

/// Input row — one comment from tasks.comments that is relevant to analytics.
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
  final String key; // dedup key
  final DateTime timestamp;
  final double qty;
  const _QtyRecord({required this.key, required this.timestamp, required this.qty});
}

/// Stateless mapper: converts flat comment rows → AnalyticsEvent list.
/// Testable without Supabase.
class TaskAnalyticsMapper {
  /// Build AnalyticsEvents for [currentRows] (comments within the target month).
  static List<AnalyticsEvent> buildEvents(
    List<TaskCommentRow> rows,
    DateTime monthStart,
    DateTime monthEnd,
    DateTime reference,
  ) {
    final events = <AnalyticsEvent>[];

    // Group time events and qty records by taskId::subjectUserId
    final rawEventsByGroup = <String, List<TaskTimeEvent>>{};
    final qtyRecordsByGroup = <String, List<_QtyRecord>>{};
    final setupRecordsByGroup = <String, List<_QtyRecord>>{};
    // Best workplace per task (for fallback events)
    final workplaceByTask = <String, String>{};
    // Row metadata per task
    final metaByTask = <String, TaskCommentRow>{};
    // Dedup set for quantity records
    final seenQtyKeys = <String>{};

    for (final row in rows) {
      final type = row.type;
      final taskId = row.taskId;
      if (taskId.isEmpty) continue;

      metaByTask[taskId] = row;

      // Best workplace: capturedByWorkplaceId > stageId
      workplaceByTask.putIfAbsent(
        taskId,
        () => row.capturedByWorkplaceId?.isNotEmpty == true
            ? row.capturedByWorkplaceId!
            : row.stageId,
      );

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

        // Update workplace from time_event if available
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
          setupRecordsByGroup
              .putIfAbsent(groupKey, () => [])
              .add(_QtyRecord(key: qtyKey, timestamp: row.timestamp, qty: qty > 0 ? qty : 1.0));
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

      // ── Fallback: emit work events for quantities not consumed by any interval ──
      while (qtyQueue.isNotEmpty) {
        final rec = qtyQueue.removeAt(0);
        if (rec.qty <= 0) continue;
        assert(() {
          debugPrint(
              '[Analytics] quantity_fallback: group=$groupKey qty=${rec.qty} at ${rec.timestamp.toLocal()}');
          return true;
        }());
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

  /// Build workplace speed baselines from previous-month rows.
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

  // ── Helpers ──────────────────────────────────────────────────────────────

  static String _makeQtyKey(TaskCommentRow row, String taskId) {
    final id = row.id.isNotEmpty ? row.id : '';
    if (id.isNotEmpty) return '$taskId|$id|${row.type}|${row.userId}';
    return '$taskId|${row.type}|${row.userId}|${row.timestamp.millisecondsSinceEpoch}|${row.text}';
  }

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
    if (value == null) return null;
    if (value is DateTime) return value.toUtc();
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
    if (value is num) return DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
    if (value is String) {
      final raw = value.trim();
      if (raw.isEmpty) return null;
      final intValue = int.tryParse(raw);
      if (intValue != null) return DateTime.fromMillisecondsSinceEpoch(intValue, isUtc: true);
      final doubleValue = double.tryParse(raw);
      if (doubleValue != null) {
        return DateTime.fromMillisecondsSinceEpoch(doubleValue.toInt(), isUtc: true);
      }
      return DateTime.tryParse(raw)?.toUtc();
    }
    return null;
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

class _MonthSpeedTotals {
  double qty = 0;
  int minutes = 0;
  void add({required double qty, required int minutes}) {
    this.qty += qty;
    this.minutes += minutes;
  }
}
```

- [ ] **Step 2: Run flutter analyze to confirm it compiles**

```powershell
cd "C:\Users\suhra\OneDrive\Desktop\Easy Pack Pro"
flutter analyze lib/modules/analytics/repositories/task_analytics_mapper.dart
```

Expected: no errors (may have unused import warnings to fix).

---

## Task 2: Rewrite `analytics_repository.dart`

**Files:**
- Modify: `lib/modules/analytics/repositories/analytics_repository.dart`

- [ ] **Step 1: Replace entire file with optimized version**

Key changes:
- Add `captured_by_workplace_id` to select
- Add `updated_at` date filter (tasks updated within target range)
- Add `Map<String, ({...})> _cache` cache by year-month
- Fix `_loadCustomersByOrderId` with chunking
- Delegate to `TaskAnalyticsMapper`
- Keep static helpers only for backward compat (none needed, mapper is self-contained)

Full replacement (see execute step).

- [ ] **Step 2: Run flutter analyze**

```powershell
flutter analyze lib/modules/analytics/repositories/
```

Expected: no errors.

---

## Task 3: Fix helper removal in `tasks_screen.dart`

**Files:**
- Modify: `lib/modules/tasks/tasks_screen.dart:6548-6553`

- [ ] **Step 1: Add `quantity_share` comment for helper after `helper_removed_qty`**

Current code at lines 6548-6553:
```dart
await taskProvider.addCommentAutoUser(
  taskId: task.id,
  type: 'helper_removed_qty',
  text: '$helperName: ${qtyInput.displayText}',
  userIdOverride: widget.employeeId,
);
```

New code:
```dart
await taskProvider.addCommentAutoUser(
  taskId: task.id,
  type: 'helper_removed_qty',
  text: '$helperName: ${qtyInput.displayText}',
  userIdOverride: widget.employeeId,
);
// Structural quantity record attributed to the helper (for analytics)
if (qtyInput.quantity > 0) {
  await taskProvider.addCommentAutoUser(
    taskId: task.id,
    type: 'quantity_share',
    text: qtyInput.commentText,
    userIdOverride: helperId,
  );
}
```

- [ ] **Step 2: Run flutter analyze on the file**

```powershell
flutter analyze lib/modules/tasks/tasks_screen.dart
```

---

## Task 4: Fix `_sumLastStageQuantity` in `task_provider.dart`

**Files:**
- Modify: `lib/modules/tasks/task_provider.dart:2288-2331`

- [ ] **Step 1: Add `quantity_share` as fallback**

Current: only counts `quantity_team_total` OR `quantity_done`.

After:
```dart
// At the end of the task loop, after checking team and done:
// 3) Fallback: sum quantity_share when no authoritative record exists
if (team.isEmpty && parts.isEmpty) {
  final shares = comments.where((m) => (m['type'] ?? '') == 'quantity_share');
  for (final m in shares) {
    total += _parseQtySafe(m['text']);
  }
}
```

- [ ] **Step 2: Run flutter analyze on the file**

---

## Task 5: Add `offsetNotifier` to `HScrollSync`

**Files:**
- Modify: `lib/modules/analytics/utils/h_scroll_sync.dart`

- [ ] **Step 1: Add ValueNotifier field + update + dispose**

Add `final offsetNotifier = ValueNotifier<double>(0.0);` field.
In `_onControllerScrolled`, after `_offset = newOffset;`, add `offsetNotifier.value = newOffset;`.
In `dispose()`, before clearing controllers, add `offsetNotifier.dispose();`.

- [ ] **Step 2: Run flutter analyze**

---

## Task 6: Refactor `employees_table.dart` for performance

**Files:**
- Modify: `lib/modules/analytics/widgets/employees_table.dart`

- [ ] **Step 1: Replace per-row `SingleChildScrollView` with `ValueListenableBuilder + Transform`**

In the `build` method, the data rows section:

**Before:**
```dart
...rows.asMap().entries.map((entry) {
  final i = entry.key;
  final r = entry.value;
  return IntrinsicHeight(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildStickyDataCell(r, stickyWidth),
        Expanded(
          child: SingleChildScrollView(
            controller: _ctrl(i),  // per-row synced controller
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            child: SizedBox(width: restWidth, child: _buildScrollableDataRow(...)),
          ),
        ),
      ],
    ),
  );
}),
```

**After:**
```dart
ValueListenableBuilder<double>(
  valueListenable: _sync.offsetNotifier,
  builder: (context, hOffset, _) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: rows.map((r) {
        return RepaintBoundary(
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildStickyDataCell(r, stickyWidth),
                Expanded(
                  child: ClipRect(
                    child: Transform.translate(
                      offset: Offset(-hOffset, 0),
                      child: SizedBox(
                        width: restWidth,
                        child: _buildScrollableDataRow(context, r, canViewFinance),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  },
),
```

Also remove `final Map<int, ScrollController> _ctrlCache = {};` field since body rows no longer need controllers. Keep `_ctrl(int key)` only for header (-1) and footer (10000).

- [ ] **Step 2: Run flutter analyze**

---

## Task 7: Refactor `workplaces_table.dart` and `schedule_grid.dart`

Same approach as Task 6. Apply `ValueListenableBuilder + Transform.translate` to the data row body.

- [ ] **Step 1: Refactor workplaces_table.dart** (same pattern)
- [ ] **Step 2: Refactor schedule_grid.dart** (same pattern — data rows column)
- [ ] **Step 3: Run flutter analyze**

---

## Task 8: Write tests

**Files:**
- Create: `test/analytics/task_analytics_mapper_test.dart`

- [ ] **Step 1: Write the test file**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:easy_pack_pro/modules/analytics/repositories/task_analytics_mapper.dart';
import 'package:easy_pack_pro/modules/analytics/models/analytics_event.dart';
// (adjust package name to match pubspec.yaml)

DateTime _ts(int hour, [int minute = 0]) =>
    DateTime(2026, 1, 15, hour, minute).toUtc();

final _monthStart = DateTime(2026, 1, 1).toUtc();
final _monthEnd = DateTime(2026, 2, 1).toUtc();
final _reference = DateTime(2026, 1, 31, 23, 59).toUtc();

TaskCommentRow _timeEvent({
  required String taskId,
  required String userId,
  required String id,
  required String type,   // production/pause/setup
  required DateTime start,
  DateTime? end,
}) {
  final ev = {
    'type': type,
    'startTime': start.millisecondsSinceEpoch,
    if (end != null) 'endTime': end.millisecondsSinceEpoch,
    'subjectUserId': userId,
    'initiatedBy': userId,
    'workplaceId': 'wp1',
    'taskId': taskId,
    'participantsSnapshot': <String>[],
  };
  import 'dart:convert';
  return TaskCommentRow(
    id: id,
    type: 'time_event',
    text: jsonEncode(ev),
    userId: userId,
    timestamp: start,
    taskId: taskId,
    stageId: 'stage1',
    orderId: 'order1',
  );
}

TaskCommentRow _qty({
  required String taskId,
  required String userId,
  required String id,
  required String type,
  required double qty,
  required DateTime ts,
}) {
  return TaskCommentRow(
    id: id,
    type: type,
    text: qty.toString(),
    userId: userId,
    timestamp: ts,
    taskId: taskId,
    stageId: 'stage1',
    orderId: 'order1',
  );
}

void main() {
  group('TaskAnalyticsMapper', () {
    test('Test 1: Normal completion — quantity_done counted', () {
      final rows = [
        _timeEvent(taskId: 't1', userId: 'empA', id: 'ev1',
            type: 'production', start: _ts(10), end: _ts(11)),
        _qty(taskId: 't1', userId: 'empA', id: 'q1',
            type: 'quantity_done', qty: 50, ts: _ts(11)),
      ];
      final events = TaskAnalyticsMapper.buildEvents(rows, _monthStart, _monthEnd, _reference);
      final work = events.where((e) => e.type == AnalyticsEventType.work && e.employeeId == 'empA');
      expect(work.fold<double>(0, (s, e) => s + e.qty), 50);
    });

    test('Test 2: Shift change — quantity_share counted within interval', () {
      final rows = [
        _timeEvent(taskId: 't1', userId: 'empA', id: 'ev1',
            type: 'production', start: _ts(10), end: _ts(12)),
        _qty(taskId: 't1', userId: 'empA', id: 'q1',
            type: 'quantity_share', qty: 20, ts: _ts(12)),
      ];
      final events = TaskAnalyticsMapper.buildEvents(rows, _monthStart, _monthEnd, _reference);
      final work = events.where((e) => e.type == AnalyticsEventType.work && e.employeeId == 'empA');
      expect(work.fold<double>(0, (s, e) => s + e.qty), 20);
    });

    test('Test 3: Shift change without production interval → fallback event', () {
      final rows = [
        _qty(taskId: 't1', userId: 'empA', id: 'q1',
            type: 'quantity_share', qty: 20, ts: _ts(12)),
      ];
      final events = TaskAnalyticsMapper.buildEvents(rows, _monthStart, _monthEnd, _reference);
      final workEvents = events.where((e) =>
          e.type == AnalyticsEventType.work && e.employeeId == 'empA');
      expect(workEvents.isNotEmpty, true);
      expect(workEvents.fold<double>(0, (s, e) => s + e.qty), 20);
    });

    test('Test 4: Separate executors — each gets their own qty', () {
      final rows = [
        _timeEvent(taskId: 't1', userId: 'empA', id: 'evA',
            type: 'production', start: _ts(10), end: _ts(11)),
        _qty(taskId: 't1', userId: 'empA', id: 'qA',
            type: 'quantity_done', qty: 10, ts: _ts(11)),
        _timeEvent(taskId: 't1', userId: 'empB', id: 'evB',
            type: 'production', start: _ts(10), end: _ts(11)),
        _qty(taskId: 't1', userId: 'empB', id: 'qB',
            type: 'quantity_done', qty: 15, ts: _ts(11)),
      ];
      final events = TaskAnalyticsMapper.buildEvents(rows, _monthStart, _monthEnd, _reference);
      final qtyA = events.where((e) => e.employeeId == 'empA')
          .fold<double>(0, (s, e) => s + e.qty);
      final qtyB = events.where((e) => e.employeeId == 'empB')
          .fold<double>(0, (s, e) => s + e.qty);
      expect(qtyA, 10);
      expect(qtyB, 15);
    });

    test('Test 5: Helper removal — helper gets qty, not current worker', () {
      // After fix in tasks_screen, helper_removed generates quantity_share for helperId
      final rows = [
        _timeEvent(taskId: 't1', userId: 'helper1', id: 'evH',
            type: 'production', start: _ts(10), end: _ts(11)),
        _qty(taskId: 't1', userId: 'helper1', id: 'qH',
            type: 'quantity_share', qty: 20, ts: _ts(11)),
      ];
      final events = TaskAnalyticsMapper.buildEvents(rows, _monthStart, _monthEnd, _reference);
      final qtyHelper = events.where((e) => e.employeeId == 'helper1')
          .fold<double>(0, (s, e) => s + e.qty);
      expect(qtyHelper, 20);
      // Current worker should NOT get helper's qty (no rows for worker)
    });

    test('Test 6: Setup counted separately, not in production qty', () {
      final rows = [
        _timeEvent(taskId: 't1', userId: 'empA', id: 'ev1',
            type: 'setup', start: _ts(9), end: _ts(10)),
        _qty(taskId: 't1', userId: 'empA', id: 's1',
            type: 'setup_done', qty: 5, ts: _ts(10)),
        _timeEvent(taskId: 't1', userId: 'empA', id: 'ev2',
            type: 'production', start: _ts(10), end: _ts(11)),
        _qty(taskId: 't1', userId: 'empA', id: 'q1',
            type: 'quantity_done', qty: 50, ts: _ts(11)),
      ];
      final events = TaskAnalyticsMapper.buildEvents(rows, _monthStart, _monthEnd, _reference);
      final workQty = events.where((e) => e.type == AnalyticsEventType.work)
          .fold<double>(0, (s, e) => s + e.qty);
      final setupQty = events.where((e) => e.type == AnalyticsEventType.setup)
          .fold<double>(0, (s, e) => s + e.setupQty);
      expect(workQty, 50);
      expect(setupQty, 5);
    });

    test('Test 7: Duplicate quantity record is not double-counted', () {
      // Same comment id → same dedup key → counted once
      final rows = [
        _timeEvent(taskId: 't1', userId: 'empA', id: 'ev1',
            type: 'production', start: _ts(10), end: _ts(11)),
        _qty(taskId: 't1', userId: 'empA', id: 'q1',
            type: 'quantity_done', qty: 50, ts: _ts(11)),
        _qty(taskId: 't1', userId: 'empA', id: 'q1', // same id = duplicate
            type: 'quantity_done', qty: 50, ts: _ts(11)),
      ];
      final events = TaskAnalyticsMapper.buildEvents(rows, _monthStart, _monthEnd, _reference);
      final total = events.where((e) => e.type == AnalyticsEventType.work && e.employeeId == 'empA')
          .fold<double>(0, (s, e) => s + e.qty);
      expect(total, 50); // not 100
    });
  });
}
```

- [ ] **Step 2: Run tests**

```powershell
flutter test test/analytics/task_analytics_mapper_test.dart
```

Expected: all 7 tests pass (after imports are fixed for the actual package name).

---

## Task 9: Final verification

- [ ] **Step 1: Run full flutter analyze**

```powershell
flutter analyze
```

Expected: 0 new errors.

- [ ] **Step 2: Run all existing tests**

```powershell
flutter test
```

Expected: all tests pass.

---

## SUPABASE MANUAL CHECKS (cannot be done from client)

1. **`complete_task_stage` RPC**: Verify it writes `quantity_done` comment in `tasks.comments` (not just in a separate table). If it writes nothing to comments, the client at `tasks_screen.dart:6223` writes `quantity_done` after the RPC — confirm this is the authoritative write.

2. **`complete_flex_printing_stage_with_paint_queue` RPC**: Same check — does it write a quantity comment? If yes, does it match the format analytics expects (`type: 'quantity_done'`, `text: quantity_value`)?

3. **`tasks` table**: Confirm `updated_at` column exists and is auto-updated on row changes (should be a Supabase trigger or column default). This is needed for the date filter optimization.

4. **`tasks.captured_by_workplace_id`**: Confirm column exists. Used for workplace attribution fallback.

5. **Indexes**: For performance, confirm `tasks` has an index on `updated_at` (or at least `created_at`).
