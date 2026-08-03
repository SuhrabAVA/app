import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/material_model.dart';
import 'package:sheet_clone/modules/orders/order_model.dart';
import 'package:sheet_clone/modules/orders/product_model.dart';
import 'package:sheet_clone/modules/tasks/quantity_status_service.dart';
import 'package:sheet_clone/modules/tasks/task_model.dart';

OrderModel _order({
  required int runSize,
  double? lengthL,
  List<MaterialModel> papers = const [],
  List<String> extras = const [],
}) =>
    OrderModel(
      id: 'o1',
      manager: 'm',
      customer: 'c',
      orderDate: DateTime(2026, 7, 27),
      dueDate: null,
      product: ProductModel(
        id: 'p',
        type: 'Листы',
        quantity: runSize,
        width: 10,
        height: 20,
        depth: 0,
        length: lengthL,
      ),
      paperMaterials: papers,
      additionalParams: extras,
    );

TaskModel _task() => TaskModel(
      id: 't1',
      orderId: 'o1',
      stageId: 'stage',
      status: TaskStatus.inProgress,
    );

void main() {
  group('план в метрах = Длина L, а не списание бумаги', () {
    test('основная бумага: берётся product.length, а не material.quantity', () {
      final order = _order(
        runSize: 12000,
        lengthL: 100,
        papers: [
          MaterialModel(name: 'Тест Подпергамент', quantity: 560, unit: 'м'),
        ],
      );

      expect(
        getExpectedQuantity(order: order, task: _task(), unit: 'м'),
        100,
        reason: 'ранее подставлялось 560 — расход со склада',
      );
    });

    test('явная длина L позиции (extra.lengthL) важнее и product.length, '
        'и списания', () {
      final order = _order(
        runSize: 5000,
        lengthL: 100,
        papers: [
          MaterialModel(
            name: 'Бумага',
            quantity: 320,
            unit: 'м',
            extra: const {'lengthL': 250},
          ),
        ],
      );

      expect(getExpectedQuantity(order: order, task: _task(), unit: 'м'), 250);
    });

    test('несколько бумаг: длины суммируются', () {
      final order = _order(
        runSize: 5000,
        lengthL: 100,
        papers: [
          MaterialModel(name: 'Основная', quantity: 999, unit: 'м'),
          MaterialModel(
            name: 'Вторая',
            quantity: 777,
            unit: 'м',
            extra: const {'lengthL': 40},
          ),
        ],
      );

      expect(getExpectedQuantity(order: order, task: _task(), unit: 'м'), 140);
    });

    test('длина L не задана — остаётся прежний ориентир по списанию', () {
      final order = _order(
        runSize: 5000,
        papers: [
          MaterialModel(name: 'Бумага', quantity: 320, unit: 'м'),
        ],
      );

      expect(getExpectedQuantity(order: order, task: _task(), unit: 'м'), 320);
    });
  });

  group('остальные единицы', () {
    test('шт — план равен тиражу', () {
      final order = _order(
        runSize: 12000,
        lengthL: 100,
        papers: [MaterialModel(name: 'Бумага', quantity: 560, unit: 'м')],
      );

      expect(getExpectedQuantity(order: order, task: _task(), unit: 'шт'), 12000);
    });

    test('уп — план равен тираж ÷ фасовку', () {
      final order = _order(
        runSize: 12000,
        lengthL: 100,
        extras: const ['Подрезка', 'Упаковка: 200'],
      );

      expect(getExpectedQuantity(order: order, task: _task(), unit: 'уп'), 60);
    });

    test('уп — фасовка распознаётся во фразе «по 50 шт»', () {
      final order = _order(
        runSize: 10000,
        extras: const ['Упаковка: по 50 шт'],
      );

      expect(getExpectedQuantity(order: order, task: _task(), unit: 'уп'), 200);
    });

    test('уп — без параметра «Упаковка» плана нет', () {
      final order = _order(runSize: 12000, extras: const ['Подрезка']);

      expect(getExpectedQuantity(order: order, task: _task(), unit: 'уп'), isNull);
    });
  });
}
