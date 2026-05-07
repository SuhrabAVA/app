import 'package:flutter_test/flutter_test.dart';
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
}
