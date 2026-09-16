import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/warehouse/paint_stock_rules.dart';

void main() {
  group('normalizePaintKey', () {
    test('регистр и лишние пробелы к разным краскам не относятся', () {
      expect(normalizePaintKey('  192D   Красный '),
          normalizePaintKey('192d красный'));
    });

    test('разные краски остаются разными', () {
      expect(
        normalizePaintKey('192D Красный') == normalizePaintKey('192D Синий'),
        isFalse,
      );
    });
  });

  group('paintCardDescription', () {
    test('ручной ввод склеивается как «название + цвет»', () {
      expect(
        paintCardDescription(name: '192D', color: 'Красный'),
        '192D Красный',
      );
    });

    test('без цвета остаётся одно название', () {
      expect(paintCardDescription(name: '192D', color: ''), '192D');
    });

    test('запрос заказа побеждает и цвет к нему НЕ приписывается', () {
      // Ровно тот случай, из-за которого заказ залипал: цвет в форме
      // обязателен, но заказ просил имя без цвета.
      expect(
        paintCardDescription(
          name: 'невидимая краска',
          color: 'Красный',
          requestedName: 'невидимая краска',
        ),
        'невидимая краска',
      );
    });

    test('пустой запрос не считается запросом', () {
      expect(
        paintCardDescription(name: '192D', color: 'Синий', requestedName: '  '),
        '192D Синий',
      );
    });
  });

  test('карточка, заведённая по запросу, ВСЕГДА совпадает с заказом', () {
    // Инвариант всей связки: заказ и склад связывает только текст, поэтому
    // созданное по запросу описание обязано дать тот же ключ, что имя в
    // заказе, — при любом имени и любом выбранном цвете.
    const requests = <String>[
      'невидимая краска',
      '192D Красный',
      'Пантон 485 C',
      '  двойной  пробел  ',
      'Красный',
    ];
    for (final requested in requests) {
      for (final color in const ['Красный', 'Синий', '']) {
        final description = paintCardDescription(
          name: 'что угодно',
          color: color,
          requestedName: requested,
        );
        expect(
          normalizePaintKey(description),
          normalizePaintKey(requested),
          reason: 'запрос «$requested», цвет «$color»',
        );
      }
    }
  });
}
