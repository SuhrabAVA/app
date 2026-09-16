import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/analytics/repositories/task_analytics_mapper.dart';
import 'package:sheet_clone/modules/tasks/stage_quantity_records.dart';

/// Инвариант: база КПД считается ПО ТОЙ ЖЕ величине, что и текущий месяц.
///
/// КПД рабочего места = скорость текущего месяца / средняя скорость
/// предыдущих. Текущий месяц берёт ТИРАЖ (`buildWorkplaceStageTotals`), и
/// если база продолжит суммировать личные количества, то на совместных
/// этапах она окажется раздутой во столько раз, сколько человек было в
/// бригаде, — КПД рухнет на ровном месте, без единого изменения в цехе.
TaskCommentRow interval({
  required String userId,
  required DateTime start,
  required DateTime end,
}) =>
    TaskCommentRow(
      id: 'te-$userId-${start.millisecondsSinceEpoch}',
      type: 'time_event',
      text: jsonEncode({
        'type': 'production',
        'startTime': start.toUtc().toIso8601String(),
        'endTime': end.toUtc().toIso8601String(),
        'subjectUserId': userId,
        'workplaceId': 'wp1',
      }),
      userId: userId,
      timestamp: start,
      taskId: 'task-1',
      stageId: 'wp1',
      orderId: 'order-1',
    );

TaskCommentRow qtyRow({
  required String type,
  required String userId,
  required DateTime at,
  required double qty,
}) =>
    TaskCommentRow(
      id: '$type-$userId-${at.millisecondsSinceEpoch}',
      type: type,
      text: '$qty',
      userId: userId,
      timestamp: at,
      taskId: 'task-1',
      stageId: 'wp1',
      orderId: 'order-1',
    );

void main() {
  // Базовый месяц — август; текущий — сентябрь.
  final monthStart = DateTime.utc(2026, 9, 1);
  final reference = DateTime.utc(2026, 9, 30);
  final workStart = DateTime.utc(2026, 8, 10, 10);
  final workEnd = DateTime.utc(2026, 8, 10, 11); // 60 минут на каждого
  final qtyAt = DateTime.utc(2026, 8, 10, 11);

  test('скорость базы = тираж / минуты', () {
    final rows = <TaskCommentRow>[
      for (final uid in ['a', 'b', 'c'])
        interval(userId: uid, start: workStart, end: workEnd),
      qtyRow(type: kStageTotalCommentType, userId: 'a', at: qtyAt, qty: 600),
      for (final uid in ['a', 'b', 'c'])
        qtyRow(type: 'quantity_share', userId: uid, at: qtyAt, qty: 200),
    ];

    final speeds =
        TaskAnalyticsMapper.buildPreviousSpeeds(rows, monthStart, reference);
    final speed = speeds['wp1']!.single;

    // 600 / 180 мин. Если бы база считала по личным записям, вышло бы то же
    // самое — доли в сумме дают тираж. Поэтому решающий тест — следующий.
    expect(speed, closeTo(600 / 180, 0.0001));
  });

  test('СТАРЫЕ данные: полное Q каждому больше не раздувает базу', () {
    // Так выглядели совместные этапы до пересчёта: каждому записано полное Q.
    // Сумма личных = 1800 при тираже 600 — втрое больше правды.
    final rows = <TaskCommentRow>[
      for (final uid in ['a', 'b', 'c'])
        interval(userId: uid, start: workStart, end: workEnd),
      qtyRow(type: kStageTotalCommentType, userId: 'a', at: qtyAt, qty: 600),
      for (final uid in ['a', 'b', 'c'])
        qtyRow(type: 'quantity_share', userId: uid, at: qtyAt, qty: 600),
    ];

    final speeds =
        TaskAnalyticsMapper.buildPreviousSpeeds(rows, monthStart, reference);

    expect(
      speeds['wp1']!.single,
      closeTo(600 / 180, 0.0001),
      reason: 'должно считаться по тиражу 600, а не по сумме 1800',
    );
  });

  test('без записи тиража остаётся прежний подсчёт', () {
    // Месяцы, где тираж не записан вовсе: поведение не меняем, иначе
    // сломалась бы история, которую нечем пересчитать.
    final rows = <TaskCommentRow>[
      for (final uid in ['a', 'b', 'c'])
        interval(userId: uid, start: workStart, end: workEnd),
      for (final uid in ['a', 'b', 'c'])
        qtyRow(type: 'quantity_done', userId: uid, at: qtyAt, qty: 200),
    ];

    final speeds =
        TaskAnalyticsMapper.buildPreviousSpeeds(rows, monthStart, reference);

    expect(speeds['wp1']!.single, closeTo(600 / 180, 0.0001));
  });

  test('тираж текущего месяца в базу не попадает', () {
    // Запись сентября не должна влиять на базу, иначе КПД сравнивал бы
    // месяц сам с собой.
    final rows = <TaskCommentRow>[
      for (final uid in ['a', 'b', 'c'])
        interval(userId: uid, start: workStart, end: workEnd),
      qtyRow(type: kStageTotalCommentType, userId: 'a', at: qtyAt, qty: 600),
      qtyRow(
        type: kStageTotalCommentType,
        userId: 'a',
        at: DateTime.utc(2026, 9, 15),
        qty: 99999,
      ),
    ];

    final speeds =
        TaskAnalyticsMapper.buildPreviousSpeeds(rows, monthStart, reference);

    expect(speeds['wp1']!.single, closeTo(600 / 180, 0.0001));
  });
}
