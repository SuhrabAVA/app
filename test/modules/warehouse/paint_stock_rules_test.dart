import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/warehouse/paint_stock_rules.dart';

void main() {
  group('availablePaintGrams', () {
    test('неприкасаемые 5 кг из свободного остатка вычтены', () {
      expect(availablePaintGrams(stockGrams: 12000), 7000);
    });

    test('склад ровно 5 кг — свободно ноль', () {
      expect(availablePaintGrams(stockGrams: 5000), 0);
    });

    test('склад ниже запаса — ноль, а не минус', () {
      expect(availablePaintGrams(stockGrams: 3000), 0);
    });

    test('чужие брони вычитаются вместе с запасом', () {
      expect(
        availablePaintGrams(stockGrams: 20000, reservedByOthersGrams: 8000),
        7000,
      );
    });

    test('запас вычитается ОДИН раз, а не по 5 кг на каждый заказ', () {
      // Три заказа по 3000 г из склада 20000: свободного должно остаться
      // 20000 - 9000 - 5000 = 6000, а не 20000 - 9000 - 15000.
      expect(
        availablePaintGrams(stockGrams: 20000, reservedByOthersGrams: 9000),
        6000,
      );
    });
  });

  group('hasEnoughPaint', () {
    test('заказ на весь остаток сверх запаса проходит', () {
      expect(hasEnoughPaint(neededGrams: 7000, stockGrams: 12000), isTrue);
    });

    test('заказ, залезающий в запас хотя бы на грамм, не проходит', () {
      expect(hasEnoughPaint(neededGrams: 7001, stockGrams: 12000), isFalse);
    });

    test('краски на складе нет вовсе', () {
      expect(hasEnoughPaint(neededGrams: 100, stockGrams: 0), isFalse);
    });
  });

  group('paintGramsToPurchase', () {
    test('краски нет на складе: потребность плюс обязательные 5 кг', () {
      expect(paintGramsToPurchase(neededGrams: 3000, stockGrams: 0), 8000);
    });

    test('часть краски есть — докупить только недостающее', () {
      expect(paintGramsToPurchase(neededGrams: 3000, stockGrams: 6000), 2000);
    });

    test('краски хватает — докупать нечего', () {
      expect(paintGramsToPurchase(neededGrams: 3000, stockGrams: 9000), 0);
    });

    test('чужие брони увеличивают закупку', () {
      expect(
        paintGramsToPurchase(
          neededGrams: 3000,
          stockGrams: 9000,
          reservedByOthersGrams: 2000,
        ),
        1000,
      );
    });
  });

  group('запас и пополнение', () {
    test('просевший запас требует пополнения', () {
      expect(needsReplenishment(3200), isTrue);
      expect(replenishmentGrams(3200), 1800);
    });

    test('полный запас пополнять не нужно', () {
      expect(needsReplenishment(5000), isFalse);
      expect(replenishmentGrams(5000), 0);
      expect(replenishmentGrams(9000), 0);
    });

    test('свободное сверх запаса считается от 5 кг', () {
      expect(freeAbovePaintReserveGrams(12000), 7000);
      expect(freeAbovePaintReserveGrams(5000), 0);
      expect(freeAbovePaintReserveGrams(1200), 0);
    });

    test('запас закрыт для заказа, но не для склада', () {
      // Инвариант правила: под заказ 5 кг не отдаются никогда, а ручное
      // списание со склада ими распоряжается — кладовщик отвечает за
      // физическую банку. Разъедься эти две трактовки, и либо заказ начнёт
      // съедать неснижаемый остаток, либо кладовщик не спишет пролитую краску.
      expect(availablePaintGrams(stockGrams: 5000), 0);
      expect(hasEnoughPaint(neededGrams: 1, stockGrams: 5000), isFalse);
      // Со склада те же 5000 доступны целиком: потолок ручного списания —
      // складской остаток за вычетом брони заказов, запас в него не входит.
      expect(freeAbovePaintReserveGrams(5000), 0);
    });
  });

  group('сообщение об отсутствующей краске', () {
    test('текст называет закупку, потребность и запас', () {
      final msg = missingPaintShortageMessage(
        paintName: '192D Красный',
        neededGrams: 3000,
      );
      expect(msg, contains('«192D Красный»'));
      expect(msg, contains('8000 г'));
      expect(msg, contains('3000 г'));
      expect(msg, contains('5000 г'));
    });

    test('карточка узнаёт свой же текст и достаёт название краски', () {
      final msg = missingPaintShortageMessage(
        paintName: '192D Красный',
        neededGrams: 3000,
      );
      expect(missingPaintNamesFromShortage(msg), ['192D Красный']);
    });

    test('несколько красок разбираются все, без дублей', () {
      final msg = [
        missingPaintShortageMessage(paintName: 'Синий', neededGrams: 100),
        missingPaintShortageMessage(paintName: 'Жёлтый', neededGrams: 200),
        missingPaintShortageMessage(paintName: 'Синий', neededGrams: 100),
      ].join(' ');
      expect(missingPaintNamesFromShortage(msg), ['Синий', 'Жёлтый']);
    });

    test('обычная нехватка отсутствующей краской не считается', () {
      expect(
        missingPaintNamesFromShortage(
          'Не хватает 200 г краски «Синий»: доступно 100 из 300.',
        ),
        isEmpty,
      );
      expect(missingPaintNamesFromShortage(''), isEmpty);
      expect(missingPaintNamesFromShortage(null), isEmpty);
    });
  });

  group('formatPaintGrams', () {
    test('целые без хвоста, дробные с двумя знаками', () {
      expect(formatPaintGrams(5000), '5000 г');
      expect(formatPaintGrams(1234.5), '1234.5 г');
    });
  });
}
