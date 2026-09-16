import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/paint_reservation_rules.dart';

void main() {
  group('outstandingPaintReservation', () {
    test('свежая бронь занимает остаток целиком', () {
      expect(
        outstandingPaintReservation(
          reservedQty: 3000,
          usedQty: 0,
          releasedQty: 0,
        ),
        3000,
      );
    });

    test('израсходованные граммы остаток больше не занимают', () {
      // Регрессия «300i Синий»: склад 3800 г, бронь 17000 г, израсходовано
      // 18500 г. Клиент считал занятыми все 17000 и выдавал доступно −13200 —
      // заказ на эту краску не выходил из «Ожидания материалов» никогда,
      // сколько её ни привези. Списанные граммы уже ушли со склада через
      // paints_writeoffs, вычитать их второй раз нельзя.
      expect(
        outstandingPaintReservation(
          reservedQty: 17000,
          usedQty: 18500,
          releasedQty: 0,
        ),
        0,
      );
    });

    test('возвращённое на склад тоже не занимает', () {
      expect(
        outstandingPaintReservation(
          reservedQty: 16700,
          usedQty: 4001,
          releasedQty: 10199,
        ),
        closeTo(2500, 1e-9),
      );
    });

    test('погашенная бронь даёт ровно ноль, а не отрицательное', () {
      // Отрицательная «бронь» прибавляла бы складу чужие граммы: заказ
      // с перерасходом делал бы соседей обеспеченными на пустом месте.
      expect(
        outstandingPaintReservation(
          reservedQty: 1000,
          usedQty: 1060,
          releasedQty: 0,
        ),
        0,
      );
    });
  });
}
