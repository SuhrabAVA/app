import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/tasks/task_completion_rules.dart';
import 'package:sheet_clone/modules/tasks/task_model.dart';

TaskComment _comment({
  required String type,
  required int timestamp,
  String userId = 'u1',
  String text = '',
}) =>
    TaskComment(
      id: '$type-$timestamp',
      type: type,
      text: text,
      userId: userId,
      timestamp: timestamp,
    );

TaskModel _task(List<TaskComment> comments) => TaskModel(
      id: 't1',
      orderId: 'o1',
      stageId: 'stage',
      status: TaskStatus.waiting,
      comments: comments,
    );

void main() {
  group('граница круга после возобновления этапа', () {
    test('этап не возобновляли — границы нет', () {
      final task = _task([
        _comment(type: 'start', timestamp: 1787000001000),
        _comment(type: 'user_done', timestamp: 1787000002000),
      ]);

      expect(stageRoundStartMillis(task), 0);
    });

    test('граница — момент возобновления', () {
      final task = _task([
        _comment(type: 'start', timestamp: 1787000001000),
        _comment(type: 'user_done', timestamp: 1787000002000),
        _comment(type: 'stage_reopened', timestamp: 1787000003000),
      ]);

      expect(stageRoundStartMillis(task), 1787000003000);
    });

    test('возобновляли несколько раз — берётся последнее', () {
      final task = _task([
        _comment(type: 'stage_reopened', timestamp: 1787000003000),
        _comment(type: 'user_done', timestamp: 1787000004000),
        _comment(type: 'stage_reopened', timestamp: 1787000005000),
        _comment(type: 'stage_reopened', timestamp: 1787000004500),
      ]);

      expect(stageRoundStartMillis(task), 1787000005000,
          reason: 'порядок комментариев в списке не гарантирован');
    });

    test('регресс: отметка завершения прошлого круга остаётся ДО границы', () {
      // Смысл правила: user_done сделан ДО возобновления, значит в
      // текущем круге сотрудник ещё не завершал участие и может начать этап.
      final task = _task([
        _comment(type: 'user_done', timestamp: 1787000002000),
        _comment(type: 'stage_reopened', timestamp: 1787000003000),
      ]);

      final roundStart = stageRoundStartMillis(task);
      final doneInThisRound = task.comments
          .where((c) => c.type == 'user_done' && c.timestamp >= roundStart)
          .toList();

      expect(doneInThisRound, isEmpty);
    });

    test('секундные метки приводятся к миллисекундам', () {
      // Часть исторических комментариев записана в секундах — граница обязана
      // сравниваться с событиями в одних единицах.
      final task = _task([
        _comment(type: 'stage_reopened', timestamp: 1787011200),
      ]);

      expect(stageRoundStartMillis(task), 1787011200000);
    });
  });
}
