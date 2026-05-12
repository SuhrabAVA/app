import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/order_model.dart';
import 'package:sheet_clone/modules/orders/product_model.dart';
import 'package:sheet_clone/modules/production/production_order_visibility.dart';

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

  OrderModel order({required OrderStatus status, DateTime? shippedAt}) =>
      OrderModel(
        id: 'order-1',
        manager: 'Manager',
        customer: 'Customer',
        orderDate: DateTime.utc(2026, 1, 1),
        dueDate: null,
        product: product(),
        status: status.name,
        shippedAt: shippedAt,
      );

  test('keeps active production orders in production jobs', () {
    expect(
      isOrderVisibleInProductionJobs(
        order(status: OrderStatus.in_production),
      ),
      isTrue,
    );
  });

  test('keeps completed orders until shipment is registered', () {
    expect(
      isOrderVisibleInProductionJobs(
        order(status: OrderStatus.completed),
      ),
      isTrue,
    );
  });

  test('hides completed orders after shipment is registered', () {
    expect(
      isOrderVisibleInProductionJobs(
        order(
          status: OrderStatus.completed,
          shippedAt: DateTime.utc(2026, 5, 12),
        ),
      ),
      isFalse,
    );
  });

  test('does not show pre-production orders in production jobs', () {
    expect(
      isOrderVisibleInProductionJobs(order(status: OrderStatus.ready_to_start)),
      isFalse,
    );
  });
}
