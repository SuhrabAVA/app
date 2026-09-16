/// Правила удаления карточки краски со склада.
///
/// Удалить краску, которую держит заказ, нельзя — за этим стоит внешний ключ
/// `order_paint_reservations_paint_id_fkey`, и это правильно: иначе бронь
/// осталась бы висеть на несуществующей карточке, а заказ считал бы себя
/// обеспеченным пустотой.
///
/// Но ключ считает СТРОКИ, а держит краску только непогашенный остаток.
/// Строка, у которой `reserved − used − released` уже ноль, не держит ничего:
/// граммы либо израсходованы (и ушли со склада через `paints_writeoffs`), либо
/// возвращены. Такая строка — учётный мусор, и запирать ею склад нельзя.
///
/// Мусор копится сам собой: `release_order_paint_reservations` на сервере
/// ЗАНУЛЯЕТ строки вместо того, чтобы удалять (в отличие от парной
/// `release_order_paper_reservations`, которая делает `delete`). Поэтому
/// краска, однажды побывавшая в заказе, становилась неудаляемой навсегда.
library;

import '../orders/paint_reservation_rules.dart';

/// Одна бронь глазами склада.
class PaintReservationHold {
  const PaintReservationHold({
    required this.orderId,
    required this.orderLabel,
    required this.reservedQty,
    required this.usedQty,
    required this.releasedQty,
  });

  final String orderId;

  /// Как показать заказ человеку («ЗК-2026.09.08-2»); пустая — покажем id.
  final String orderLabel;

  final double reservedQty;
  final double usedQty;
  final double releasedQty;

  double get outstandingGrams => outstandingPaintReservation(
        reservedQty: reservedQty,
        usedQty: usedQty,
        releasedQty: releasedQty,
      );

  /// Держит ли эта строка краску на самом деле.
  bool get holdsPaint => outstandingGrams > 0;

  String get displayName =>
      orderLabel.trim().isNotEmpty ? orderLabel.trim() : orderId;
}

/// Брони, которые реально мешают удалить краску.
List<PaintReservationHold> paintHoldsBlockingDeletion(
  Iterable<PaintReservationHold> holds,
) =>
    holds.where((hold) => hold.holdsPaint).toList(growable: false);

/// Погашенные брони: удалению не мешают, но строку за собой оставляют.
List<PaintReservationHold> settledPaintHolds(
  Iterable<PaintReservationHold> holds,
) =>
    holds.where((hold) => !hold.holdsPaint).toList(growable: false);

/// Можно ли удалить карточку краски.
bool canDeletePaintCard(Iterable<PaintReservationHold> holds) =>
    paintHoldsBlockingDeletion(holds).isEmpty;

/// Текст отказа — с номерами заказов, чтобы было ясно, куда идти.
///
/// Без него удаление молча не срабатывало: ошибка уходила в лог как
/// `UNCAUGHT ZONE ERROR`, а на экране не менялось ничего.
String paintInUseMessage(Iterable<PaintReservationHold> blocking) {
  final holds = paintHoldsBlockingDeletion(blocking);
  if (holds.isEmpty) return '';
  final names = <String>[];
  for (final hold in holds) {
    final name = hold.displayName;
    if (name.isNotEmpty && !names.contains(name)) names.add(name);
  }
  final listed = names.take(3).join(', ');
  final tail = names.length > 3 ? ' и ещё ${names.length - 3}' : '';
  return names.length == 1
      ? 'Краску держит бронь заказа $listed. '
          'Уберите её из заказа — тогда карточку можно будет удалить.'
      : 'Краску держат брони заказов: $listed$tail. '
          'Уберите её из этих заказов — тогда карточку можно будет удалить.';
}

/// Отказ удалить краску, которую держит заказ.
class PaintInUseException implements Exception {
  const PaintInUseException(this.message, {this.orderLabels = const []});

  final String message;
  final List<String> orderLabels;

  @override
  String toString() => message;
}

/// Понятное объяснение отказа по внешнему ключу (23503).
///
/// `null` — это не наш случай, ошибку показывать как есть.
///
/// Нужна потому, что ссылок на карточку склада много и заводятся новые: на
/// экране кладовщика при каждой такой появлялся сырой
/// `PostgrestException(... violates foreign key constraint ...)`, из которого
/// не следует ни причина, ни действие. Имя таблицы в тексте базы —
/// единственное, что отличает случаи, поэтому разбираем именно его.
String? warehouseDeleteBlockedMessage(String rawError) {
  if (!rawError.contains('23503') &&
      !rawError.contains('violates foreign key constraint')) {
    return null;
  }

  const byTable = <String, String>{
    'order_paint_pending_writeoffs':
        'На краску ссылаются записи переходящих списаний.',
    'order_paint_reservations': 'Краску держат брони заказов.',
    'order_paints': 'Краска вписана в заказы.',
    'paints_writeoffs': 'По краске есть история списаний.',
    'order_paper_reservations': 'Бумагу держат брони заказов.',
    'papers_writeoffs': 'По бумаге есть история списаний.',
  };

  for (final entry in byTable.entries) {
    if (rawError.contains(entry.key)) {
      return '${entry.value} Карточку нельзя удалить, пока эти записи '
          'ссылаются на неё. Сообщите техлиду — ссылку нужно ослабить '
          'миграцией, чтобы уборка склада не стирала историю производства.';
    }
  }

  return 'На эту карточку ссылаются другие записи, поэтому удалить её нельзя. '
      'Сообщите техлиду текст ошибки.';
}
