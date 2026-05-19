import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/order_model.dart';
import 'package:sheet_clone/modules/orders/order_queue_validity.dart';
import 'package:sheet_clone/modules/orders/product_model.dart';

void main() {
  Map<String, dynamic> _signature() => buildQueueSignature(
        product: ProductModel(
          id: 'p1',
          type: 'П-пакет',
          quantity: 100,
          width: 10,
          height: 20,
          depth: 5,
          parameters: '',
        ),
        paperMaterials: const [],
        materialWidth: 100,
        hasPaint: true,
        hasTrimming: false,
        hasCardboard: false,
        handle: '-',
        templateId: 'tpl-1',
      );

  test('built + matching signature => actual queue', () {
    final signature = _signature();
    final actual = isQueueActual(
      currentSignature: signature,
      storedSignature: signature,
      queueBuildStatus: QueueBuildStatus.built,
      stages: const [
        {'stageId': 'print'}
      ],
    );

    expect(actual, isTrue);
  });

  test('built + mismatching signature => outdated queue', () {
    final current = _signature();
    final stored = _signature()..['has_paint'] = false;
    final actual = isQueueActual(
      currentSignature: current,
      storedSignature: stored,
      queueBuildStatus: QueueBuildStatus.built,
      stages: const [
        {'stageId': 'print'}
      ],
    );

    expect(actual, isFalse);
  });

  test('empty queue is never actual', () {
    final signature = _signature();
    final actual = isQueueActual(
      currentSignature: signature,
      storedSignature: signature,
      queueBuildStatus: QueueBuildStatus.built,
      stages: const [],
    );

    expect(actual, isFalse);
  });
}
