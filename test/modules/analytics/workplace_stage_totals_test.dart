import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/analytics/repositories/task_analytics_mapper.dart';

/// Выработка САМОГО рабочего места — это зафиксированный тираж, а не сумма
/// выработки участников. На станках каждому участнику записывается полное
/// количество, поэтому суммирование людей даёт тираж, умноженный на размер
/// бригады: шесть человек на 30 000 превращались в 180 000.
TaskCommentRow _row({
  required String type,
  required String text,
  required DateTime at,
  String taskId = 'task-1',
  String stageId = 'wp1',
  String? capturedBy,
  String id = '',
}) {
  return TaskCommentRow(
    id: id.isEmpty ? '$type-${at.millisecondsSinceEpoch}' : id,
    type: type,
    text: text,
    userId: 'e1',
    timestamp: at,
    taskId: taskId,
    stageId: stageId,
    orderId: 'order-1',
    capturedByWorkplaceId: capturedBy,
  );
}

void main() {
  final monthStart = DateTime.utc(2026, 8, 1);
  final monthEnd = DateTime.utc(2026, 9, 1);

  test('тираж сегментов складывается по рабочему месту', () {
    // Пересмена + завершение: два сегмента одного этапа.
    final totals = TaskAnalyticsMapper.buildWorkplaceStageTotals(
      [
        _row(
            type: 'quantity_stage_total',
            text: '{"actual":7000}',
            at: DateTime.utc(2026, 8, 5, 12)),
        _row(
            type: 'quantity_stage_total',
            text: '{"actual":5000}',
            at: DateTime.utc(2026, 8, 5, 20)),
      ],
      monthStart,
      monthEnd,
    );
    expect(totals['wp1'], 12000);
  });

  test('персональные доли в итог рабочего места не идут', () {
    final totals = TaskAnalyticsMapper.buildWorkplaceStageTotals(
      [
        _row(
            type: 'quantity_stage_total',
            text: '{"actual":30000}',
            at: DateTime.utc(2026, 8, 5, 20)),
        _row(
            type: 'quantity_share',
            text: '{"actual":30000,"generated":true}',
            at: DateTime.utc(2026, 8, 5, 20)),
        _row(
            type: 'quantity_share',
            text: '{"actual":30000,"generated":true}',
            at: DateTime.utc(2026, 8, 5, 20)),
      ],
      monthStart,
      monthEnd,
    );
    expect(totals['wp1'], 30000,
        reason: 'иначе станок с бригадой показал бы тираж × число людей');
  });

  test('чужой месяц не попадает в итог', () {
    final totals = TaskAnalyticsMapper.buildWorkplaceStageTotals(
      [
        _row(
            type: 'quantity_stage_total',
            text: '{"actual":1000}',
            at: DateTime.utc(2026, 7, 31, 23)),
        _row(
            type: 'quantity_stage_total',
            text: '{"actual":500}',
            at: DateTime.utc(2026, 9, 1)),
        _row(
            type: 'quantity_stage_total',
            text: '{"actual":250}',
            at: DateTime.utc(2026, 8, 1)),
      ],
      monthStart,
      monthEnd,
    );
    expect(totals['wp1'], 250);
  });

  test('дубли одной записи считаются один раз', () {
    final totals = TaskAnalyticsMapper.buildWorkplaceStageTotals(
      [
        _row(
            id: 'same',
            type: 'quantity_stage_total',
            text: '{"actual":800}',
            at: DateTime.utc(2026, 8, 5, 20)),
        _row(
            id: 'same',
            type: 'quantity_stage_total',
            text: '{"actual":800}',
            at: DateTime.utc(2026, 8, 5, 20)),
      ],
      monthStart,
      monthEnd,
    );
    expect(totals['wp1'], 800);
  });

  test('тираж относится к захватившему рабочему месту, а не к этапу', () {
    // Группа альтернативных РМ: этап заведён на одно, а выполнен на другом.
    final totals = TaskAnalyticsMapper.buildWorkplaceStageTotals(
      [
        _row(
            type: 'time_event',
            text: '{}',
            at: DateTime.utc(2026, 8, 5, 8),
            capturedBy: 'wp-real'),
        _row(
            type: 'quantity_stage_total',
            text: '{"actual":900}',
            at: DateTime.utc(2026, 8, 5, 20),
            capturedBy: 'wp-real'),
      ],
      monthStart,
      monthEnd,
    );
    expect(totals['wp-real'], 900);
    expect(totals['wp1'], isNull);
  });

  test('пустой ввод даёт пустой итог, а не ноль по всем местам', () {
    expect(
      TaskAnalyticsMapper.buildWorkplaceStageTotals(
          const [], monthStart, monthEnd),
      isEmpty,
    );
  });
}
