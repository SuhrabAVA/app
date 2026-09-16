import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/order_model.dart';
import 'package:sheet_clone/modules/orders/product_model.dart';
import 'package:sheet_clone/modules/orders/shipment_summary.dart';

OrderModel order({
  String id = 'o1',
  int quantity = 1000,
  DateTime? orderDate,
  DateTime? completedAt,
  DateTime? shippedAt,
  String? shippedBy,
  double? shippedQty,
  double? actualQty,
}) {
  final model = OrderModel(
    id: id,
    manager: 'м',
    customer: 'ТОО Ромашка',
    orderDate: orderDate ?? DateTime(2026, 9, 1),
    dueDate: DateTime(2026, 9, 20),
    product: ProductModel(
      id: 'p-$id',
      type: 'Листы',
      quantity: quantity,
      width: 100,
      height: 100,
      depth: 100,
    ),
  );
  model.completedAt = completedAt;
  model.shippedAt = shippedAt;
  model.shippedBy = shippedBy;
  model.shippedQty = shippedQty;
  model.actualQty = actualQty;
  return model;
}

void main() {
  group('shipmentSummaryOf', () {
    test('неотгруженный заказ сведений об отгрузке не даёт', () {
      // Архив держит и завершённые, но ещё не уехавшие заказы.
      expect(shipmentSummaryOf(order()), isNull);
    });

    test('отгруженный отдаёт кто, когда и сколько', () {
      final summary = shipmentSummaryOf(order(
        shippedAt: DateTime(2026, 9, 8, 14, 30),
        shippedBy: 'Иванова',
        shippedQty: 950,
        actualQty: 1000,
      ))!;
      expect(summary.shippedAt, DateTime(2026, 9, 8, 14, 30));
      expect(summary.shippedBy, 'Иванова');
      expect(summary.shippedQty, 950);
      expect(summary.producedQty, 1000);
    });

    test('пустое имя не превращается в пробелы', () {
      final summary = shipmentSummaryOf(
        order(shippedAt: DateTime(2026, 9, 8), shippedBy: '   '),
      )!;
      expect(summary.shippedBy, isEmpty);
      expect(formatShippedBy(summary.shippedBy), '—');
    });
  });

  group('остаток', () {
    test('произвели больше, чем отгрузили — остаток на складе', () {
      final summary = shipmentSummaryOf(order(
        shippedAt: DateTime(2026, 9, 8),
        shippedQty: 950,
        actualQty: 1000,
      ))!;
      expect(summary.remainingQty, 50);
      expect(summary.hasRemainder, isTrue);
    });

    test('отгрузили всё — остатка нет', () {
      final summary = shipmentSummaryOf(order(
        shippedAt: DateTime(2026, 9, 8),
        shippedQty: 1000,
        actualQty: 1000,
      ))!;
      expect(summary.remainingQty, 0);
      expect(summary.hasRemainder, isFalse);
    });

    test('разъехавшиеся числа не дают отрицательного остатка', () {
      // shipOrder отгрузить больше произведённого не даёт, но у старых
      // записей числа могли разойтись: «минус 40 осталось» — бессмыслица.
      final summary = shipmentSummaryOf(order(
        shippedAt: DateTime(2026, 9, 8),
        shippedQty: 1040,
        actualQty: 1000,
      ))!;
      expect(summary.remainingQty, 0);
      expect(summary.hasRemainder, isFalse);
    });

    test('без факта производства остаток не выдумывается', () {
      final summary = shipmentSummaryOf(order(
        shippedAt: DateTime(2026, 9, 8),
        shippedQty: 950,
      ))!;
      expect(summary.remainingQty, isNull);
      expect(summary.hasRemainder, isFalse);
      expect(formatShipmentQty(summary.remainingQty), '—');
    });

    test('без отметки отгруженного количества остатка тоже нет', () {
      final summary = shipmentSummaryOf(order(
        shippedAt: DateTime(2026, 9, 8),
        actualQty: 1000,
      ))!;
      expect(summary.remainingQty, isNull);
    });
  });

  group('расхождение с тиражом', () {
    test('недовоз', () {
      final summary = shipmentSummaryOf(order(
        quantity: 1000,
        shippedAt: DateTime(2026, 9, 8),
        shippedQty: 950,
      ))!;
      expect(summary.deviationFromPlan, -50);
      expect(formatShipmentDeviation(summary.deviationFromPlan), '−50');
    });

    test('перевоз', () {
      final summary = shipmentSummaryOf(order(
        quantity: 1000,
        shippedAt: DateTime(2026, 9, 8),
        shippedQty: 1020,
      ))!;
      expect(formatShipmentDeviation(summary.deviationFromPlan), '+20');
    });

    test('сошлось — подписи нет', () {
      final summary = shipmentSummaryOf(order(
        quantity: 1000,
        shippedAt: DateTime(2026, 9, 8),
        shippedQty: 1000,
      ))!;
      expect(formatShipmentDeviation(summary.deviationFromPlan), isEmpty);
    });

    test('нечего сравнивать — подписи нет', () {
      expect(formatShipmentDeviation(null), isEmpty);
    });
  });

  group('форматирование количеств', () {
    test('целые без хвоста', () {
      expect(formatShipmentQty(1000), '1000');
      expect(formatShipmentQty(1000.0), '1000');
    });

    test('дробные сохраняются', () {
      expect(formatShipmentQty(12.5), '12.5');
    });

    test('нет значения — прочерк', () {
      expect(formatShipmentQty(null), '—');
    });
  });

  group('archiveShipmentStateOf', () {
    test('есть отметка отгрузки — заказ уехал', () {
      expect(
        archiveShipmentStateOf(order(
          shippedAt: DateTime(2026, 9, 8),
          shippedQty: 900,
          actualQty: 1000,
        )),
        ArchiveShipmentState.shipped,
      );
    });

    test('произведён, но не отгружен — лежит на складе', () {
      expect(
        archiveShipmentStateOf(order(actualQty: 1000)),
        ArchiveShipmentState.inStock,
      );
    });

    test('выработка неизвестна — просто не отгружен', () {
      expect(
        archiveShipmentStateOf(order()),
        ArchiveShipmentState.notShipped,
      );
      // Нулевая выработка складом не считается: класть на склад нечего.
      expect(
        archiveShipmentStateOf(order(actualQty: 0)),
        ArchiveShipmentState.notShipped,
      );
    });

    test('отгрузка перевешивает выработку', () {
      // Проверка на укус: у отгруженного заказа actual_qty тоже стоит, и
      // порядок проверок решает, каким бейджем он покажется.
      expect(
        archiveShipmentStateOf(
          order(shippedAt: DateTime(2026, 9, 8), actualQty: 1000),
        ),
        isNot(ArchiveShipmentState.inStock),
      );
    });

    test('у каждого состояния своя подпись', () {
      final labels = ArchiveShipmentState.values
          .map(archiveShipmentLabel)
          .toList(growable: false);
      expect(labels.toSet().length, ArchiveShipmentState.values.length);
      expect(
        archiveShipmentLabel(ArchiveShipmentState.inStock),
        'На складе',
      );
    });
  });

  group('archiveDateOf', () {
    final sample = order(
      orderDate: DateTime(2026, 8, 1),
      completedAt: DateTime(2026, 8, 20),
      shippedAt: DateTime(2026, 9, 5),
    );

    test('каждое основание берёт свою дату', () {
      expect(archiveDateOf(sample, ArchiveDateBasis.created),
          DateTime(2026, 8, 1));
      expect(archiveDateOf(sample, ArchiveDateBasis.completed),
          DateTime(2026, 8, 20));
      expect(archiveDateOf(sample, ArchiveDateBasis.shipped),
          DateTime(2026, 9, 5));
    });

    test('три основания дают три разные даты', () {
      // Проверка на укус: если бы «завершение» читалось из shipped_at, фильтр
      // по нему просто повторял бы фильтр по отгрузке.
      final dates = ArchiveDateBasis.values
          .map((basis) => archiveDateOf(sample, basis))
          .toSet();
      expect(dates.length, ArchiveDateBasis.values.length);
    });

    test('события не было — даты нет', () {
      final fresh = order(orderDate: DateTime(2026, 8, 1));
      expect(archiveDateOf(fresh, ArchiveDateBasis.completed), isNull);
      expect(archiveDateOf(fresh, ArchiveDateBasis.shipped), isNull);
    });

    test('у каждого основания своя подпись', () {
      final labels = ArchiveDateBasis.values
          .map(archiveDateBasisLabel)
          .toList(growable: false);
      expect(labels.toSet().length, ArchiveDateBasis.values.length);
    });
  });

  group('archiveOrderInRange', () {
    test('границы периода включительные', () {
      final start = DateTime(2026, 9, 1);
      final end = DateTime(2026, 9, 30);
      expect(
        archiveOrderInRange(order(shippedAt: DateTime(2026, 9, 1, 0, 5)),
            ArchiveDateBasis.shipped, start, end),
        isTrue,
      );
      expect(
        archiveOrderInRange(order(shippedAt: DateTime(2026, 9, 30, 23, 59)),
            ArchiveDateBasis.shipped, start, end),
        isTrue,
      );
    });

    test('за пределами периода — мимо', () {
      final start = DateTime(2026, 9, 1);
      final end = DateTime(2026, 9, 30);
      expect(
        archiveOrderInRange(order(shippedAt: DateTime(2026, 8, 31, 23, 59)),
            ArchiveDateBasis.shipped, start, end),
        isFalse,
      );
      expect(
        archiveOrderInRange(order(shippedAt: DateTime(2026, 10, 1)),
            ArchiveDateBasis.shipped, start, end),
        isFalse,
      );
    });

    test('заказ без нужной даты в период не попадает', () {
      // Неотгруженный заказ не должен просачиваться в отчёт об отгрузках за
      // сентябрь только потому, что оформлен он в сентябре.
      expect(
        archiveOrderInRange(
          order(orderDate: DateTime(2026, 9, 10)),
          ArchiveDateBasis.shipped,
          DateTime(2026, 9, 1),
          DateTime(2026, 9, 30),
        ),
        isFalse,
      );
    });
  });
}
