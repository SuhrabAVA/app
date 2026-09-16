import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/tasks/task_model.dart';
import 'package:sheet_clone/modules/tasks/workplace_queue_gate.dart';

TaskModel task(
  String id, {
  TaskStatus status = TaskStatus.waiting,
  List<String> commentTypes = const [],
}) =>
    TaskModel(
      id: id,
      orderId: 'order-$id',
      stageId: 'stage-1',
      status: status,
      comments: [
        for (var i = 0; i < commentTypes.length; i++)
          TaskComment(
            id: '$id-c$i',
            type: commentTypes[i],
            text: '',
            userId: 'u1',
            timestamp: 1000 + i,
          ),
      ],
    );

void main() {
  group('hasWorkplaceQueueActivity', () {
    test('нетронутое задание активности не имеет', () {
      expect(hasWorkplaceQueueActivity(task('a')), isFalse);
    });

    test('начатое задание открывает очередь ещё до завершения', () {
      expect(
        hasWorkplaceQueueActivity(task('a', status: TaskStatus.inProgress)),
        isTrue,
      );
    });

    test('пауза, проблема и завершение тоже считаются активностью', () {
      for (final status in [
        TaskStatus.paused,
        TaskStatus.problem,
        TaskStatus.completed,
      ]) {
        expect(hasWorkplaceQueueActivity(task('a', status: status)), isTrue,
            reason: '$status');
      }
    });

    test('waiting со следом старта в комментариях — тоже активность', () {
      expect(
        hasWorkplaceQueueActivity(task('a', commentTypes: ['start'])),
        isTrue,
      );
      expect(
        hasWorkplaceQueueActivity(task('a', commentTypes: ['user_done'])),
        isTrue,
      );
    });
  });

  group('isUnlockedByQueueOrder', () {
    test('первая позиция открыта всегда', () {
      final queue = [task('a'), task('b')];
      expect(isUnlockedByQueueOrder(queue, 0), isTrue);
    });

    test(
        'НАЧАТЫЙ, но не завершённый предыдущий заказ открывает следующий '
        '(двое на одном этапе: вторая берёт следующий заказ)', () {
      final queue = [
        task('a', status: TaskStatus.inProgress),
        task('b'),
      ];
      expect(isUnlockedByQueueOrder(queue, 1), isTrue);
    });

    test('нетронутый предыдущий заказ держит очередь', () {
      final queue = [task('a'), task('b')];
      expect(isUnlockedByQueueOrder(queue, 1), isFalse);
    });

    test('держит любой нетронутый заказ выше по очереди, не только соседний',
        () {
      final queue = [
        task('a'),
        task('b', status: TaskStatus.inProgress),
        task('c'),
      ];
      expect(isUnlockedByQueueOrder(queue, 2), isFalse);
    });

    test('все предыдущие начаты — позиция открыта', () {
      final queue = [
        task('a', status: TaskStatus.completed),
        task('b', status: TaskStatus.inProgress),
        task('c'),
      ];
      expect(isUnlockedByQueueOrder(queue, 2), isTrue);
    });
  });
}
