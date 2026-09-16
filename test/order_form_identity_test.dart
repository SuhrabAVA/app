import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/order_model.dart';
import 'package:sheet_clone/modules/orders/product_model.dart';

OrderModel order({String? formId}) => OrderModel(
      id: 'order', manager: 'manager', customer: 'Rommi',
      orderDate: DateTime(2026, 9, 9), dueDate: DateTime(2026, 9, 25),
      product: ProductModel(id: 'product', type: 'В-образный пакет',
          quantity: 20000, width: 29, height: 8, depth: 3.5),
      hasForm: true, isOldForm: true, formId: formId,
      newFormNo: 1671, formSeries: 'Rommi doner 1,5',
    );

void main() {
  test('form identity survives serialization and edits to unrelated fields', () {
    final original = order(formId: '84ad0235-fecc-4911-bfe6-16ed110a2431');
    final loaded = OrderModel.fromMap(original.toMap());
    final edited = loaded.copyWith(comments: 'Updated comment');
    expect(edited.formId, original.formId);
    expect(edited.newFormNo, 1671);
    expect(edited.formSeries, 'Rommi doner 1,5');
    expect(edited.product.toMap(), original.product.toMap());
    expect(edited.toMap(includeNulls: true)['form_id'], original.formId);
  });

  test('older callers without identity do not clear an existing database link', () {
    expect(order().toMap(includeNulls: true).containsKey('form_id'), isFalse);
  });

  test('linked database updates never overwrite warehouse reference snapshots', () {
    final payload = order(formId: '84ad0235-fecc-4911-bfe6-16ed110a2431')
        .toMap(includeNulls: true, canonicalFormReference: true);
    expect(payload['form_id'], isNotNull);
    expect(payload.containsKey('form_series'), isFalse);
    expect(payload.containsKey('new_form_no'), isFalse);
    expect(payload.containsKey('form_code'), isFalse);
    expect(payload['product'], isNotNull);
  });

  test('a copied or resumed order preserves the selected form', () {
    final source = order(formId: '84ad0235-fecc-4911-bfe6-16ed110a2431');
    final resumed = source.copyWith(restartGeneration: 1, status: 'draft');
    expect(OrderModel.fromMap(resumed.toMap()).formId, source.formId);
  });
}
