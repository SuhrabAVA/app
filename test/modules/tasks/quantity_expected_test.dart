import 'dart:convert';

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

    test('уп — план в штуках, это тираж: упаковщик вводит штуки', () {
      final order = _order(
        runSize: 12000,
        lengthL: 100,
        extras: const ['Подрезка', 'Упаковка: 200'],
      );

      expect(
          getExpectedQuantity(order: order, task: _task(), unit: 'уп'), 12000);
    });

    test('уп — план не зависит от фасовки', () {
      final withPackSize = _order(
        runSize: 10000,
        extras: const ['Упаковка: по 50 шт'],
      );
      final withoutPackSize = _order(runSize: 10000, extras: const ['Подрезка']);

      expect(
        getExpectedQuantity(order: withPackSize, task: _task(), unit: 'уп'),
        10000,
      );
      expect(
        getExpectedQuantity(order: withoutPackSize, task: _task(), unit: 'уп'),
        10000,
      );
    });
  });

  group('упаковки из штук', () {
    test('ввод на упаковке идёт в штуках', () {
      expect(quantityInputUnit('пачка'), 'шт');
      expect(quantityInputUnit('уп'), 'шт');
      expect(quantityInputUnit('м'), 'м');
      expect(quantityInputUnit('шт'), 'шт');
    });

    test('кратное количество — ровно тираж ÷ фасовку', () {
      expect(packCountForPieces(pieces: 12000, packSize: 100), 120);
    });

    test('неполная упаковка засчитывается целой', () {
      expect(packCountForPieces(pieces: 12030, packSize: 100), 121);
      expect(packCountForPieces(pieces: 1, packSize: 100), 1);
    });

    test('недобор тиража округляется так же вверх', () {
      expect(packCountForPieces(pieces: 11970, packSize: 100), 120);
      expect(packCountForPieces(pieces: 11900, packSize: 100), 119);
    });

    test('без фасовки или без количества упаковок нет', () {
      expect(packCountForPieces(pieces: 12030, packSize: null), isNull);
      expect(packCountForPieces(pieces: 12030, packSize: 0), isNull);
      expect(packCountForPieces(pieces: 0, packSize: 100), isNull);
    });

    test('остаток показывает недобор последней упаковки', () {
      expect(packRemainderPieces(pieces: 12030, packSize: 100), 30);
      expect(packRemainderPieces(pieces: 12000, packSize: 100), 0);
      expect(packRemainderPieces(pieces: 12030, packSize: null), 0);
    });
  });

  group('правка количества техлидом', () {
    String payload({
      required double actual,
      String unit = 'шт',
      double? expected,
      double? packSize,
      double? originalActual,
    }) =>
        jsonEncode(<String, dynamic>{
          'actual': actual,
          'unit': unit,
          'expected': expected,
          'quantity_status': 'danger',
          'display': '\$actual \$unit',
          if (packSize != null) 'pack_size': packSize,
          if (originalActual != null) 'original_actual': originalActual,
        });

    test('единица и план сохраняются, статус и подпись пересчитываются', () {
      final result = rebuildQuantityPayload(
        previousText: payload(actual: 500, unit: 'м', expected: 1000),
        newActual: 1000,
        editorId: 'lead-1',
        editedAt: DateTime.utc(2026, 8, 18),
      );
      final decoded = tryDecodeQuantityPayload(result)!;

      expect(decoded['actual'], 1000);
      expect(decoded['unit'], 'м');
      expect(decoded['expected'], 1000);
      expect(decoded['quantity_status'], 'success');
      expect(decoded['display'], '1000 м');
      expect(decoded['edited_by'], 'lead-1');
    });

    test('упаковки пересчитываются от исправленных штук', () {
      final result = rebuildQuantityPayload(
        previousText: payload(actual: 1000, expected: 12000, packSize: 100),
        newActual: 12030,
        editorId: 'lead-1',
        editedAt: DateTime.utc(2026, 8, 18),
      );
      final decoded = tryDecodeQuantityPayload(result)!;

      expect(decoded['actual'], 12030);
      expect(decoded['packs'], 121);
      expect(decoded['pack_size'], 100);
      expect(decoded['display'], '12030 шт · 121 уп');
    });

    test('исходное значение сотрудника не теряется при повторной правке', () {
      final first = rebuildQuantityPayload(
        previousText: payload(actual: 100, expected: 1000),
        newActual: 500,
        editorId: 'lead-1',
        editedAt: DateTime.utc(2026, 8, 18),
      );
      expect(tryDecodeQuantityPayload(first)!['original_actual'], 100);

      final second = rebuildQuantityPayload(
        previousText: first,
        newActual: 900,
        editorId: 'lead-2',
        editedAt: DateTime.utc(2026, 8, 18, 1),
      );
      final decoded = tryDecodeQuantityPayload(second)!;
      expect(decoded['actual'], 900);
      expect(decoded['original_actual'], 100,
          reason: 'первая правка не должна становиться «исходным»');
      expect(decoded['edited_by'], 'lead-2');
    });

    test('старая запись без payload остаётся простым числом', () {
      final result = rebuildQuantityPayload(
        previousText: '123 пачка',
        newActual: 150,
        editorId: 'lead-1',
        editedAt: DateTime.utc(2026, 8, 18),
      );
      expect(result, '150');
      expect(tryDecodeQuantityPayload(result), isNull);
    });
  });
}
