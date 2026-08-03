import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/analytics/models/analytics_event.dart';
import 'package:sheet_clone/modules/analytics/repositories/task_analytics_mapper.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

final _monthStart = DateTime.utc(2026, 1, 1);
final _monthEnd = DateTime.utc(2026, 2, 1);
final _reference = DateTime.utc(2026, 1, 31, 23, 59);

DateTime _ts(int hour, [int minute = 0]) =>
    DateTime.utc(2026, 1, 15, hour, minute);

String _encodeTimeEvent({
  required String type,
  required DateTime start,
  DateTime? end,
  required String userId,
  String taskId = 't1',
  String workplaceId = 'wp1',
}) {
  return jsonEncode({
    'type': type,
    'startTime': start.toIso8601String(),
    if (end != null) 'endTime': end.toIso8601String(),
    'initiatedBy': userId,
    'subjectUserId': userId,
    'taskId': taskId,
    'workplaceId': workplaceId,
    'participantsSnapshot': <String>[],
  });
}

TaskCommentRow _timeEventRow({
  required String taskId,
  required String userId,
  required String id,
  required String evType, // 'production' | 'pause' | 'setup'
  required DateTime start,
  DateTime? end,
}) =>
    TaskCommentRow(
      id: id,
      type: 'time_event',
      text: _encodeTimeEvent(
        type: evType,
        start: start,
        end: end,
        userId: userId,
        taskId: taskId,
      ),
      userId: userId,
      timestamp: start,
      taskId: taskId,
      stageId: 'stage1',
      orderId: 'order1',
    );

TaskCommentRow _qtyRow({
  required String taskId,
  required String userId,
  required String id,
  required String qtyType,
  required double qty,
  required DateTime ts,
}) =>
    TaskCommentRow(
      id: id,
      type: qtyType,
      text: qty.toString(),
      userId: userId,
      timestamp: ts,
      taskId: taskId,
      stageId: 'stage1',
      orderId: 'order1',
    );

// ── Tests ────────────────────────────────────────────────────────────────────

