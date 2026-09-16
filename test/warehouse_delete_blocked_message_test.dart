import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/warehouse/paint_deletion_rules.dart';

/// Отказ базы по внешнему ключу кладовщик должен читать словами.
///
/// До этого на экране появлялся сырой PostgrestException — из него не следует
/// ни причина, ни действие, и кладовщик жал «удалить» повторно.
void main() {
  group('warehouseDeleteBlockedMessage', () {
    const pendingWriteoffs =
        'PostgrestException(message: update or delete on table "paints" '
        'violates foreign key constraint '
        '"order_paint_pending_writeoffs_paint_id_fkey" on table '
        '"order_paint_pending_writeoffs", code: 23503)';

    test('называет причину по таблице из текста ошибки', () {
      final message = warehouseDeleteBlockedMessage(pendingWriteoffs);

      expect(message, isNotNull);
      expect(message, contains('переходящих списаний'));
      expect(message, isNot(contains('PostgrestException')));
    });

    test('незнакомая таблица — общая фраза, но не сырая ошибка', () {
      final message = warehouseDeleteBlockedMessage(
        'PostgrestException(message: violates foreign key constraint '
        '"some_future_table_paint_id_fkey" on table "some_future_table", '
        'code: 23503)',
      );

      expect(message, isNotNull);
      expect(message, contains('ссылаются другие записи'));
    });

    test('чужая ошибка не перехватывается', () {
      // Кусается: без этой проверки любая ошибка удаления выглядела бы как
      // отказ по ссылке, и настоящая причина терялась бы.
      expect(
        warehouseDeleteBlockedMessage(
          'PostgrestException(message: JWT expired, code: PGRST301)',
        ),
        isNull,
      );
      expect(warehouseDeleteBlockedMessage('TimeoutException after 25s'), isNull);
    });

    test('узнаёт и бумагу, не только краски', () {
      expect(
        warehouseDeleteBlockedMessage(
          'violates foreign key constraint "x" on table '
          '"order_paper_reservations", code: 23503',
        ),
        contains('брони заказов'),
      );
    });
  });
}
