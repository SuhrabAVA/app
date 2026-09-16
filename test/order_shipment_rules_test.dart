import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/order_shipment_rules.dart';

/// Отгрузка частями: сколько отгружено, сколько осталось, когда закрывать.
///
/// Ошибка здесь стоит дорого в обе стороны: недосчитали — заказ навсегда
/// висит в «Завершённых» с остатком в сотую; пересчитали — закрылся раньше,
/// чем товар уехал.

OrderShipment _shipment(double qty, {bool document = false, int day = 1}) =>
    OrderShipment(
      id: 's$qty$day',
      qty: qty,
      shippedAt: DateTime(2026, 9, day, 14, 30),
      shippedBy: 'Расул',
      hasDocument: document,
    );

void main() {
  group('shippedTotal и remainingToShip', () {
    test('без отгрузок отгружено ноль, остаток — весь факт', () {
      expect(shippedTotal(const []), 0);
      expect(
        remainingToShip(actualQty: 5291, shipments: const []),
        5291,
      );
    });

    test('партии складываются', () {
      final shipments = [_shipment(2000), _shipment(1500, day: 3)];

      expect(shippedTotal(shipments), 3500);
      expect(remainingToShip(actualQty: 5291, shipments: shipments), 1791);
    });

    test('перебор по журналу даёт нулевой остаток, а не отрицательный', () {
      // Факт могли пересчитать задним числом. «Минус двести к отгрузке» —
      // это те же ноль, и показывать минус нельзя.
      expect(
        remainingToShip(actualQty: 1000, shipments: [_shipment(1200)]),
        0,
      );
    });
  });

  group('isFullyShipped', () {
    test('добрали до факта — заказ закрыт', () {
      expect(
        isFullyShipped(
          actualQty: 5000,
          shipments: [_shipment(2000), _shipment(3000, day: 5)],
        ),
        isTrue,
      );
    });

    test('не добрали — заказ открыт', () {
      expect(
        isFullyShipped(actualQty: 5000, shipments: [_shipment(4999)]),
        isFalse,
      );
    });

    test('хвост в тысячную не держит заказ открытым', () {
      // Количества дробные, и точное равенство double не срабатывает: без
      // допуска заказ навсегда остался бы с остатком 0.0000001.
      expect(
        isFullyShipped(
          actualQty: 1000.0,
          shipments: [_shipment(333.33), _shipment(333.33, day: 2),
              _shipment(333.34, day: 3)],
        ),
        isTrue,
      );
    });
  });

  group('shipmentClosesOrder', () {
    test('разом закрывает заказ даже при неполном списании', () {
      expect(
        shipmentClosesOrder(
          mode: ShipmentMode.whole,
          actualQty: 5291,
          shipments: const [],
          qty: 5000,
        ),
        isTrue,
      );
    });

    test('частями не закрывает, пока есть остаток', () {
      expect(
        shipmentClosesOrder(
          mode: ShipmentMode.partial,
          actualQty: 5291,
          shipments: const [],
          qty: 5000,
        ),
        isFalse,
      );
    });

    test('частями закрывает, когда списали весь факт', () {
      // Требование заказчика: «выбрал частями, но списал всё — заказ уходит
      // из завершённых». Отдельного случая не нужно, он получается сам.
      expect(
        shipmentClosesOrder(
          mode: ShipmentMode.partial,
          actualQty: 5291,
          shipments: const [],
          qty: 5291,
        ),
        isTrue,
      );
    });

    test('частями закрывает последней партией', () {
      expect(
        shipmentClosesOrder(
          mode: ShipmentMode.partial,
          actualQty: 5000,
          shipments: [_shipment(3000)],
          qty: 2000,
        ),
        isTrue,
      );
    });
  });

  group('shipmentQuantityError', () {
    test('ноль и отрицательное отвергаются', () {
      expect(
        shipmentQuantityError(qty: 0, actualQty: 1000, shipments: const []),
        contains('больше нуля'),
      );
      expect(
        shipmentQuantityError(qty: -5, actualQty: 1000, shipments: const []),
        contains('больше нуля'),
      );
    });

    test('больше остатка нельзя', () {
      final error = shipmentQuantityError(
        qty: 2000,
        actualQty: 5000,
        shipments: [_shipment(4000)],
      );

      expect(error, contains('больше остатка'));
      expect(error, contains('1000'));
    });

    test('ровно остаток можно', () {
      expect(
        shipmentQuantityError(
          qty: 1000,
          actualQty: 5000,
          shipments: [_shipment(4000)],
        ),
        isNull,
      );
    });

    test('полностью отгруженный заказ отгрузить нельзя', () {
      expect(
        shipmentQuantityError(
          qty: 1,
          actualQty: 5000,
          shipments: [_shipment(5000)],
        ),
        contains('уже отгружен'),
      );
    });
  });

  group('тексты для истории', () {
    test('отгрузка называет количество, документ и остаток', () {
      final text = describeShipment(
        qty: 2000,
        hasDocument: true,
        remaining: 3291,
        closed: false,
      );

      expect(text, contains('Отгружено: 2000'));
      expect(text, contains('Документ: есть'));
      expect(text, contains('Осталось: 3291'));
    });

    test('закрывающая отгрузка говорит об этом вместо остатка', () {
      final text = describeShipment(
        qty: 3291,
        hasDocument: false,
        remaining: 0,
        closed: true,
      );

      expect(text, contains('Документ: нет'));
      expect(text, contains('отгружен полностью'));
      expect(text, isNot(contains('Осталось')));
    });

    test('галочка документа тоже описывается словами', () {
      final text = describeDocumentToggle(
        shipment: _shipment(2000, day: 7),
        hasDocument: true,
      );

      expect(text, contains('07.09.2026'));
      expect(text, contains('2000'));
      expect(text, contains('отмечен'));
    });
  });

  group('formatShipmentQty', () {
    test('целое без хвоста, дробное с сотыми', () {
      expect(formatShippedQty(5000), '5000');
      expect(formatShippedQty(1791.5), '1791.5');
      expect(formatShippedQty(0.333), '0.33');
    });
  });
}
