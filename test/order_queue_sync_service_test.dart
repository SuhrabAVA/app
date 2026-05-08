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

  test(
    'OrderQueueMapper keeps parallel workplace alternatives on one queue step',
    () {
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

      expect(entries.map((entry) => entry.step), [3, 3, 4]);
      expect(entries.map((entry) => entry.stageId), [
        'die-cut-a1',
        'die-cut-a2',
        'pack',
      ]);
    },
  );

  test('OrderQueueMapper uses only selected workplace for switchable stages', () {
    final entries = OrderQueueMapper.toSyncEntries(const [
      {
        'stageKey': 'v_main_switch',
        'stageId': 'window',
        'selectedWorkplaceId': 'window',
        'workplaceIds': ['fri', 'window'],
        'alternativeStageIds': ['fri'],
        'isSwitchable': true,
        'order': 1,
      },
      {
        'stageKey': 'pack',
        'stageId': 'pack',
        'order': 2,
      },
    ]);

    expect(entries.map((entry) => entry.stageId), ['window', 'pack']);
    expect(entries.map((entry) => entry.step), [1, 2]);
  });

  test('physical seq stays unique for parallel stages on the same logical step', () {
    const firstAlternative = OrderQueueSyncEntry(
      stageId: 'die-cut-a1',
      stageGroupKey: 'die_cut',
      step: 3,
    );
    const secondAlternative = OrderQueueSyncEntry(
      stageId: 'die-cut-a2',
      stageGroupKey: 'die_cut',
      step: 3,
    );
    const nextStage = OrderQueueSyncEntry(
      stageId: 'pack',
      stageGroupKey: 'pack',
      step: 4,
    );
    const farStage = OrderQueueSyncEntry(
      stageId: 'far-stage',
      stageGroupKey: 'far-stage',
      step: 3000,
    );

    final physicalSeq = OrderQueueSyncService.physicalSeqByIdentityKey(
      const [firstAlternative, secondAlternative, nextStage, farStage],
    );

    expect(physicalSeq[firstAlternative.identityKey], 3001);
    expect(physicalSeq[secondAlternative.identityKey], 3002);
    expect(physicalSeq[nextStage.identityKey], 4);
    expect(physicalSeq[farStage.identityKey], 3000);
    expect(physicalSeq.values.toSet(), hasLength(4));
  });

}
