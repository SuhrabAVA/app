import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/order_model.dart';
import 'package:sheet_clone/modules/orders/paper_reservation_rules.dart';

void main() {
  group('holdsPaperReservation', () {
    test('обеспеченный заказ держит бумагу с «Готов к запуску»', () {
      // Регрессия заказа 323: пришла бумага, пересчёт поднял заказ в
      // готовность — а на складе не ушло в резерв ни метра. Свободного было
      // 1861.74 при потребности 1840, и любой сосед забирал рулон первым.
      expect(
        holdsPaperReservation(
          assignmentCreated: false,
          status: OrderStatus.ready_to_start,
        ),
        isTrue,
      );
      expect(
        holdsPaperReservation(
          assignmentCreated: false,
          status: OrderStatus.in_production,
        ),
        isTrue,
      );
    });

    test('черновик и ожидание материалов бумагу не морозят', () {
      for (final status in <OrderStatus>[
        OrderStatus.draft,
        OrderStatus.waiting_materials,
      ]) {
        expect(
          holdsPaperReservation(assignmentCreated: false, status: status),
          isFalse,
          reason: 'необеспеченный заказу в статусе $status бронь не положена',
        );
      }
    });

    test('запущенный заказ держит бумагу в любом статусе', () {
      // Залипший дозапускной статус у запущенного заказа — сломанное
      // состояние, но метры он уже занял и вернуть их на склад нельзя:
      // бумага физически в цеху.
      for (final status in <OrderStatus>[
        OrderStatus.draft,
        OrderStatus.waiting_materials,
        OrderStatus.ready_to_start,
        OrderStatus.in_production,
      ]) {
        expect(
          holdsPaperReservation(assignmentCreated: true, status: status),
          isTrue,
          reason: 'запущенный заказ в статусе $status обязан держать бронь',
        );
      }
    });

    test('у завершённого заказа брони нет — она списана', () {
      expect(
        holdsPaperReservation(
          assignmentCreated: true,
          status: OrderStatus.completed,
        ),
        isFalse,
      );
      expect(
        holdsPaperReservation(
          assignmentCreated: false,
          status: OrderStatus.completed,
        ),
        isFalse,
      );
    });
  });

  group('sameReservationPlan', () {
    test('тот же состав и метраж — трогать нечего', () {
      expect(
        sameReservationPlan({'p1': 1700, 'p2': 300}, {'p1': 1700, 'p2': 300}),
        isTrue,
      );
    });

    test('изменился метраж — есть что применять', () {
      expect(sameReservationPlan({'p1': 1700}, {'p1': 2000}), isFalse);
      expect(sameReservationPlan({'p1': 1700}, {'p1': 1000}), isFalse);
    });

    test('добавили или убрали бумагу — есть что применять', () {
      expect(sameReservationPlan({'p1': 1700}, {'p1': 1700, 'p2': 5}), isFalse);
      expect(sameReservationPlan({'p1': 1700, 'p2': 5}, {'p1': 1700}), isFalse);
    });

    test('дробный шум не считается изменением', () {
      expect(sameReservationPlan({'p1': 1700}, {'p1': 1700.0000001}), isTrue);
    });
  });

  group('additionalReserveNeeded', () {
    test('потребность не изменилась — новый остаток не нужен', () {
      expect(
        additionalReserveNeeded(alreadyReserved: 1700, plannedQty: 1700),
        0,
      );
    });

    test('потребность выросла — нужен только прирост', () {
      expect(
        additionalReserveNeeded(alreadyReserved: 1700, plannedQty: 2000),
        300,
      );
    });

    test('потребность упала — новый остаток не нужен', () {
      expect(
        additionalReserveNeeded(alreadyReserved: 1700, plannedQty: 1000),
        0,
      );
    });

    test('брони не было — нужен весь метраж', () {
      expect(additionalReserveNeeded(alreadyReserved: 0, plannedQty: 740), 740);
    });
  });

  group('canApplyReservation', () {
    test('перезапись своей же брони проходит при пустом свободном остатке', () {
      // Регрессия ЗК-2026.08.21-5: бронь 1700 м, свободный остаток по чужим
      // заказам меньше потребности — сохранение всё равно должно проходить,
      // потому что заказ ничего не берёт заново.
      expect(
        canApplyReservation(
          alreadyReserved: 1700,
          plannedQty: 1700,
          availableExcludingThisOrder: 1439.76,
        ),
        isTrue,
      );
    });

    test('уменьшение проходит всегда', () {
      expect(
        canApplyReservation(
          alreadyReserved: 1700,
          plannedQty: 1000,
          availableExcludingThisOrder: 0,
        ),
        isTrue,
      );
    });

    test('рост проходит, если прирост есть в свободном остатке', () {
      // Держит 1700, хочет 2000; в остатке (со своей бронью) 2100 — прироста
      // в 300 м хватает.
      expect(
        canApplyReservation(
          alreadyReserved: 1700,
          plannedQty: 2000,
          availableExcludingThisOrder: 2100,
        ),
        isTrue,
      );
    });

    test('рост не проходит, если прироста нет', () {
      expect(
        canApplyReservation(
          alreadyReserved: 1700,
          plannedQty: 2000,
          availableExcludingThisOrder: 1800,
        ),
        isFalse,
      );
    });

    test('новая бронь считается от нуля', () {
      expect(
        canApplyReservation(
          alreadyReserved: 0,
          plannedQty: 740,
          availableExcludingThisOrder: 740,
        ),
        isTrue,
      );
      expect(
        canApplyReservation(
          alreadyReserved: 0,
          plannedQty: 740,
          availableExcludingThisOrder: 739,
        ),
        isFalse,
      );
    });
  });
}
