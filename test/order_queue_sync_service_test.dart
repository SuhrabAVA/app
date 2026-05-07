import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/order_queue_service.dart';
import 'package:sheet_clone/modules/orders/order_queue_sync_service.dart';

void main() {
  test('OrderQueueSyncEntry uses saved stage name for legacy plan inserts', () {
    const entry = OrderQueueSyncEntry(
      stageId: 'stage-1',
      stageGroupKey: 'stage-1',
      step: 1,
      row: {'stageName': 'Флексопечать'},
    );

    expect(entry.displayName, 'Флексопечать');
  });

  test('OrderQueueSyncEntry falls back to stage id when name is absent', () {
    const entry = OrderQueueSyncEntry(
      stageId: 'stage-1',
      stageGroupKey: 'stage-1',
      step: 1,
    );

    expect(entry.displayName, 'stage-1');
  });

  test('diff updates pending stages even when protected stages stay unchanged', () {
    const protectedStage = OrderQueueSyncEntry(
      stageId: 'print',
      stageGroupKey: 'print',
      step: 1,
      status: 'in_progress',
      row: {'name': 'Печать'},
    );
    const pendingStage = OrderQueueSyncEntry(
      stageId: 'pack',
      stageGroupKey: 'pack',
      step: 2,
      status: 'waiting',
      row: {'name': 'Упаковка'},
    );
    const nextProtectedStage = OrderQueueSyncEntry(
      stageId: 'print',
      stageGroupKey: 'print',
      step: 1,
    );
    const nextPendingStage = OrderQueueSyncEntry(
      stageId: 'pack',
      stageGroupKey: 'pack',
      step: 3,
    );

    final operations = OrderQueueSyncService.diff(
      currentStages: const [protectedStage, pendingStage],
      currentTasks: const [protectedStage, pendingStage],
      nextQueue: const [nextProtectedStage, nextPendingStage],
    );

    expect(
      operations.where((op) => op.type == OrderQueueSyncOperationType.block),
      isEmpty,
    );
    expect(
      operations.any((op) =>
          op.type == OrderQueueSyncOperationType.updatePending &&
          op.current?.stageId == 'pack' &&
          op.next?.step == 3),
      isTrue,
    );
  });

  test('diff blocks moving a protected stage with a concrete message', () {
    const protectedStage = OrderQueueSyncEntry(
      stageId: 'print',
      stageGroupKey: 'print',
      step: 1,
      status: 'started',
      row: {'name': 'Печать'},
    );
    const movedProtectedStage = OrderQueueSyncEntry(
      stageId: 'print',
      stageGroupKey: 'print',
      step: 2,
    );

    final operations = OrderQueueSyncService.diff(
      currentStages: const [protectedStage],
      currentTasks: const [protectedStage],
      nextQueue: const [movedProtectedStage],
    );

    final blocked = operations.where(
      (op) => op.type == OrderQueueSyncOperationType.block,
    );
    expect(blocked, isNotEmpty);
    expect(blocked.first.reason, contains('Печать'));
    expect(blocked.first.reason, contains('started'));
  });

  test('OrderQueueMapper assigns unique steps for alternative workplaces', () {
    final entries = OrderQueueMapper.toSyncEntries(const [
      {
        'stageKey': 'die_cut',
        'stageId': 'die-cut-a1',
        'workplaceIds': ['die-cut-a1', 'die-cut-a2'],
        'order': 3,
      },
      {
        'stageKey': 'pack',
        'stageId': 'pack',
        'order': 4,
      },
    ]);

    expect(entries.map((entry) => entry.step), [3, 4, 5]);
    expect(entries.map((entry) => entry.stageId), [
      'die-cut-a1',
      'die-cut-a2',
      'pack',
    ]);
  });
}
