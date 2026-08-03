import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/production/production_queue_provider.dart';

WorkplaceQueuePosition pos({
  String id = 'p1',
  String workplaceId = 'wp-1',
  String? taskId,
  String orderId = 'order-1',
  String stageId = 'stage-1',
  String? stageGroupKey,
  int queuePosition = 1,
  bool hasQueuePosition = true,
}) {
  return WorkplaceQueuePosition(
    id: id,
    workplaceId: workplaceId,
    taskId: taskId,
    orderId: orderId,
    stageId: stageId,
    stageGroupKey: stageGroupKey,
    queuePosition: queuePosition,
    hasQueuePosition: hasQueuePosition,
  );
}

Map<String, Map<String, WorkplaceQueuePosition>> snapshot(
  List<WorkplaceQueuePosition> positions,
) {
  final result = <String, Map<String, WorkplaceQueuePosition>>{};
  for (final position in positions) {
    result.putIfAbsent(
      position.workplaceId,
      () => <String, WorkplaceQueuePosition>{},
    )[position.queueKey] = position;
  }
  return result;
}

void main() {
  group('positionsEqual', () {
    test('одинаковые поля — равны, хотя это разные объекты', () {
      final left = pos();
      final right = pos();
      expect(identical(left, right), isFalse);
      expect(left == right, isFalse, reason: 'у модели нет своего ==');
      expect(ProductionQueueProvider.positionsEqual(left, right), isTrue);
    });

    test('различие в queue_position ловится', () {
      expect(
        ProductionQueueProvider.positionsEqual(
          pos(queuePosition: 1),
          pos(queuePosition: 2),
        ),
        isFalse,
      );
    });

    test('различие в hasQueuePosition ловится', () {
      expect(
        ProductionQueueProvider.positionsEqual(
          pos(hasQueuePosition: true),
          pos(hasQueuePosition: false),
        ),
        isFalse,
      );
    });

    test('различие в nullable-полях ловится', () {
      expect(
        ProductionQueueProvider.positionsEqual(
          pos(taskId: null),
          pos(taskId: 't-1'),
        ),
        isFalse,
      );
      expect(
        ProductionQueueProvider.positionsEqual(
          pos(stageGroupKey: null),
          pos(stageGroupKey: 'group-1'),
        ),
        isFalse,
      );
    });

    test('различие в id ловится (строка пересоздана на сервере)', () {
      expect(
        ProductionQueueProvider.positionsEqual(pos(id: 'a'), pos(id: 'b')),
        isFalse,
      );
    });
  });

  group('positionSnapshotsMatch', () {
    test('пустой → пустой: изменений нет', () {
      expect(
        ProductionQueueProvider.positionSnapshotsMatch(snapshot([]), snapshot([])),
        isTrue,
      );
    });

    test('пустой → непустой: изменение', () {
      expect(
        ProductionQueueProvider.positionSnapshotsMatch(
          snapshot([]),
          snapshot([pos()]),
        ),
        isFalse,
      );
    });

    test('непустой → пустой: изменение', () {
      expect(
        ProductionQueueProvider.positionSnapshotsMatch(
          snapshot([pos()]),
          snapshot([]),
        ),
        isFalse,
      );
    });

    test('идентичные снимки: нотификации быть не должно', () {
      final left = snapshot([
        pos(id: 'a', taskId: 't-1', queuePosition: 1),
        pos(id: 'b', taskId: 't-2', queuePosition: 2),
        pos(id: 'c', workplaceId: 'wp-2', taskId: 't-3', queuePosition: 1),
      ]);
      final right = snapshot([
        pos(id: 'a', taskId: 't-1', queuePosition: 1),
        pos(id: 'b', taskId: 't-2', queuePosition: 2),
        pos(id: 'c', workplaceId: 'wp-2', taskId: 't-3', queuePosition: 1),
      ]);
      expect(
        ProductionQueueProvider.positionSnapshotsMatch(left, right),
        isTrue,
      );
    });

    test('изменение одной позиции внутри рабочего места', () {
      final left = snapshot([
        pos(id: 'a', taskId: 't-1', queuePosition: 1),
        pos(id: 'b', taskId: 't-2', queuePosition: 2),
      ]);
      final right = snapshot([
        pos(id: 'a', taskId: 't-1', queuePosition: 1),
        pos(id: 'b', taskId: 't-2', queuePosition: 5),
      ]);
      expect(
        ProductionQueueProvider.positionSnapshotsMatch(left, right),
        isFalse,
      );
    });

    test('добавление позиции в существующее рабочее место', () {
      final left = snapshot([pos(id: 'a', taskId: 't-1')]);
      final right = snapshot([
        pos(id: 'a', taskId: 't-1'),
        pos(id: 'b', taskId: 't-2', queuePosition: 2),
      ]);
      expect(
        ProductionQueueProvider.positionSnapshotsMatch(left, right),
        isFalse,
      );
    });

    test('добавление нового рабочего места', () {
      final left = snapshot([pos(id: 'a', taskId: 't-1')]);
      final right = snapshot([
        pos(id: 'a', taskId: 't-1'),
        pos(id: 'b', workplaceId: 'wp-2', taskId: 't-2'),
      ]);
      expect(
        ProductionQueueProvider.positionSnapshotsMatch(left, right),
        isFalse,
      );
    });

    test('замена позиции на другую с тем же ключом очереди', () {
      final left = snapshot([pos(id: 'a', taskId: 't-1', queuePosition: 1)]);
      final right = snapshot([pos(id: 'z', taskId: 't-1', queuePosition: 1)]);
      expect(
        left.values.first.keys.toSet(),
        right.values.first.keys.toSet(),
        reason: 'ключи очереди совпадают — различие только в id строки',
      );
      expect(
        ProductionQueueProvider.positionSnapshotsMatch(left, right),
        isFalse,
      );
    });

    test('одинаковое число рабочих мест, но разные их идентификаторы', () {
      final left = snapshot([pos(id: 'a', workplaceId: 'wp-1')]);
      final right = snapshot([pos(id: 'a', workplaceId: 'wp-2')]);
      expect(
        ProductionQueueProvider.positionSnapshotsMatch(left, right),
        isFalse,
      );
    });
  });
}
