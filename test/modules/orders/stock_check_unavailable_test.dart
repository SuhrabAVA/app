import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Инвариант: сбой чтения не превращается в вердикт об обеспеченности.
///
/// Проверка обеспеченности ПИШЕТ статус заказа в базу, и он расходится по всем
/// устройствам. Поэтому у неё есть четвёртый исход помимо «обеспечен», «не
/// хватает» и «краски нет на складе» — «не смог проверить», и он обязан
/// оставлять заказ нетронутым. Пока каждый сбой чтения молча возвращал
/// пустой список / `null` / текст ошибки, один и тот же заказ на каждом
/// пересчёте выпадал в новое состояние и карточка мигала между тремя.
void main() {
  final source =
      File('lib/modules/orders/orders_provider.dart').readAsStringSync();

  String bodyOf(String signature, {required String until}) {
    final start = source.indexOf(signature);
    expect(start, greaterThan(-1), reason: 'не найдено: $signature');
    final end = source.indexOf(until, start);
    expect(end, greaterThan(start), reason: 'не найден конец для: $signature');
    return source.substring(start, end);
  }

  test('сбой чтения красок заказа не читается как «красок нет»', () {
    final body = bodyOf(
      'Future<List<_PaintRequirement>> _paintRequirementsForOrder',
      until: 'Future<double?> _fetchPaintAvailableQty',
    );
    final catchBlock = body.substring(body.lastIndexOf('} catch'));

    // Пустой список здесь означал бы «красок в заказе нет» — и заказ уходил
    // бы в «Готов к запуску» вообще без проверки краски.
    expect(catchBlock, contains('_StockCheckUnavailable'));
    expect(catchBlock, isNot(contains('return const <_PaintRequirement>[]')));
  });

  test('сбой чтения остатка краски не читается как «нет на складе»', () {
    final body = bodyOf(
      'Future<double?> _fetchPaintAvailableQty',
      until: 'Future<double?> _fetchPaintStockQty',
    );
    final catchBlock = body.substring(body.lastIndexOf('} catch'));

    // `null` из этой функции печатает «Краска не найдена на складе».
    expect(catchBlock, contains('throw _StockCheckUnavailable'));
    expect(catchBlock, isNot(contains('return null')));
  });

  test('неприкасаемый запас снимается и когда броней нет вовсе', () {
    final body = bodyOf(
      'Future<double?> _fetchPaintAvailableQty',
      until: 'Future<double?> _fetchPaintStockQty',
    );
    final earlyReturn = body.substring(
      body.indexOf('allReserveRows is! List'),
    );
    final firstReturn =
        earlyReturn.substring(0, earlyReturn.indexOf(';') + 1);

    // Ранний выход мимо availablePaintGrams отдавал бы под заказ и те 5 кг.
    expect(firstReturn, isNot(contains('return baseQty')));
    expect(
      earlyReturn.substring(0, earlyReturn.indexOf('}')),
      contains('availablePaintGrams'),
    );
  });

  test('обрыв связи при броне краски не кладёт заказ в ожидание', () {
    final body = bodyOf(
      'Future<String?> _syncPaintReservationsForOrder',
      until: 'Future<String?> _syncPaperReservationsForOrder',
    );

    // Отказ сервера — настоящая нехватка, её текст остаётся.
    expect(body, contains('on PostgrestException'));
    // Всё остальное вердиктом не является.
    final tail = body.substring(body.lastIndexOf('} catch'));
    expect(tail, contains('throw _StockCheckUnavailable'));
  });

  test('оба писателя статуса пропускают заказ, а не пишут догадку', () {
    // Фоновый пересчёт: заказ пропускается, цикл идёт дальше.
    final recheck = bodyOf(
      'for (final order in pending) {',
      until: 'await refresh();',
    );
    expect(recheck, contains('on _StockCheckUnavailable'));
    expect(recheck, contains('continue;'));

    // Пересчёт на сохранении заказа: выходим не записав ничего.
    final immediate = bodyOf(
      'Future<void> _applyImmediateMaterialAvailabilityState',
      until: 'final nextStatus = materialAvailabilityStatus(',
    );
    expect(immediate, contains('on _StockCheckUnavailable'));
    expect(immediate, contains('return;'));
  });
}
