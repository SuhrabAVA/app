import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/material_model.dart';
import 'package:sheet_clone/modules/orders/order_model.dart';
import 'package:sheet_clone/modules/orders/product_model.dart';
import 'package:sheet_clone/modules/tasks/tasks_screen.dart';

void main() {
  group('task paper length initial quantity helpers', () {
    test('recognizes meter units with normalized case and spaces', () {
      expect(isTaskMeterUnit(' м '), isTrue);
      expect(isTaskMeterUnit('  M  '), isTrue);
      expect(isTaskMeterUnit(' Meter '), isTrue);
      expect(isTaskMeterUnit('meters'), isTrue);
      expect(isTaskMeterUnit('шт'), isFalse);
    });

    test('uses one paper L=4500 from normalized materials', () {
      final order = _orderWithMaterials([
        const MaterialModel(name: 'Paper', quantity: 4500, unit: 'м'),
      ]);

      expect(
        initialTaskMeterQuantityForOrder(unit: 'м', order: order),
        4500,
      );
    });

    test('sums two papers L=3000+2000 from normalized materials', () {
      final order = _orderWithMaterials([
        const MaterialModel(name: 'Paper 1', quantity: 3000, unit: 'м'),
        const MaterialModel(name: 'Paper 2', quantity: 2000, unit: 'м'),
      ]);

      expect(
        initialTaskMeterQuantityForOrder(unit: 'meters', order: order),
        5000,
      );
    });

    test('does not provide initial quantity for non-meter unit', () {
      final order = _orderWithMaterials([
        const MaterialModel(name: 'Paper', quantity: 4500, unit: 'м'),
      ]);

      expect(
        initialTaskMeterQuantityForOrder(unit: 'шт', order: order),
        isNull,
      );
    });

    test('does not provide initial quantity when L is absent', () {
      final order = _orderWithMaterials([
        const MaterialModel(name: 'Paper', unit: 'м'),
      ]);

      expect(
        initialTaskMeterQuantityForOrder(unit: 'м', order: order),
        isNull,
      );
    });
  });
}

OrderModel _orderWithMaterials(List<MaterialModel> materials) {
  return OrderModel(
    id: 'order-1',
    manager: 'manager',
    customer: 'customer',
    orderDate: DateTime(2026),
    dueDate: null,
    product: ProductModel(
      id: 'product-1',
      type: 'product',
      quantity: 1,
      width: 0,
      height: 0,
      depth: 0,
    ),
    paperMaterials: materials,
  );
}
