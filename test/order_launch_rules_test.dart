import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/material_model.dart';
import 'package:sheet_clone/modules/orders/order_launch_rules.dart';
import 'package:sheet_clone/modules/orders/order_model.dart';
import 'package:sheet_clone/modules/orders/product_model.dart';
import 'package:sheet_clone/modules/warehouse/tmc_model.dart';

void main() {
  OrderModel buildOrder({
    String? stageTemplateId,
    OrderStatus status = OrderStatus.ready_to_start,
    bool assignmentCreated = false,
    double productLength = 10,
  }) {
    return OrderModel(
      id: 'order-1',
      manager: 'manager',
      customer: 'customer',
      orderDate: DateTime(2026, 5, 6),
      dueDate: null,
      product: ProductModel(
        id: 'product-1',
        type: 'Пакет',
        quantity: 100,
        width: 10,
        height: 20,
        depth: 5,
        length: productLength,
      ),
      material: const MaterialModel(id: 'material-1', name: 'Бумага'),
      stageTemplateId: stageTemplateId,
      status: status.name,
      assignmentCreated: assignmentCreated,
    );
  }

  const availableMaterial = TmcModel(
    id: 'material-1',
    date: '2026-05-06',
    type: 'paper',
    description: 'Бумага',
    quantity: 20,
    unit: 'м',
  );

  test(
    'allows ready order without stageTemplateId when assignment is not created and material is sufficient',
    () {
      final orderWithoutTemplate = buildOrder();
      final orderWithEmptyTemplate = buildOrder(stageTemplateId: '');

      expect(
        canLaunchOrder(orderWithoutTemplate, const [availableMaterial]),
        isTrue,
      );
      expect(
        canLaunchOrder(orderWithEmptyTemplate, const [availableMaterial]),
        isTrue,
      );
    },
  );

  test('blocks launch when available material is below required length', () {
    final order = buildOrder(stageTemplateId: 'template-1');
    const shortMaterial = TmcModel(
      id: 'material-1',
      date: '2026-05-06',
      type: 'paper',
      description: 'Бумага',
      quantity: 5,
      unit: 'м',
    );

    expect(canLaunchOrder(order, const [shortMaterial]), isFalse);
  });

  test('blocks launch when assignment was already created', () {
    final order = buildOrder(assignmentCreated: true);

    expect(canLaunchOrder(order, const [availableMaterial]), isFalse);
  });
}
