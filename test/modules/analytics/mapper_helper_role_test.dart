import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/analytics/repositories/task_analytics_mapper.dart';
import 'package:sheet_clone/modules/tasks/task_model.dart';

/// Роль в совместной работе нельзя вывести из количества: после завершения
/// этапа оно засчитывается всем участникам целиком. Мэппер получает готовый
/// список помощников и обязан разметить им ВСЕ события — включая fallback,
/// которым закрываются количества без парного интервала.
TaskCommentRow _timeEvent({
  required String userId,
  required DateTime start,
  required DateTime end,
}) {
  final payload = TaskTimeEvent.encodePayload(TaskTimeEvent(
    id: 'te-$userId',
    type: TaskTimeType.production,
    startTime: start,
    endTime: end,
    initiatedBy: userId,
    subjectUserId: userId,
    taskId: 'task-1',
    workplaceId: 'wp1',
    participantsSnapshot: const <String>[],
  ));
  return TaskCommentRow(
    id: 'te-$userId',
    type: 'time_event',
    text: payload,
    userId: userId,
    timestamp: start,
    taskId: 'task-1',
    stageId: 'wp1',
    orderId: 'order-1',
  );
}

TaskCommentRow _qty({
  required String userId,
  required DateTime at,
  required double qty,
}) {
  return TaskCommentRow(
    id: 'qty-$userId-${at.millisecondsSinceEpoch}',
    type: 'quantity_team_total',
    text: '$qty',
    userId: userId,
    timestamp: at,
    taskId: 'task-1',
    stageId: 'wp1',
    orderId: 'order-1',
  );
}

void main() {
  final monthStart = DateTime(2026, 6, 1);
  final monthEnd = DateTime(2026, 7, 1);
  final reference = DateTime(2026, 6, 30, 23, 59);

  final start = DateTime(2026, 6, 3, 8);
  final end = DateTime(2026, 6, 3, 16);

  test('помощник помечается, основной исполнитель — нет', () {
    final events = TaskAnalyticsMapper.buildEvents(
      [
        _timeEvent(userId: 'main', start: start, end: end),
        _timeEvent(userId: 'helper', start: start, end: end),
        _qty(userId: 'main', at: start.add(const Duration(hours: 1)), qty: 6000),
        _qty(
            userId: 'helper',
            at: start.add(const Duration(hours: 1)),
            qty: 6000),
      ],
      monthStart,
      monthEnd,
      reference,
      helpersByTask: const {
        'task-1': {'helper'}
      },
    );

    final mainEvents = events.where((e) => e.employeeId == 'main');
    final helperEvents = events.where((e) => e.employeeId == 'helper');

    expect(mainEvents, isNotEmpty);
    expect(helperEvents, isNotEmpty);
    expect(mainEvents.every((e) => !e.isHelper), isTrue);
    expect(helperEvents.every((e) => e.isHelper), isTrue);
    // Количество у обоих одинаковое — разницу делает только ставка.
    expect(
      mainEvents.fold<double>(0, (s, e) => s + e.qty),
      helperEvents.fold<double>(0, (s, e) => s + e.qty),
    );
  });

  test('без списка помощников все события остаются основными', () {
    final events = TaskAnalyticsMapper.buildEvents(
      [
        _timeEvent(userId: 'main', start: start, end: end),
        _qty(userId: 'main', at: start.add(const Duration(hours: 1)), qty: 100),
      ],
      monthStart,
      monthEnd,
      reference,
    );

    expect(events, isNotEmpty);
    expect(events.every((e) => !e.isHelper), isTrue);
  });

  test('fallback-события количества тоже несут роль', () {
    // Количество без парного интервала — мэппер делает минутное событие.
    final events = TaskAnalyticsMapper.buildEvents(
      [
        _qty(userId: 'helper', at: start, qty: 6000),
      ],
      monthStart,
      monthEnd,
      reference,
      helpersByTask: const {
        'task-1': {'helper'}
      },
    );

    expect(events, hasLength(1));
    expect(events.single.note, 'quantity_fallback');
    expect(events.single.isHelper, isTrue,
        reason: 'иначе помощник получил бы полную ставку за это количество');
  });
}
