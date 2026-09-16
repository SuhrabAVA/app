import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/production/production_queue_provider.dart';

WorkplaceQueueEntry _entry(
  String workplaceId,
  String orderId, {
  String? taskId,
  String? stageId,
  String? stageGroupKey,
}) {
  return WorkplaceQueueEntry(
    workplaceId: workplaceId,
    taskId: taskId,
    orderId: orderId,
    stageId: stageId ?? 'stage-$orderId',
    stageGroupKey: stageGroupKey ?? 'group-$orderId',
  );
}

WorkplaceQueuePosition _position(
  String workplaceId,
  String orderId,
  int queuePosition, {
  String? id,
  String? taskId,
  String? stageId,
  String? stageGroupKey,
  bool hasQueuePosition = true,
}) {
  return WorkplaceQueuePosition(
    id: id ?? '$workplaceId-$orderId',
    workplaceId: workplaceId,
    taskId: taskId,
    orderId: orderId,
    stageId: stageId ?? 'stage-$orderId',
    stageGroupKey: stageGroupKey ?? 'group-$orderId',
    queuePosition: queuePosition,
    hasQueuePosition: hasQueuePosition,
  );
}

void main() {
  group('WorkplaceQueuePositionPlanner', () {
    test('показ и перестановка выбирают одну строку задвоенного элемента', () {
      // Регрессия «нельзя поднять ТОО Raw на листорезе». У заказа было две
      // строки очереди: одна на удалённой задаче (номер меньше), другая на
      // живой. Показ ходил по точному ключу задачи и попадал во вторую,
      // перестановка выбирала первую. Заказ получал новый номер в строке,
      // которую список не читал, и оставался на месте.
      final stale = _position('cut', 'raw', 28,
          id: 'row-stale', taskId: 'task-dead');
      final live = _position('cut', 'raw', 47,
          id: 'row-live', taskId: 'task-live');
      final other = _position('cut', 'other', 1, id: 'row-other');
      final current = [stale, live, other];

      final shown = WorkplaceQueuePositionPlanner.positionForSemanticKey(
        current,
        live.semanticKey,
      );
      final canonical =
          WorkplaceQueuePositionPlanner.canonicalBySemanticKey(current)[
              live.semanticKey];
      expect(shown!.id, canonical!.id,
          reason: 'показ обязан читать ту же строку, что переписывает drag');

      // Поднимаем ТОО Raw на первое место.
      final nextKeys = WorkplaceQueuePositionPlanner.reorderedQueueKeys(
        current: current,
        orderedKeys: [
          WorkplaceQueueItemKey.fromEntry(
              _entry('cut', 'raw', taskId: 'task-live')),
          WorkplaceQueueItemKey.fromEntry(_entry('cut', 'other')),
        ],
        workplaceId: 'cut',
      );
      final renumbered = WorkplaceQueuePositionPlanner.renumber(
        current: current,
        nextKeys: nextKeys,
      );

      final after = WorkplaceQueuePositionPlanner.positionForSemanticKey(
        renumbered,
        live.semanticKey,
      );
      expect(after!.queuePosition, 1,
          reason: 'после перетаскивания заказ обязан оказаться первым');

      // Проверка кусается: прежнее правило показа — точное совпадение по
      // ключу задачи — на этих же данных вернуло бы ДРУГУЮ строку и другой
      // номер. Если кто-то вернёт быстрый путь в priorityOfEntry, тест упадёт.
      final byExactKeyBefore =
          current.firstWhere((p) => p.queueKey == live.queueKey);
      expect(byExactKeyBefore.id, isNot(canonical.id),
          reason: 'данные должны воспроизводить расхождение старого правила');
      final byExactKeyAfter =
          renumbered.firstWhere((p) => p.id == byExactKeyBefore.id);
      expect(byExactKeyAfter.queuePosition, isNot(1),
          reason: 'старое правило показа так и оставило бы заказ не первым');
    });

    test('одна строка на слот: показ равен назначенному номеру', () {
      final row = _position('cut', 'raw', 5, id: 'row', taskId: 'task-live');
      final shown = WorkplaceQueuePositionPlanner.positionForSemanticKey(
        [row],
        row.semanticKey,
      );
      expect(shown!.queuePosition, 5);
    });

    test('appends a new element to the end of the workplace queue', () {
      final existing = [
        _position('cut', 'order-1', 4),
        _position('cut', 'order-2', 7),
      ];
      final entries = [
        _entry('cut', 'order-2'),
        _entry('cut', 'order-3'),
      ];

      final plan = WorkplaceQueuePositionPlanner.appendMissingAfterMax(
        existing: existing,
        entries: entries,
        workplaceId: 'cut',
      );

      expect(plan, hasLength(1));
      expect(plan.single.entry.orderId, 'order-3');
      expect(plan.single.queuePosition, 8);
    });

    test('keeps incoming order for new tasks instead of priority sorting', () {
      final existing = [
        _position('cut', 'order-1', 1),
      ];
      final entries = [
        _entry('cut', 'order-low'),
        _entry('cut', 'order-high'),
      ];

      final plan = WorkplaceQueuePositionPlanner.appendMissingAfterMax(
        existing: existing,
        entries: entries,
        workplaceId: 'cut',
      );

      expect(plan.map((item) => item.entry.orderId), [
        'order-low',
        'order-high',
      ]);
      expect(plan.map((item) => item.queuePosition), [2, 3]);
    });

    test('reorder in one workplace does not change another workplace', () {
      final cutFirst = _position('cut', 'order-1', 1);
      final cutSecond = _position('cut', 'order-2', 2);
      final printFirst = _position('print', 'order-3', 1);
      final printSecond = _position('print', 'order-4', 2);
      final current = [cutFirst, cutSecond, printFirst, printSecond];

      final cutKeys = WorkplaceQueuePositionPlanner.reorderedKeys(
        current: current,
        orderedEntries: [
          _entry('cut', 'order-2'),
          _entry('cut', 'order-1'),
        ],
        workplaceId: 'cut',
      );
      final printKeys = WorkplaceQueuePositionPlanner.sortedPositions(
        current.where((position) => position.workplaceId == 'print'),
      ).map((position) => position.queueKey);

      expect(cutKeys, [cutSecond.queueKey, cutFirst.queueKey]);
      expect(printKeys, [printFirst.queueKey, printSecond.queueKey]);
    });

    test('reorders by concrete task keys inside selected workplace only', () {
      final cutPaint = _position(
        'cut',
        'order-1',
        1,
        taskId: 'task-paint',
        stageId: 'paint',
        stageGroupKey: 'finish',
      );
      final cutCut = _position(
        'cut',
        'order-1',
        2,
        taskId: 'task-cut',
        stageId: 'cut',
        stageGroupKey: 'cut',
      );
      final print = _position('print', 'order-2', 1, taskId: 'task-print');

      final keys = WorkplaceQueuePositionPlanner.reorderedQueueKeys(
        current: [cutPaint, cutCut, print],
        orderedKeys: [
          WorkplaceQueueItemKey.fromEntry(_entry(
            'cut',
            'order-1',
            taskId: 'task-cut',
            stageId: 'cut',
            stageGroupKey: 'cut',
          )),
          WorkplaceQueueItemKey.fromEntry(_entry(
            'cut',
            'order-1',
            taskId: 'task-paint',
            stageId: 'paint',
            stageGroupKey: 'finish',
          )),
          WorkplaceQueueItemKey.fromEntry(_entry(
            'print',
            'order-2',
            taskId: 'task-print',
          )),
        ],
        workplaceId: 'cut',
      );

      expect(keys, [cutCut.queueKey, cutPaint.queueKey]);
    });

    test('регресс: строка без task_id и элемент с task_id — один элемент', () {
      // В таблице позиций строки заведены БЕЗ task_id (так их создаёт
      // рабочее пространство), а из производства перетаскивание приходит с
      // task_id. Строгие ключи не совпадали: элемент не опознавался как
      // видимый, его позиция не переписывалась, и он ещё раз добавлялся в
      // хвост — заказ вставал не туда, куда его положили.
      final first = _position('cut', 'order-1', 1,
          id: 'row-1', stageId: 'cut', stageGroupKey: 'cut');
      final second = _position('cut', 'order-2', 2,
          id: 'row-2', stageId: 'cut', stageGroupKey: 'cut');

      final keys = WorkplaceQueuePositionPlanner.reorderedQueueKeys(
        current: [first, second],
        orderedKeys: [
          WorkplaceQueueItemKey.fromEntry(_entry('cut', 'order-2',
              taskId: 'task-2', stageId: 'cut', stageGroupKey: 'cut')),
          WorkplaceQueueItemKey.fromEntry(_entry('cut', 'order-1',
              taskId: 'task-1', stageId: 'cut', stageGroupKey: 'cut')),
        ],
        workplaceId: 'cut',
      );

      expect(keys, [second.queueKey, first.queueKey],
          reason: 'ключи существующих строк, без дублей в хвосте');
    });

    test('задвоенный элемент: обе стороны выбирают строку с task_id', () {
      // Реальная ситуация в базе: на один заказ+этап две строки — с task_id и
      // без, на разных позициях. Показ и перестановка обязаны выбрать одну и
      // ту же, иначе после перетаскивания элемент встаёт на позицию второй.
      final withTask = _position('cut', 'order-1', 80,
          id: 'row-task', taskId: 'task-1', stageId: 'cut',
          stageGroupKey: 'cut');
      final withoutTask = _position('cut', 'order-1', 108,
          id: 'row-plain', stageId: 'cut', stageGroupKey: 'cut');

      expect(
        WorkplaceQueuePositionPlanner.preferredPosition(
            withoutTask, withTask),
        same(withTask),
      );
      expect(
        WorkplaceQueuePositionPlanner.preferredPosition(
            withTask, withoutTask),
        same(withTask),
        reason: 'выбор не должен зависеть от порядка сравнения',
      );

      final canonical = WorkplaceQueuePositionPlanner.canonicalBySemanticKey(
        [withoutTask, withTask],
      );
      expect(canonical.length, 1);
      expect(canonical.values.single.id, 'row-task');
    });

    test('задвоенный элемент не занимает два места в хвосте', () {
      final visible = _position('cut', 'order-1', 1,
          id: 'row-visible', taskId: 'task-1', stageId: 'cut',
          stageGroupKey: 'cut');
      final hiddenA = _position('cut', 'order-2', 2,
          id: 'row-a', taskId: 'task-2', stageId: 'cut',
          stageGroupKey: 'cut');
      final hiddenB = _position('cut', 'order-2', 9,
          id: 'row-b', stageId: 'cut', stageGroupKey: 'cut');

      final keys = WorkplaceQueuePositionPlanner.reorderedQueueKeys(
        current: [visible, hiddenA, hiddenB],
        orderedKeys: [
          WorkplaceQueueItemKey.fromEntry(_entry('cut', 'order-1',
              taskId: 'task-1', stageId: 'cut', stageGroupKey: 'cut')),
        ],
        workplaceId: 'cut',
      );

      expect(keys, [visible.queueKey, hiddenA.queueKey],
          reason: 'order-2 занимает одно место, а не два');
    });

    test('перенумерация: номер получает каждая строка, коллизий нет', () {
      // Задвоенный элемент order-2: две строки. Пропущенная строка сохранила
      // бы старый номер и столкнулась бы с новым — так на Флексопечати
      // появилось 7 пар одинаковых номеров.
      final a = _position('cut', 'order-1', 5,
          id: 'row-a', taskId: 'task-1', stageId: 'cut', stageGroupKey: 'cut');
      final bMain = _position('cut', 'order-2', 6,
          id: 'row-b', taskId: 'task-2', stageId: 'cut', stageGroupKey: 'cut');
      final bDup = _position('cut', 'order-2', 91,
          id: 'row-b-dup', stageId: 'cut', stageGroupKey: 'cut');

      final result = WorkplaceQueuePositionPlanner.renumber(
        current: [a, bMain, bDup],
        nextKeys: [bMain.queueKey, a.queueKey],
      );

      expect(result.map((p) => p.id), ['row-b', 'row-a', 'row-b-dup'],
          reason: 'сначала порядок элементов, затем осиротевшие строки');
      expect(result.map((p) => p.queuePosition), [1, 2, 3]);
      expect(result.map((p) => p.queuePosition).toSet().length, result.length,
          reason: 'номера уникальны');
      expect(result.length, 3, reason: 'ни одна строка не потеряна');
    });

    test('перенумерация не теряет строки, которых нет в nextKeys', () {
      final visible = _position('cut', 'order-1', 1,
          id: 'row-1', taskId: 'task-1', stageId: 'cut', stageGroupKey: 'cut');
      final stale = _position('cut', 'order-9', 77,
          id: 'row-9', taskId: 'task-9', stageId: 'cut', stageGroupKey: 'cut');

      final result = WorkplaceQueuePositionPlanner.renumber(
        current: [visible, stale],
        nextKeys: [visible.queueKey],
      );

      expect(result.map((p) => p.id), ['row-1', 'row-9']);
      expect(result.map((p) => p.queuePosition), [1, 2]);
    });

    test('sync plan does not delete or reorder existing positions', () {
      final existing = [
        _position('pack', 'order-1', 10),
        _position('pack', 'order-2', 30),
      ];
      final entries = [
        _entry('pack', 'order-2'),
        _entry('pack', 'order-3'),
        _entry('pack', 'order-1'),
      ];

      final plan = WorkplaceQueuePositionPlanner.appendMissingAfterMax(
        existing: existing,
        entries: entries,
        workplaceId: 'pack',
      );
      final existingAfterPlan = WorkplaceQueuePositionPlanner.sortedPositions(
        existing,
      );

      expect(plan.map((item) => item.entry.orderId), ['order-3']);
      expect(plan.map((item) => item.queuePosition), [31]);
      expect(existingAfterPlan.map((position) => position.orderId), [
        'order-1',
        'order-2',
      ]);
      expect(existingAfterPlan.map((position) => position.queuePosition), [
        10,
        30,
      ]);
    });

    test('loads legacy rows without a position after positioned rows', () {
      final positioned = _position('lamination', 'order-1', 2);
      final legacyWithoutPosition = _position(
        'lamination',
        'order-legacy',
        1 << 30,
        hasQueuePosition: false,
      );

      final sorted = WorkplaceQueuePositionPlanner.sortedPositions([
        legacyWithoutPosition,
        positioned,
      ]);

      expect(sorted.map((position) => position.orderId), [
        'order-1',
        'order-legacy',
      ]);
    });
  });

  /// Слот очереди обязан называться одинаково на всех экранах.
  ///
  /// Рабочее пространство и МУПЗ строят элемент очереди из РАЗНЫХ данных: одно
  /// из задачи, другое из заказа. Пока они расходились хоть в одном поле
  /// ключа, `missingEntries` считал элемент новым и заводил вторую строку
  /// позиции на тот же слот — списки после этого расходились навсегда, а
  /// перетаскивание в МУПЗ не двигало то, что видит рабочий.
  group('WorkplaceQueueEntry.forSlot', () {
    test('stageId прибит к рабочему месту', () {
      final entry = WorkplaceQueueEntry.forSlot(
        workplaceId: 'wp-handle',
        orderId: 'order-1',
        taskId: 'task-1',
        stageGroupKey: 'group-handle',
      );

      expect(entry.stageId, 'wp-handle');
      expect(
        entry.semanticKey,
        ProductionQueueProvider.queueSemanticKeyFor(
          workplaceId: 'wp-handle',
          orderId: 'order-1',
          stageId: 'wp-handle',
          stageGroupKey: 'group-handle',
        ),
      );
    });

    test('два экрана дают один ключ на один слот', () {
      // Рабочее пространство: знает задачу и её группу.
      final fromWorkspace = WorkplaceQueueEntry.forSlot(
        workplaceId: 'wp-handle',
        orderId: 'order-1',
        taskId: 'task-1',
        stageGroupKey: 'group-handle',
      );
      // МУПЗ: та же задача, найденная со стороны заказа.
      final fromProduction = WorkplaceQueueEntry.forSlot(
        workplaceId: ' wp-handle ',
        orderId: ' order-1 ',
        taskId: 'task-1',
        stageGroupKey: ' group-handle ',
      );

      expect(fromWorkspace.semanticKey, fromProduction.semanticKey);
    });

    test('задача другого РМ той же группы ключ не меняет', () {
      // Ровно тот дефект: МУПЗ подставлял в ключ stageId ЧУЖОЙ задачи, взятой
      // из параллельной группы, и слот получал второе имя.
      final own = WorkplaceQueueEntry.forSlot(
        workplaceId: 'wp-handle',
        orderId: 'order-1',
        taskId: 'task-own',
        stageGroupKey: 'group-handle',
      );
      final foreignTask = WorkplaceQueueEntry.forSlot(
        workplaceId: 'wp-handle',
        orderId: 'order-1',
        taskId: 'task-of-other-workplace',
        stageGroupKey: 'group-handle',
      );

      expect(own.semanticKey, foreignTask.semanticKey);
      // Кусается: разное рабочее место — по-прежнему разные слоты.
      final otherWorkplace = WorkplaceQueueEntry.forSlot(
        workplaceId: 'wp-other',
        orderId: 'order-1',
        taskId: 'task-own',
        stageGroupKey: 'group-handle',
      );
      expect(own.semanticKey, isNot(otherWorkplace.semanticKey));
      // И разные этапы одного РМ тоже остаются разными слотами.
      final otherGroup = WorkplaceQueueEntry.forSlot(
        workplaceId: 'wp-handle',
        orderId: 'order-1',
        taskId: 'task-own',
        stageGroupKey: 'group-cutting',
      );
      expect(own.semanticKey, isNot(otherGroup.semanticKey));
    });

    test('элемент с ключом слота не заводит вторую строку позиции', () {
      final existing = _position(
        'wp-handle',
        'order-1',
        1,
        taskId: 'task-1',
        stageId: 'wp-handle',
        stageGroupKey: 'group-handle',
      );
      final entry = WorkplaceQueueEntry.forSlot(
        workplaceId: 'wp-handle',
        orderId: 'order-1',
        taskId: 'task-2', // задачу пересоздали — слот тот же
        stageGroupKey: 'group-handle',
      );

      expect(
        WorkplaceQueuePositionPlanner.missingEntries(
          existing: [existing],
          entries: [entry],
          workplaceId: 'wp-handle',
        ),
        isEmpty,
      );

      // Кусается: элемент другого слота в пропущенные попадает.
      expect(
        WorkplaceQueuePositionPlanner.missingEntries(
          existing: [existing],
          entries: [
            WorkplaceQueueEntry.forSlot(
              workplaceId: 'wp-handle',
              orderId: 'order-2',
              stageGroupKey: 'group-handle',
            ),
          ],
          workplaceId: 'wp-handle',
        ),
        hasLength(1),
      );
    });
  });
}
