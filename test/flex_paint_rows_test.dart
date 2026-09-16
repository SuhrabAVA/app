import 'package:flutter_test/flutter_test.dart';
import 'package:sheet_clone/modules/orders/flex_paint_rows.dart';

/// Одна строка на один слот списания.
///
/// Из живого случая: зелёная краска ушла в RPC дважды, склад просел на два
/// расхода подряд, и третья проверка отказала с числами, которые не сходились
/// ни с остатком, ни с бронями — «доступно 8300» при складе 85 000, потому что
/// 8300 это остаток ПОСЛЕ двух списаний.

Map<String, dynamic> _row({
  String? pendingId,
  String order = 'order-1',
  String? paintId,
  String? name,
  double amount = 100,
}) =>
    <String, dynamic>{
      if (pendingId != null) 'pending_writeoff_id': pendingId,
      'source_order_id': order,
      if (paintId != null) 'paint_id': paintId,
      if (name != null) 'paint_name': name,
      'actual_used_amount': amount,
    };

void main() {
  group('flexPaintRowKey', () {
    test('очередь опознаётся по id долговой строки', () {
      expect(
        flexPaintRowKey(_row(pendingId: 'debt-1'), pending: true),
        'pending::debt-1',
      );
    });

    test('краска заказа — по паре «заказ + краска»', () {
      expect(
        flexPaintRowKey(_row(paintId: 'p-9'), pending: false),
        'order-1::paint::p-9',
      );
    });

    test('без id краска опознаётся по названию', () {
      // Часть красок вписана текстом и карточки на складе не имеет.
      expect(
        flexPaintRowKey(_row(name: '366 Lalu  Зелёный'), pending: false),
        'order-1::name::366 lalu зелёный',
      );
    });

    test('строка с id и строка с именем — ОДИН слот', () {
      // Тот самый дубль: состав заказа несёт paint_id, а собранная по имени
      // строка его не несёт. Ключ по id разводил их в разные слоты, и краска
      // списывалась дважды.
      expect(
        flexPaintRowKey(
          _row(paintId: 'p-9', name: '366 Lalu Зелёный'),
          pending: false,
        ),
        flexPaintRowKey(_row(name: '366  lalu  зелёный'), pending: false),
      );
    });

    test('разные заказы — разные слоты', () {
      expect(
        flexPaintRowKey(_row(order: 'a', paintId: 'p'), pending: false),
        isNot(flexPaintRowKey(_row(order: 'b', paintId: 'p'), pending: false)),
      );
    });
  });

  group('dedupeFlexPaintRows', () {
    test('повтор слота убирается', () {
      final rows = dedupeFlexPaintRows([
        _row(paintId: 'green', amount: 38350),
        _row(paintId: 'pink', amount: 1650),
        _row(paintId: 'green', amount: 38350),
      ], pending: false);

      expect(rows, hasLength(2));
      expect(
        rows.map((r) => r['paint_id']),
        ['green', 'pink'],
        reason: 'порядок сохраняется, дубль уходит',
      );
    });

    test('побеждает последняя копия — в ней ввод оператора', () {
      final rows = dedupeFlexPaintRows([
        _row(paintId: 'green', amount: 35000),
        _row(paintId: 'green', amount: 38350),
      ], pending: false);

      expect(rows.single['actual_used_amount'], 38350);
    });

    test('разные краски одного заказа не схлопываются', () {
      // Кусается: без этого дедуп съел бы законные строки, и заказ списал бы
      // только одну краску из трёх.
      final rows = dedupeFlexPaintRows([
        _row(paintId: 'green'),
        _row(paintId: 'beige'),
        _row(paintId: 'pink'),
      ], pending: false);

      expect(rows, hasLength(3));
    });

    test('долговые строки различаются по своему id', () {
      final rows = dedupeFlexPaintRows([
        _row(pendingId: 'debt-1', paintId: 'green'),
        _row(pendingId: 'debt-2', paintId: 'green'),
        _row(pendingId: 'debt-1', paintId: 'green'),
      ], pending: true);

      expect(rows.map((r) => r['pending_writeoff_id']), ['debt-1', 'debt-2']);
    });

    test('пустой список остаётся пустым', () {
      expect(dedupeFlexPaintRows(const [], pending: false), isEmpty);
    });
  });

  /// Пересечение двух списков — тот самый живой отказ: один и тот же слот
  /// приходил и как краска заказа, и как долг, и списывался дважды.
  group('dropPendingRowsAlreadyInCurrent', () {
    test('долг того же заказа и той же краски убирается', () {
      final pending = dropPendingRowsAlreadyInCurrent(
        currentRows: [_row(order: 'A', paintId: 'green', amount: 38350)],
        pendingRows: [
          _row(pendingId: 'debt-1', order: 'A', paintId: 'green'),
        ],
      );

      expect(pending, isEmpty);
    });

    test('долг ДРУГОГО заказа остаётся — это законное списание', () {
      // Кусается: без этой проверки фильтр съел бы переходящие краски
      // предыдущего заказа, ради которых очередь и существует.
      final pending = dropPendingRowsAlreadyInCurrent(
        currentRows: [_row(order: 'A', paintId: 'green')],
        pendingRows: [
          _row(pendingId: 'debt-1', order: 'B', paintId: 'green'),
        ],
      );

      expect(pending, hasLength(1));
      expect(pending.single['source_order_id'], 'B');
    });

    test('долг по другой краске того же заказа остаётся', () {
      final pending = dropPendingRowsAlreadyInCurrent(
        currentRows: [_row(order: 'A', paintId: 'green')],
        pendingRows: [
          _row(pendingId: 'debt-1', order: 'A', paintId: 'beige'),
        ],
      );

      expect(pending, hasLength(1));
    });

    test('сверка идёт и по названию, когда id нет', () {
      final pending = dropPendingRowsAlreadyInCurrent(
        currentRows: [_row(order: 'A', name: '366 Lalu Зелёный')],
        pendingRows: [
          _row(pendingId: 'debt-1', order: 'A', name: '366  lalu  зелёный'),
        ],
      );

      expect(pending, isEmpty);
    });
  });
}
