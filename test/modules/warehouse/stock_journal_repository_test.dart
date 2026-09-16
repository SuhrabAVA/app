import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/warehouse/stock_journal_repository.dart';

void main() {
  group('isJournaledStockType', () {
    test('бумага и краска ведутся только через журнал', () {
      // Регрессия: остаток бумаги и краски правился update-ом мимо журнала,
      // и у 68 позиций разошёлся с ним.
      expect(isJournaledStockType('paper'), isTrue);
      expect(isJournaledStockType('paint'), isTrue);
    });

    test('остальные типы склада идут прежним путём', () {
      for (final type in <String?>['stationery', 'pens', 'material', '', null]) {
        expect(isJournaledStockType(type), isFalse, reason: '$type');
      }
    });

    test('названия движений совпадают с аргументом серверной функции', () {
      // stock_cancel_movement принимает ровно writeoff | arrival | inventory,
      // а stock_set_quantity — count | correction.
      expect(StockMovement.values.map((m) => m.name),
          <String>['writeoff', 'arrival', 'inventory']);
      expect(StockCountKind.values.map((k) => k.name),
          <String>['count', 'correction']);
    });
  });
}