void main() {
  group('TaskAnalyticsMapper.buildEvents', () {
    test('Test 1 — Normal completion: quantity_done counted', () {
      final rows = [
        _timeEventRow(
            taskId: 't1',
            userId: 'empA',
            id: 'ev1',
            evType: 'production',
            start: _ts(10),
            end: _ts(11)),
        _qtyRow(
            taskId: 't1',
            userId: 'empA',
            id: 'q1',
            qtyType: 'quantity_done',
            qty: 50,
            ts: _ts(11)),
      ];

      final events = TaskAnalyticsMapper.buildEvents(
          rows, _monthStart, _monthEnd, _reference);

      final total = events
          .where((e) =>
              e.type == AnalyticsEventType.work && e.employeeId == 'empA')
          .fold<double>(0, (s, e) => s + e.qty);
      expect(total, 50);
    });

    test('Test 2 — Shift change: quantity_share counted within interval', () {
      final rows = [
        _timeEventRow(
            taskId: 't1',
            userId: 'empA',
            id: 'ev1',
            evType: 'production',
            start: _ts(10),
            end: _ts(12)),
        _qtyRow(
            taskId: 't1',
            userId: 'empA',
            id: 'q1',
            qtyType: 'quantity_share',
            qty: 20,
            ts: _ts(12)),
      ];

      final events = TaskAnalyticsMapper.buildEvents(
          rows, _monthStart, _monthEnd, _reference);

      final total = events
          .where((e) =>
              e.type == AnalyticsEventType.work && e.employeeId == 'empA')
          .fold<double>(0, (s, e) => s + e.qty);
      expect(total, 20);
    });

    test('Test 3 — Shift change without production interval: fallback event created', () {
      final rows = [
        _qtyRow(
            taskId: 't1',
            userId: 'empA',
            id: 'q1',
            qtyType: 'quantity_share',
            qty: 20,
            ts: _ts(12)),
      ];

      final events = TaskAnalyticsMapper.buildEvents(
          rows, _monthStart, _monthEnd, _reference);

      final workEvents = events.where((e) =>
          e.type == AnalyticsEventType.work && e.employeeId == 'empA');
      expect(workEvents.isNotEmpty, true,
          reason: 'A fallback event must be created for orphaned quantity_share');
      final total = workEvents.fold<double>(0, (s, e) => s + e.qty);
      expect(total, 20);
    });

    test('Test 4 — Separate executors: each gets their own qty', () {
      final rows = [
        _timeEventRow(
            taskId: 't1',
            userId: 'empA',
            id: 'evA',
            evType: 'production',
            start: _ts(10),
            end: _ts(11)),
        _qtyRow(
            taskId: 't1',
            userId: 'empA',
            id: 'qA',
            qtyType: 'quantity_done',
            qty: 10,
            ts: _ts(11)),
        _timeEventRow(
            taskId: 't1',
            userId: 'empB',
            id: 'evB',
            evType: 'production',
            start: _ts(10),
            end: _ts(11)),
        _qtyRow(
            taskId: 't1',
            userId: 'empB',
            id: 'qB',
            qtyType: 'quantity_done',
            qty: 15,
            ts: _ts(11)),
      ];

      final events = TaskAnalyticsMapper.buildEvents(
          rows, _monthStart, _monthEnd, _reference);

      final qtyA = events
          .where((e) => e.employeeId == 'empA')
          .fold<double>(0, (s, e) => s + e.qty);
      final qtyB = events
          .where((e) => e.employeeId == 'empB')
          .fold<double>(0, (s, e) => s + e.qty);
      expect(qtyA, 10);
      expect(qtyB, 15);
    });

    test('Test 5 — Helper removed: helper gets qty, not current worker', () {
      // After the fix in tasks_screen, helper removal writes quantity_share
      // for helperId. This test verifies the mapper attributes it correctly.
      final rows = [
        _timeEventRow(
            taskId: 't1',
            userId: 'helper1',
            id: 'evH',
            evType: 'production',
            start: _ts(10),
            end: _ts(11)),
        _qtyRow(
            taskId: 't1',
            userId: 'helper1',
            id: 'qH',
            qtyType: 'quantity_share',
            qty: 20,
            ts: _ts(11)),
      ];

      final events = TaskAnalyticsMapper.buildEvents(
          rows, _monthStart, _monthEnd, _reference);

      final qtyHelper = events
          .where((e) => e.employeeId == 'helper1')
          .fold<double>(0, (s, e) => s + e.qty);
      expect(qtyHelper, 20);
      // No events should be attributed to any other employee
      final otherQty = events
          .where((e) => e.employeeId != 'helper1' && e.type == AnalyticsEventType.work)
          .fold<double>(0, (s, e) => s + e.qty);
      expect(otherQty, 0);
    });

    test('Test 6 — Setup counted separately, not added to production qty', () {
      final rows = [
        _timeEventRow(
            taskId: 't1',
            userId: 'empA',
            id: 'ev1',
            evType: 'setup',
            start: _ts(9),
            end: _ts(10)),
        _qtyRow(
            taskId: 't1',
            userId: 'empA',
            id: 's1',
            qtyType: 'setup_done',
            qty: 5,
            ts: _ts(10)),
        _timeEventRow(
            taskId: 't1',
            userId: 'empA',
            id: 'ev2',
            evType: 'production',
            start: _ts(10),
            end: _ts(11)),
        _qtyRow(
            taskId: 't1',
            userId: 'empA',
            id: 'q1',
            qtyType: 'quantity_done',
            qty: 50,
            ts: _ts(11)),
      ];

      final events = TaskAnalyticsMapper.buildEvents(
          rows, _monthStart, _monthEnd, _reference);

      final workQty = events
          .where((e) => e.type == AnalyticsEventType.work)
          .fold<double>(0, (s, e) => s + e.qty);
      final setupQty = events
          .where((e) => e.type == AnalyticsEventType.setup)
          .fold<double>(0, (s, e) => s + e.setupQty);

      expect(workQty, 50);
      expect(setupQty, 5);
    });

    test('Test 7 — Duplicate quantity record is counted only once', () {
      // Same comment id → same dedup key → counted once even if rows repeated
      final rows = [
        _timeEventRow(
            taskId: 't1',
            userId: 'empA',
            id: 'ev1',
            evType: 'production',
            start: _ts(10),
            end: _ts(11)),
        _qtyRow(
            taskId: 't1',
            userId: 'empA',
            id: 'q1',
            qtyType: 'quantity_done',
            qty: 50,
            ts: _ts(11)),
        // Duplicate — same id
        _qtyRow(
            taskId: 't1',
            userId: 'empA',
            id: 'q1',
            qtyType: 'quantity_done',
            qty: 50,
            ts: _ts(11)),
      ];

      final events = TaskAnalyticsMapper.buildEvents(
          rows, _monthStart, _monthEnd, _reference);

      final total = events
          .where((e) =>
              e.type == AnalyticsEventType.work && e.employeeId == 'empA')
          .fold<double>(0, (s, e) => s + e.qty);
      expect(total, 50, reason: 'Duplicate quantity records must not be double-counted');
    });

    TaskCommentRow setupDoneRow({
      required String id,
      required String text,
      required DateTime ts,
    }) =>
        TaskCommentRow(
          id: id,
          type: 'setup_done',
          text: text,
          userId: 'empA',
          timestamp: ts,
          taskId: 't1',
          stageId: 'stage1',
          orderId: 'order1',
        );

    test('Test 8 — setup_done с маркером «приладок: N» использует явное число', () {
      final rows = [
        _timeEventRow(
            taskId: 't1',
            userId: 'empA',
            id: 'ev1',
            evType: 'setup',
            start: _ts(9),
            end: _ts(10)),
        setupDoneRow(
            id: 's1',
            text: 'Завершил(а) настройку станка (приладок: 3) — по краскам: 3',
            ts: _ts(10)),
      ];

      final events = TaskAnalyticsMapper.buildEvents(
          rows, _monthStart, _monthEnd, _reference);

      final setupQty = events
          .where((e) => e.type == AnalyticsEventType.setup)
          .fold<double>(0, (s, e) => s + e.setupQty);
      expect(setupQty, 3);
    });

    test('Test 9 — setup_done с «приладок: 0» даёт 0 (размеры совпали)', () {
      final rows = [
        _timeEventRow(
            taskId: 't1',
            userId: 'empA',
            id: 'ev1',
            evType: 'setup',
            start: _ts(9),
            end: _ts(10)),
        setupDoneRow(
            id: 's1',
            text: 'Завершил(а) настройку станка (приладок: 0) — '
                'по размеру: размеры совпадают с предыдущим заказом',
            ts: _ts(10)),
      ];

      final events = TaskAnalyticsMapper.buildEvents(
          rows, _monthStart, _monthEnd, _reference);

      final setupQty = events
          .where((e) => e.type == AnalyticsEventType.setup)
          .fold<double>(0, (s, e) => s + e.setupQty);
      expect(setupQty, 0,
          reason: 'Явный 0 из маркера не должен превращаться в легаси-единицу');
    });

    test('Test 10 — старый setup_done без маркера по-прежнему = 1', () {
      final rows = [
        _timeEventRow(
            taskId: 't1',
            userId: 'empA',
            id: 'ev1',
            evType: 'setup',
            start: _ts(9),
            end: _ts(10)),
        setupDoneRow(
            id: 's1',
            text: 'Завершил(а) настройку станка',
            ts: _ts(10)),
      ];

      final events = TaskAnalyticsMapper.buildEvents(
          rows, _monthStart, _monthEnd, _reference);

      final setupQty = events
          .where((e) => e.type == AnalyticsEventType.setup)
          .fold<double>(0, (s, e) => s + e.setupQty);
      expect(setupQty, 1);
    });
  });
}
