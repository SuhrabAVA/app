import 'package:flutter_test/flutter_test.dart';
import 'package:app/modules/orders/order_form_rules.dart';
import 'package:app/modules/orders/order_model.dart';
import 'package:app/modules/orders/product_model.dart';

OrderModel _draft({bool hasForm = false, bool isOldForm = false}) => OrderModel(
      id: '1',
      manager: 'm',
      customer: 'c',
      orderDate: DateTime(2026, 1, 1),
      dueDate: null,
      product: ProductModel(id: 'p', type: 't', quantity: 1, width: 1, height: 1, depth: 1),
      hasForm: hasForm,
      isOldForm: isOldForm,
    );

void main() {
  test('первое добавление краски включает форму и new по умолчанию', () {
    final result = applyOrderFormRules(
      draft: _draft(),
      hasPaints: true,
      userManuallySelectedFormType: false,
    );
    expect(result.hasForm, isTrue);
    expect(result.isOldForm, isFalse);
  });

  test('повторное добавление не перезаписывает уже определенную форму', () {
    final result = applyOrderFormRules(
      draft: _draft(hasForm: true, isOldForm: true),
      hasPaints: true,
      userManuallySelectedFormType: false,
    );
    expect(result.hasForm, isTrue);
    expect(result.isOldForm, isTrue);
  });

  test('ручной выбор old не перезаписывается', () {
    final result = applyOrderFormRules(
      draft: _draft(hasForm: true, isOldForm: true),
      hasPaints: true,
      userManuallySelectedFormType: true,
    );
    expect(result.isOldForm, isTrue);
  });

  test('удаление последней краски не выключает hasForm автоматически', () {
    final result = applyOrderFormRules(
      draft: _draft(hasForm: true, isOldForm: false),
      hasPaints: false,
      userManuallySelectedFormType: false,
    );
    expect(result.hasForm, isTrue);
  });
}
