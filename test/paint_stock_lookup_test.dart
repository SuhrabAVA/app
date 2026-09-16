import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/warehouse/paint_stock_lookup.dart';
import 'package:sheet_clone/modules/warehouse/tmc_model.dart';

/// Фактический остаток краски рядом с плановым расходом в задании.
///
/// Показывается ВЕСЬ остаток карточки — свободное, занятое бронями и
/// неприкасаемый запас вместе: рабочий спрашивает «сколько есть», а не
/// «сколько мне дадут».

TmcModel _paint(String description, double quantity) => TmcModel(
      id: description,
      date: '2026-09-11',
      type: 'Краска',
      description: description,
      quantity: quantity,
      unit: 'г',
    );

void main() {
  group('normalizePaintLookupName', () {
    test('регистр и лишние пробелы не мешают сверке', () {
      expect(
        normalizePaintLookupName('  366   Lalu   Зелёный '),
        '366 lalu зелёный',
      );
    });
  });

  group('paintStockIndex', () {
    test('остаток находится по названию', () {
      final index = paintStockIndex([
        _paint('192D Красный', 25000),
        _paint('278 Голубой', 4000),
      ]);

      expect(paintStockFor(index, '192D Красный'), 25000);
      expect(paintStockFor(index, '  192d  красный '), 25000);
    });

    test('тёзки складываются', () {
      // Одна краска, заведённая двумя карточками. Показать только одну —
      // занизить остаток и отправить рабочего на склад зря.
      final index = paintStockIndex([
        _paint('Белила', 1000),
        _paint('белила', 500),
      ]);

      expect(paintStockFor(index, 'Белила'), 1500);
    });

    test('карточка без названия пропускается', () {
      final index = paintStockIndex([_paint('   ', 900)]);
      expect(index, isEmpty);
    });
  });

  group('paintStockFor', () {
    test('нет карточки — null, а не ноль', () {
      // «Не заведена» и «есть, но пусто» — разные новости, и «(0 г)» на
      // первой было бы враньём.
      final index = paintStockIndex([_paint('192D Красный', 25000)]);

      expect(paintStockFor(index, 'Неизвестная'), isNull);
      // Кусается: пустая карточка даёт именно ноль, а не null.
      final withEmpty = paintStockIndex([_paint('Пустая', 0)]);
      expect(paintStockFor(withEmpty, 'Пустая'), 0);
    });

    test('пустой склад не ломает поиск', () {
      expect(paintStockFor(const <String, double>{}, 'Любая'), isNull);
    });
  });
}
