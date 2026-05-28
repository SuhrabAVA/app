import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/order_model.dart';
import 'package:sheet_clone/modules/orders/product_model.dart';
import 'package:sheet_clone/modules/tasks/task_visibility.dart';

void main() {
  OrderModel order({
    required OrderStatus status,
    required bool assignmentCreated,
  }) {
    return OrderModel(
      id: 'order-1',
      manager: 'manager',
      customer: 'customer',
      orderDate: DateTime(2026, 5, 11),
      dueDate: null,
      product: ProductModel(
        id: 'product-1',
        type: 'Пакет',
        quantity: 100,
        width: 10,
        height: 20,
        depth: 5,
      ),
      status: status.name,
      assignmentCreated: assignmentCreated,
    );
  }

  test('hides tasks for saved orders that are not launched yet', () {
    expect(
      isTaskOrderLaunchedForWorkspace(
        order(
          status: OrderStatus.ready_to_start,
          assignmentCreated: false,
        ),
      ),
      isFalse,
    );
    expect(
      isTaskOrderLaunchedForWorkspace(
        order(
          status: OrderStatus.waiting_materials,
          assignmentCreated: false,
        ),
      ),
      isFalse,
    );
    expect(
      isTaskOrderLaunchedForWorkspace(
        order(
          status: OrderStatus.draft,
          assignmentCreated: false,
        ),
      ),
      isFalse,
    );
  });

  test('shows tasks once the order is launched', () {
    expect(
      isTaskOrderLaunchedForWorkspace(
        order(
          status: OrderStatus.in_production,
          assignmentCreated: true,
        ),
      ),
      isTrue,
    );
  });

  test('keeps tasks visible while order data is not loaded locally', () {
    expect(isTaskOrderLaunchedForWorkspace(null), isTrue);
  });
}
