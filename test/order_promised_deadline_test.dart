import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/order_deadline_countdown.dart';
import 'package:sheet_clone/modules/orders/order_model.dart';
import 'package:sheet_clone/modules/orders/product_model.dart';

/// Срок завершения: обещание производства перекрывает срок заказчика.
///
/// `due_date` остаётся нетронутым — иначе исчез бы сам факт сдвига, — а показ
/// везде идёт по `promised_at`, если он назначен.

OrderModel _order({DateTime? dueDate, DateTime? promisedAt}) => OrderModel(
      id: 'o1',
      manager: '',
      customer: 'Заказчик',
      orderDate: DateTime.utc(2026, 9, 1),
      dueDate: dueDate,
      promisedAt: promisedAt,
      product: ProductModel(
        id: 'p',
        type: 'П-пакет',
        quantity: 1000,
        width: 1,
        height: 1,
        depth: 1,
      ),
    );

void main() {
  group('effectiveDeadlineDate', () {
    test('без обещания живёт срок заказчика', () {
      final order = _order(dueDate: DateTime.utc(2026, 9, 17));
      expect(effectiveDeadlineDate(order), DateTime.utc(2026, 9, 17));
      expect(hasManualDeadline(order), isFalse);
    });

    test('обещание перекрывает срок заказчика', () {
      final order = _order(
        dueDate: DateTime.utc(2026, 9, 17),
        promisedAt: DateTime.utc(2026, 9, 20, 9),
      );

      expect(effectiveDeadlineDate(order), DateTime.utc(2026, 9, 20, 9));
      expect(hasManualDeadline(order), isTrue);
      // Кусается: срок заказчика остался на месте, его не переписали.
      expect(order.dueDate, DateTime.utc(2026, 9, 17));
    });

    test('без обоих показывать нечего', () {
      expect(effectiveDeadlineDate(_order()), isNull);
    });
  });

  group('formatDeadlineDate', () {
    test('обычный срок — только дата', () {
      expect(
        formatDeadlineDate(DateTime.utc(2026, 9, 17), manual: false),
        '17.09.2026',
      );
    });

    test('назначенный с временем показывает час', () {
      // 09:00 по Костанаю — это 04:00 UTC.
      expect(
        formatDeadlineDate(DateTime.utc(2026, 9, 20, 4), manual: true),
        '20.09.2026 09:00',
      );
    });

    test('назначенный на полночь времени не показывает', () {
      // Полночь означает «весь день», и «00:00» читалось бы как «к полуночи».
      expect(
        formatDeadlineDate(DateTime.utc(2026, 9, 19, 19), manual: true),
        '20.09.2026',
      );
    });
  });

  group('hasExactPromisedTime', () {
    test('час указан — срок точный', () {
      expect(
        hasExactPromisedTime(_order(promisedAt: DateTime.utc(2026, 9, 20, 4))),
        isTrue,
      );
    });

    test('полночь — это день целиком', () {
      expect(
        hasExactPromisedTime(_order(promisedAt: DateTime.utc(2026, 9, 19, 19))),
        isFalse,
      );
    });

    test('без обещания — нечего уточнять', () {
      expect(hasExactPromisedTime(_order()), isFalse);
    });
  });

  group('countdownForOrder с обещанием', () {
    test('точный час не достраивается до конца дня', () {
      // Обещали к 09:00; до 23:59 того же дня цеху никто не давал.
      final order = _order(promisedAt: DateTime.utc(2026, 9, 20, 4));
      final countdown = countdownForOrder(
        order,
        now: DateTime.utc(2026, 9, 20, 5),
      );

      expect(countdown, isNotNull);
      expect(countdown!.overdue, isTrue, reason: 'час уже прошёл');
    });

    test('день без времени держится до конца дня', () {
      final order = _order(promisedAt: DateTime.utc(2026, 9, 19, 19));
      final countdown = countdownForOrder(
        order,
        now: DateTime.utc(2026, 9, 20, 5),
      );

      expect(countdown!.overdue, isFalse);
    });
  });

  group('describePromisedDateChange', () {
    test('назначение и перенос', () {
      expect(
        describePromisedDateChange(
          before: null,
          after: DateTime.utc(2026, 9, 20, 4),
          dueDate: DateTime.utc(2026, 9, 17),
        ),
        'Срок завершения: не назначен → 20.09.2026 09:00',
      );
    });

    test('снятие называет, к чему вернулись', () {
      // Иначе запись «→ не назначен» не отвечает на вопрос «а когда теперь».
      expect(
        describePromisedDateChange(
          before: DateTime.utc(2026, 9, 20, 4),
          after: null,
          dueDate: DateTime.utc(2026, 9, 17),
        ),
        'Срок завершения снят: 20.09.2026 09:00 → срок заказчика 17.09.2026',
      );
    });

    test('снятие без срока заказчика говорит и об этом', () {
      expect(
        describePromisedDateChange(
          before: DateTime.utc(2026, 9, 20, 4),
          after: null,
          dueDate: null,
        ),
        contains('срок заказчика не указан'),
      );
    });
  });
}
