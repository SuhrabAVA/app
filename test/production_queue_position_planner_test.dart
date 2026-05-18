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
}
