import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/order_model.dart';
import 'package:sheet_clone/modules/orders/product_model.dart';

void main() {
  ProductModel product() => ProductModel(
        id: 'product-1',
        type: 'П-пакет',
        quantity: 100,
        width: 10,
        height: 20,
        depth: 30,
        parameters: '',
      );

  test('serializes queue build fields with snake_case keys', () {
    final order = OrderModel(
      id: 'order-1',
      manager: 'Manager',
      customer: 'Customer',
      orderDate: DateTime.utc(2026, 1, 1),
      dueDate: DateTime.utc(2026, 1, 2),
      product: product(),
      queueBuildStatus: QueueBuildStatus.built,
      selectedVStage: 'v-stage',
      selectedPStage: 'p-stage',
      queueSignature: {'product_type_id': 'П-пакет'},
    );

    final map = order.toMap();

    expect(map['queue_build_status'], QueueBuildStatus.built);
    expect(map['selected_v_stage'], 'v-stage');
    expect(map['selected_p_stage'], 'p-stage');
    expect(map['queue_signature'], {'product_type_id': 'П-пакет'});
  });

  test('deserializes queue build fields from snake_case keys', () {
    final order = OrderModel.fromMap({
      'id': 'order-1',
      'manager': 'Manager',
      'customer': 'Customer',
      'order_date': '2026-01-01T00:00:00.000Z',
      'product': product().toMap(),
      'queue_build_status': QueueBuildStatus.outdated,
      'selected_v_stage': 'v-stage',
      'selected_p_stage': 'p-stage',
      'queue_signature': {'has_paint': true},
    });

    expect(order.queueBuildStatus, QueueBuildStatus.outdated);
    expect(order.selectedVStage, 'v-stage');
    expect(order.selectedPStage, 'p-stage');
    expect(order.queueSignature, {'has_paint': true});
  });

  test('copyWith keeps and overrides queue build fields', () {
    final order = OrderModel(
      id: 'order-1',
      manager: 'Manager',
      customer: 'Customer',
      orderDate: DateTime.utc(2026, 1, 1),
      dueDate: null,
      product: product(),
      queueBuildStatus: QueueBuildStatus.notBuilt,
    );

    final updated = order.copyWith(
      queueBuildStatus: QueueBuildStatus.built,
      selectedVStage: 'v-stage',
      selectedPStage: 'p-stage',
      queueSignature: {'has_trimming': false},
    );

    expect(updated.queueBuildStatus, QueueBuildStatus.built);
    expect(updated.selectedVStage, 'v-stage');
    expect(updated.selectedPStage, 'p-stage');
    expect(updated.queueSignature, {'has_trimming': false});
  });
}
