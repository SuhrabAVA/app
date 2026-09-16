import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Инвариант: пересчёт обеспеченности не теряет просьб.
///
/// Автоматический переход статуса («краску завели → заказ сам ушёл в „Готов к
/// запуску“») держится ровно на этом. Пересчёт ходит в сеть по каждому заказу
/// и живёт секунды, а запускается из трёх мест: открытие списка заказов,
/// коммит складского движения и кнопка «Завести краску». Пока просьба,
/// пришедшая во время идущего прохода, молча выбрасывалась, заведение краски
/// внутри этого окна не меняло ничего — заказ висел в прежнем статусе до
/// повторного открытия экрана.
void main() {
  final source =
      File('lib/modules/orders/orders_provider.dart').readAsStringSync();

  String slice(String text, String signature, String until) {
    final start = text.indexOf(signature);
    if (start < 0) throw StateError('не найдено: $signature');
    final end = text.indexOf(until, start);
    if (end <= start) throw StateError('не найден конец: $signature');
    return text.substring(start, end);
  }

  final wrapper = slice(
    source,
    'Future<void> recheckMaterialAvailability({bool forceRefresh = false})',
    'Future<void> _runMaterialAvailabilityPass(',
  );

  test('занятый пересчёт запоминает просьбу, а не выбрасывает её', () {
    expect(wrapper, contains('_stockRecheckRequested = true'));
    // Немой выход был здесь: `if (_stockRecheckInProgress) return;`
    expect(
      wrapper,
      isNot(matches(RegExp(r'_stockRecheckInProgress\)\s*return;'))),
    );
  });

  test('после прохода делается ещё один, если просили', () {
    expect(wrapper, contains('_runMaterialAvailabilityPass'));
    expect(wrapper, contains('_stockRecheckRequested'));
    expect(wrapper, matches(RegExp(r'for \(var pass = 0; pass < \d+; pass\+\+\)')));
  });

  test('число проходов ограничено — пересчёт не может крутиться вечно', () {
    final match =
        RegExp(r'pass < (\d+); pass\+\+').firstMatch(wrapper);
    expect(match, isNotNull);
    final cap = int.parse(match!.group(1)!);
    expect(cap, greaterThan(1));
    expect(cap, lessThanOrEqualTo(5));
  });

  test('флаги сбрасываются всегда, даже когда проход упал', () {
    final tail = wrapper.substring(wrapper.indexOf('} finally {'));
    expect(tail, contains('_stockRecheckInProgress = false'));
    expect(tail, contains('_stockRecheckRequested = false'));
  });

  test('заведение краски с карточки заказа запускает пересчёт', () {
    final screen =
        File('lib/modules/orders/orders_screen.dart').readAsStringSync();
    final body = slice(
        screen, 'Future<void> _openPaintCreation', 'Widget _buildOrderCard');
    expect(body, contains('AddEntryDialog'));
    expect(body, contains('recheckMaterialAvailability()'));
  });
}
