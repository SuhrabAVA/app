import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Инвариант: краска отпускается там же, где отпускается бумага.
///
/// Заказ, потерявший право на материал, обязан вернуть на склад и то, и
/// другое. Пока снятие брони краски вызывалось ровно из одного места
/// (удаление заказа), застрявший заказ вечно держал краску, которой сам
/// воспользоваться не мог, и отнимал её у соседей. Побочно это же делало
/// карточку краски неудаляемой навсегда.
void main() {
  final provider =
      File('lib/modules/orders/orders_provider.dart').readAsStringSync();

  test('каждое снятие брони бумаги сопровождается снятием брони краски', () {
    final paperCalls = '_releasePaperReservations('.allMatches(provider).length;
    final paintCalls = '_releasePaintReservations('.allMatches(provider).length;

    // По одному объявлению у каждого метода — остальное вызовы.
    expect(paperCalls, greaterThan(1));
    expect(
      paintCalls,
      paperCalls,
      reason: 'у краски должно быть столько же точек снятия, сколько у бумаги',
    );
  });

  test('снятие идёт по всем причинам потери обеспеченности', () {
    for (final reason in const [
      'queue_not_built',
      'material_quantity_missing',
      'material_shortage',
      'not_ready_to_start',
    ]) {
      final index = provider.indexOf("reason: '$reason'");
      expect(index, greaterThan(-1), reason: 'нет причины $reason');
      // Рядом с каждой причиной снимается и краска: ищем в том же куске.
      final window = provider.substring(
        index,
        (index + 400).clamp(0, provider.length),
      );
      expect(
        window,
        contains('_releasePaintReservations'),
        reason: 'краска не отпускается при $reason',
      );
    }
  });

  test('журнал удаления пишется ПОСЛЕ успеха, а не до', () {
    final screen = File('lib/modules/warehouse/type_table_tabs_screen.dart')
        .readAsStringSync();
    // Якорь уникальный: в файле есть второе, несвязанное место с
    // _deletedEntityTypes.
    final start =
        screen.indexOf("_deletedEntityTypes[typeKey] ?? 'tmc_generic'");
    expect(start, greaterThan(-1));
    final body = screen.substring(start, start + 2000);

    final deleteAt = body.indexOf('.deleteTmc(');
    final archiveAt = body.indexOf('DeletedRecordsRepository.archive');
    expect(deleteAt, greaterThan(-1));
    expect(archiveAt, greaterThan(-1));
    // Три неудачные попытки удалить занятую краску оставили три записи
    // «удалено» о карточке, которая осталась на складе.
    expect(
      deleteAt,
      lessThan(archiveAt),
      reason: 'архивная запись не должна опережать само удаление',
    );
  });

  test('законный отказ показывается пользователю', () {
    final screen = File('lib/modules/warehouse/type_table_tabs_screen.dart')
        .readAsStringSync();
    expect(screen, contains('on PaintInUseException'));
    expect(screen, contains('showSnackBar'));
  });
}
