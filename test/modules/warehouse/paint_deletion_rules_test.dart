import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/warehouse/paint_deletion_rules.dart';

PaintReservationHold hold({
  String orderId = 'o1',
  String orderLabel = '',
  double reserved = 0,
  double used = 0,
  double released = 0,
}) =>
    PaintReservationHold(
      orderId: orderId,
      orderLabel: orderLabel,
      reservedQty: reserved,
      usedQty: used,
      releasedQty: released,
    );

void main() {
  group('что держит краску', () {
    test('непогашенная бронь держит', () {
      expect(hold(reserved: 3000).holdsPaint, isTrue);
    });

    test('полностью израсходованная — не держит', () {
      // Граммы уже ушли со склада через paints_writeoffs.
      expect(hold(reserved: 3000, used: 3000).holdsPaint, isFalse);
    });

    test('снятая бронь не держит', () {
      // Именно такие строки оставляет release_order_paint_reservations:
      // она зануляет, но не удаляет.
      expect(hold(reserved: 3000, released: 3000).holdsPaint, isFalse);
    });

    test('перерасход не превращается в отрицательную бронь', () {
      expect(hold(reserved: 1000, used: 2500).holdsPaint, isFalse);
      expect(hold(reserved: 1000, used: 2500).outstandingGrams, 0);
    });

    test('частично израсходованная всё ещё держит остаток', () {
      final h = hold(reserved: 3000, used: 1000);
      expect(h.holdsPaint, isTrue);
      expect(h.outstandingGrams, 2000);
    });
  });

  group('можно ли удалить карточку', () {
    test('без броней — можно', () {
      expect(canDeletePaintCard(const <PaintReservationHold>[]), isTrue);
    });

    test('только погашенные строки удалению не мешают', () {
      final holds = [
        hold(orderId: 'a', reserved: 3000, used: 3000),
        hold(orderId: 'b', reserved: 500, released: 500),
      ];
      expect(canDeletePaintCard(holds), isTrue);
      expect(settledPaintHolds(holds).length, 2);
      expect(paintHoldsBlockingDeletion(holds), isEmpty);
    });

    test('хотя бы одна живая бронь — нельзя', () {
      final holds = [
        hold(orderId: 'a', reserved: 3000, used: 3000),
        hold(orderId: 'b', reserved: 800),
      ];
      expect(canDeletePaintCard(holds), isFalse);
      expect(paintHoldsBlockingDeletion(holds).single.orderId, 'b');
      expect(settledPaintHolds(holds).single.orderId, 'a');
    });
  });

  group('текст отказа', () {
    test('называет заказ, чтобы было ясно куда идти', () {
      final message = paintInUseMessage([
        hold(orderId: 'a', orderLabel: 'ЗК-2026.09.08-2', reserved: 800),
      ]);
      expect(message, contains('ЗК-2026.09.08-2'));
      expect(message.toLowerCase(), contains('уберите её из заказа'),
          reason: 'подсказка, что делать');
    });

    test('без номера показывает id, а не пустоту', () {
      final message = paintInUseMessage([hold(orderId: 'abc-123', reserved: 1)]);
      expect(message, contains('abc-123'));
    });

    test('погашенные строки в текст не попадают', () {
      final message = paintInUseMessage([
        hold(orderId: 'a', orderLabel: 'ЗК-1', reserved: 500, released: 500),
        hold(orderId: 'b', orderLabel: 'ЗК-2', reserved: 500),
      ]);
      expect(message, contains('ЗК-2'));
      expect(message, isNot(contains('ЗК-1')));
    });

    test('длинный список сокращается', () {
      final message = paintInUseMessage([
        for (var i = 1; i <= 5; i++)
          hold(orderId: 'o$i', orderLabel: 'ЗК-$i', reserved: 100),
      ]);
      expect(message, contains('и ещё 2'));
    });

    test('без блокирующих броней текста нет', () {
      expect(paintInUseMessage([hold(reserved: 100, used: 100)]), isEmpty);
    });
  });
}
