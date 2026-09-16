import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/tasks/task_buttons_state.dart'
    show UserRunState;
import 'package:sheet_clone/modules/tasks/task_model.dart';
import 'package:sheet_clone/modules/tasks/task_run_state.dart';

TaskComment _interval({
  required String id,
  required String userId,
  required int startMs,
  int? endMs,
  String type = 'production',
}) =>
    TaskComment(
      id: id,
      type: 'time_event',
      userId: userId,
      timestamp: startMs,
      text: jsonEncode({
        'type': type,
        'taskId': 'task-1',
        'subjectUserId': userId,
        'startTime':
            DateTime.fromMillisecondsSinceEpoch(startMs, isUtc: true)
                .toIso8601String(),
        if (endMs != null)
          'endTime': DateTime.fromMillisecondsSinceEpoch(endMs, isUtc: true)
              .toIso8601String(),
        'workplaceId': 'wp-1',
        'participantsSnapshot': ['u1', 'u2'],
      }),
    );

TaskModel _task(List<TaskComment> comments) => TaskModel(
      id: 'task-1',
      orderId: 'order-1',
      stageId: 'wp-1',
      status: TaskStatus.inProgress,
      assignees: const ['u1'],
      comments: comments,
    );

void main() {
  test('интервалы разбираются один раз на объект задачи', () {
    final task = _task([
      _interval(id: '1', userId: 'u1', startMs: 1000, endMs: 2000),
      _interval(id: '2', userId: 'u2', startMs: 1500),
    ]);

    final first = taskTimeEvents(task);
    final second = taskTimeEvents(task);

    expect(identical(first, second), isTrue,
        reason: 'повторный вызов обязан брать разбор из кэша');
    expect(first.length, 2);
  });

  test('копия задачи разбирается заново — кэш не протухает', () {
    final task = _task([
      _interval(id: '1', userId: 'u1', startMs: 1000, endMs: 2000),
    ]);
    expect(taskTimeEvents(task).length, 1);

    final updated = task.copyWith(comments: [
      ...task.comments,
      _interval(id: '2', userId: 'u1', startMs: 3000),
    ]);

    expect(identical(taskTimeEvents(task), taskTimeEvents(task)), isTrue);
    expect(taskTimeEvents(updated).length, 2,
        reason: 'новый объект задачи — новый разбор');
    expect(taskTimeEvents(task).length, 1,
        reason: 'старый объект остаётся при своих данных');
  });

  test('порядок сохраняется: по началу интервала', () {
    final task = _task([
      _interval(id: '2', userId: 'u1', startMs: 5000),
      _interval(id: '1', userId: 'u1', startMs: 1000, endMs: 2000),
    ]);

    final events = taskTimeEvents(task);
    expect(events.first.startTime.millisecondsSinceEpoch, 1000);
    expect(events.last.startTime.millisecondsSinceEpoch, 5000);
  });

  test('список неизменяемый: правка на месте испортила бы общий кэш', () {
    final task = _task([_interval(id: '1', userId: 'u1', startMs: 1000)]);
    expect(
      () => taskTimeEvents(task).sort((a, b) => 0),
      throwsUnsupportedError,
    );
  });

  test('состояние исполнителя не изменилось от кэша', () {
    final open = _task([
      _interval(id: '1', userId: 'u1', startMs: 1000),
    ]);
    final closed = _task([
      _interval(id: '1', userId: 'u1', startMs: 1000, endMs: 2000),
    ]);
    final paused = _task([
      _interval(id: '1', userId: 'u1', startMs: 1000, type: 'pause'),
    ]);

    expect(userRunState(open, 'u1'), UserRunState.active);
    expect(userRunState(closed, 'u1'), UserRunState.idle);
    expect(userRunState(paused, 'u1'), UserRunState.paused);
    expect(stageProductionStarted(open), isTrue);
    expect(isShiftPausedForTasks([open]), isFalse);
  });
}
