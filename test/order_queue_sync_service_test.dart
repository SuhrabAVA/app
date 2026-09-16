import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/production_ids.dart';
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

  test(
    'diff ignores legacy protected task group when its plan stage is unchanged',
    () {
      const protectedPlanStage = OrderQueueSyncEntry(
        stageId: wpBobbinUuid,
        stageGroupKey: 'bobbin',
        step: 1,
        status: 'completed',
        row: {'name': 'Бобинорезка'},
      );
      const legacyProtectedTask = OrderQueueSyncEntry(
        stageId: wpBobbinUuid,
        stageGroupKey: wpBobbinUuid,
        step: 1,
        status: 'completed',
      );
      const pendingAutoBig = OrderQueueSyncEntry(
        stageId: 'auto-big',
        stageGroupKey: 'p_main_switch',
        step: 2,
        status: 'waiting',
        row: {'name': 'Автомат большой'},
      );
      const nextProtectedPlanStage = OrderQueueSyncEntry(
        stageId: wpBobbinUuid,
        stageGroupKey: 'bobbin',
        step: 1,
      );
      const nextAutoSmall = OrderQueueSyncEntry(
        stageId: 'auto-small',
        stageGroupKey: 'p_main_switch',
        step: 2,
        row: {'stageName': 'Автомат маленький'},
      );

      final operations = OrderQueueSyncService.diff(
        currentStages: const [protectedPlanStage, pendingAutoBig],
        currentTasks: const [legacyProtectedTask, pendingAutoBig],
        nextQueue: const [nextProtectedPlanStage, nextAutoSmall],
      );

      expect(
        operations.where((op) => op.type == OrderQueueSyncOperationType.block),
        isEmpty,
      );
      expect(
        operations.any((op) =>
            op.type == OrderQueueSyncOperationType.cancelOrDeletePending &&
            op.current?.stageId == 'auto-big'),
        isTrue,
      );
      expect(
        operations.any((op) =>
            op.type == OrderQueueSyncOperationType.insert &&
            op.next?.stageId == 'auto-small'),
        isTrue,
      );
    },
  );

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

  test('OrderQueueMapper keeps separate normalized rows in the same group', () {
    final entries = OrderQueueMapper.toSyncEntries(const [
      {
        'stage_id': 'die-cut-a1',
        'stage_group_key': 'die_cut',
        'step_no': 5,
      },
      {
        'stage_id': 'die-cut-a2',
        'stage_group_key': 'die_cut',
        'step_no': 5,
      },
    ]);

    expect(entries.map((entry) => entry.stageId), [
      'die-cut-a1',
      'die-cut-a2',
    ]);
    expect(entries.map((entry) => entry.stageGroupKey).toSet(), {'die_cut'});
    expect(entries.map((entry) => entry.step), [5, 5]);
  });

  group('planMatchesQueue', () {
    const flexo = OrderQueueSyncEntry(
      stageId: 'flexo',
      stageGroupKey: 'flexo',
      step: 1,
    );
    const pack = OrderQueueSyncEntry(
      stageId: 'pack',
      stageGroupKey: 'pack',
      step: 2,
    );

    test('сохранение без правок маршрута план не переписывает', () {
      expect(
        OrderQueueSyncService.planMatchesQueue(
          const [flexo, pack],
          const [flexo, pack],
        ),
        isTrue,
      );
    });

    test('сдвиг шага — расхождение', () {
      expect(
        OrderQueueSyncService.planMatchesQueue(
          const [flexo, pack],
          const [
            flexo,
            OrderQueueSyncEntry(
              stageId: 'pack',
              stageGroupKey: 'pack',
              step: 3,
            ),
          ],
        ),
        isFalse,
      );
    });

    test('удалённый и добавленный этап — расхождение', () {
      expect(
        OrderQueueSyncService.planMatchesQueue(const [flexo, pack], const [flexo]),
        isFalse,
      );
      expect(
        OrderQueueSyncService.planMatchesQueue(
          const [flexo],
          const [
            flexo,
            OrderQueueSyncEntry(
              stageId: 'bobbin',
              stageGroupKey: 'bobbin',
              step: 2,
            ),
          ],
        ),
        isFalse,
      );
    });
  });

  test('rpc payload keeps parallel stages of one step as separate rows', () {
    // Физический seq раздаёт replace_plan_stages: только сервер видит номера,
    // занятые защищёнными этапами. Клиент отдаёт логический порядок, и два
    // параллельных рабочих места одного шага обязаны остаться двумя строками
    // с общим stage_group_key и одинаковым step_no.
    const firstAlternative = OrderQueueSyncEntry(
      stageId: 'die-cut-a1',
      stageGroupKey: 'die_cut',
      step: 3,
      row: {'name': 'Вырубка А1'},
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

    final payload = OrderQueueSyncService.planStagesRpcPayload(
      const [firstAlternative, secondAlternative, nextStage],
    );

    expect(payload, [
      {
        'stage_id': 'die-cut-a1',
        'stage_group_key': 'die_cut',
        'name': 'Вырубка А1',
        'step_no': 3,
      },
      {
        'stage_id': 'die-cut-a2',
        'stage_group_key': 'die_cut',
        // Без имени в строке очереди в план уходит идентификатор — иначе
        // функция подставит его сама, но в плане останется пустое поле.
        'name': 'die-cut-a2',
        'step_no': 3,
      },
      {
        'stage_id': 'pack',
        'stage_group_key': 'pack',
        'name': 'pack',
        'step_no': 4,
      },
    ]);
  });

  test(
    'diff allows switching a pending automatic stage after protected base stages',
    () {
      const protectedFlexo = OrderQueueSyncEntry(
        stageId: 'flexo',
        stageGroupKey: 'flexo',
        step: 1,
        status: 'in_progress',
        row: {'name': 'Флексопечать'},
      );
      const pendingAutoBig = OrderQueueSyncEntry(
        stageId: 'auto-big',
        stageGroupKey: 'p_main_switch',
        step: 2,
        status: 'waiting',
        row: {'name': 'Автомат большой'},
      );
      const nextFlexo = OrderQueueSyncEntry(
        stageId: 'flexo',
        stageGroupKey: 'flexo',
        step: 1,
      );
      const nextAutoSmall = OrderQueueSyncEntry(
        stageId: 'auto-small',
        stageGroupKey: 'p_main_switch',
        step: 2,
        row: {'stageName': 'Автомат маленький'},
      );

      final operations = OrderQueueSyncService.diff(
        currentStages: const [protectedFlexo, pendingAutoBig],
        currentTasks: const [protectedFlexo, pendingAutoBig],
        nextQueue: const [nextFlexo, nextAutoSmall],
      );

      expect(
        operations.where((op) => op.type == OrderQueueSyncOperationType.block),
        isEmpty,
      );
      expect(
        operations.any((op) =>
            op.type == OrderQueueSyncOperationType.cancelOrDeletePending &&
            op.current?.stageId == 'auto-big'),
        isTrue,
      );
      expect(
        operations.any((op) =>
            op.type == OrderQueueSyncOperationType.insert &&
            op.next?.stageId == 'auto-small'),
        isTrue,
      );
    },
  );

  test('diff blocks switching an automatic stage that has already started', () {
    const startedAutoBig = OrderQueueSyncEntry(
      stageId: 'auto-big',
      stageGroupKey: 'p_main_switch',
      step: 2,
      status: 'started',
      row: {'name': 'Автомат большой'},
    );
    const nextAutoSmall = OrderQueueSyncEntry(
      stageId: 'auto-small',
      stageGroupKey: 'p_main_switch',
      step: 2,
      row: {'stageName': 'Автомат маленький'},
    );

    final operations = OrderQueueSyncService.diff(
      currentStages: const [startedAutoBig],
      currentTasks: const [startedAutoBig],
      nextQueue: const [nextAutoSmall],
    );

    final blocked = operations.where(
      (op) => op.type == OrderQueueSyncOperationType.block,
    );
    expect(blocked, isNotEmpty);
    expect(blocked.first.reason, contains('Автомат большой'));
  });

  group('правка запущенного заказа (force)', () {
    // Смена типа продукта у запущенного заказа: маршрут меняется целиком,
    // при этом отработанный этап обязан уцелеть — в нём зафиксированы время
    // и количество, которые идут в аналитику и зарплату.
    const startedPrint = OrderQueueSyncEntry(
      stageId: 'print',
      stageGroupKey: 'print',
      step: 1,
      status: 'in_progress',
      row: {'name': 'Флексопечать'},
    );
    const pendingPack = OrderQueueSyncEntry(
      stageId: 'pack',
      stageGroupKey: 'pack',
      step: 2,
      status: 'waiting',
      row: {'name': 'Упаковка'},
    );
    const newCut = OrderQueueSyncEntry(
      stageId: 'cut',
      stageGroupKey: 'cut',
      step: 1,
      row: {'stageName': 'Резка'},
    );

    test('начатый этап помечается block, ожидающий — удаляется', () {
      final operations = OrderQueueSyncService.diff(
        currentStages: const [startedPrint, pendingPack],
        currentTasks: const [startedPrint, pendingPack],
        nextQueue: const [newCut],
      );

      final blocked = operations
          .where((op) => op.type == OrderQueueSyncOperationType.block)
          .toList();
      expect(blocked, isNotEmpty,
          reason: 'начатая Флексопечать не должна молча исчезнуть');
      expect(blocked.first.current?.stageId, 'print');

      final removed = operations
          .where((op) =>
              op.type == OrderQueueSyncOperationType.cancelOrDeletePending)
          .toList();
      expect(removed.map((op) => op.current?.stageId), contains('pack'));
    });

    test('новый этап маршрута добавляется', () {
      final operations = OrderQueueSyncService.diff(
        currentStages: const [startedPrint],
        currentTasks: const [startedPrint],
        nextQueue: const [startedPrint, newCut],
      );

      final inserted = operations
          .where((op) => op.type == OrderQueueSyncOperationType.insert)
          .toList();
      expect(inserted.map((op) => op.next?.stageId), contains('cut'));
    });
  });
}