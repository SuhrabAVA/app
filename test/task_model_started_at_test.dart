import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/tasks/task_model.dart';

void main() {
  test('copyWith can clear startedAt when stage is finished or paused', () {
    final task = TaskModel(
      id: 'task-1',
      orderId: 'order-1',
      stageId: 'stage-1',
      status: TaskStatus.inProgress,
      startedAt: 1710000000000,
    );

    final updated = task.copyWith(
      status: TaskStatus.completed,
      clearStartedAt: true,
    );

    expect(updated.status, TaskStatus.completed);
    expect(updated.startedAt, isNull);
  });
}
