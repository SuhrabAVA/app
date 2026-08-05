import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/order_model.dart';
import 'package:sheet_clone/modules/orders/product_model.dart';
// uuid берём из реестра: production_ids_test запрещает литералы в test/,
// иначе опечатка в тесте маскировала бы верную реализацию.
import 'package:sheet_clone/modules/orders/production_ids.dart';

/// Ключ `product_type_id` попадает в payload ТОЛЬКО когда значение известно.
///
/// В откачённой ветке клиент слал `product_type_id: null` при неизвестном типе,
/// и сохранение заказа стирало уже проставленную колонку. Особенно опасен
/// `toMap(includeNulls: true)`: его использует
/// `OrdersProvider.updateOrder`, и по общему шаблону `if (includeNulls || …)`
/// ключ ушёл бы с null на каждом сохранении.
void main() {
  OrderModel buildOrder({String? productTypeId}) {
    return OrderModel(
      id: 'order-1',
      manager: 'Менеджер',
      customer: 'Заказчик',
      orderDate: DateTime.utc(2026, 8, 5),
      dueDate: DateTime.utc(2026, 8, 12),
      product: ProductModel(
        id: 'product-1',
        type: 'Листы',
        quantity: 1000,
        width: 100,
        height: 200,
        depth: 50,
      ),
      productTypeId: productTypeId,
    );
  }

  group('OrderModel.toMap → product_type_id', () {
    test('тип не выбран: ключа нет в payload', () {
      final payload = buildOrder().toMap();
      expect(payload.containsKey('product_type_id'), isFalse);
    });

    test('тип не выбран + includeNulls: ключа всё равно нет', () {
      // Главный случай: updateOrder пишет именно так.
      final payload = buildOrder().toMap(includeNulls: true);
      expect(payload.containsKey('product_type_id'), isFalse);
    });

    test('тип выбран: ключ есть и несёт uuid', () {
      const id = ptSheetUuid;
      final payload = buildOrder(productTypeId: id).toMap();
      expect(payload['product_type_id'], id);
    });

    test('тип выбран + includeNulls: ключ есть', () {
      const id = ptSheetUuid;
      final payload = buildOrder(productTypeId: id).toMap(includeNulls: true);
      expect(payload['product_type_id'], id);
    });
  });

  group('OrderModel.fromMap → product_type_id', () {
    test('пустая строка читается как «значение неизвестно»', () {
      final order = OrderModel.fromMap({
        'id': 'order-1',
        'manager': '',
        'customer': '',
        'order_date': DateTime.utc(2026, 8, 5).toIso8601String(),
        'product': {'type': 'Листы'},
        'product_type_id': '   ',
      });
      expect(order.productTypeId, isNull);
      expect(order.toMap(includeNulls: true).containsKey('product_type_id'),
          isFalse);
    });

    test('значение из БД переживает round-trip', () {
      const id = ptPPackageUuid;
      final order = OrderModel.fromMap({
        'id': 'order-1',
        'manager': '',
        'customer': '',
        'order_date': DateTime.utc(2026, 8, 5).toIso8601String(),
        'product': {'type': 'П-образный пакет'},
        'product_type_id': id,
      });
      expect(order.productTypeId, id);
      expect(order.toMap()['product_type_id'], id);
    });
  });
}
