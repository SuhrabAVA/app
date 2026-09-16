/// Что известно об отгрузке заказа — для архива.
///
/// Отгрузку заказ помнит четырьмя полями: `shipped_at`, `shipped_by`,
/// `shipped_qty` и `actual_qty` (сколько произвели). Остаток отдельной
/// колонкой НЕ хранится: при отгрузке он считается на лету
/// (`leftoverQty = actual − shipped` в `shipOrder`) и уходит на склад в
/// категорию готовой продукции. Поэтому здесь он тоже считается, а не
/// читается — иначе пришлось бы держать в базе поле, которое повторяет
/// разность двух соседних.
///
/// Отгруженный заказ от просто завершённого отличается НЕ статусом: у обоих
/// `completed`. Разделяет их отметка `shipped_at`.
library;

import 'order_model.dart';

/// Сведения об отгрузке одного заказа.
class ShipmentSummary {
  const ShipmentSummary({
    required this.shippedAt,
    required this.shippedBy,
    required this.shippedQty,
    required this.producedQty,
    required this.plannedQty,
  });

  final DateTime shippedAt;

  /// Кто отгрузил. Может быть пустым: у старых отгрузок имя не записывалось.
  final String shippedBy;

  final double? shippedQty;

  /// Сколько произвели (`orders.actual_qty`).
  final double? producedQty;

  /// Тираж по заказу.
  final double plannedQty;

  /// Сколько осталось после отгрузки: произвели минус отгрузили.
  ///
  /// `null`, когда одно из двух чисел неизвестно — тогда честнее промолчать,
  /// чем показать остаток, посчитанный от нуля. Отрицательным не бывает:
  /// отгрузить больше произведённого `shipOrder` не даёт, но у старых записей
  /// числа могли разъехаться, и «минус 40 осталось» — бессмыслица.
  double? get remainingQty {
    final produced = producedQty;
    final shipped = shippedQty;
    if (produced == null || shipped == null) return null;
    final left = produced - shipped;
    return left > 0 ? left : 0;
  }

  /// Осталось ли что-нибудь на складе после отгрузки.
  bool get hasRemainder => (remainingQty ?? 0) > 0;

  /// Расхождение отгрузки с тиражом: плюс — отгрузили больше, минус — меньше.
  double? get deviationFromPlan {
    final shipped = shippedQty;
    if (shipped == null) return null;
    return shipped - plannedQty;
  }
}

/// Сведения об отгрузке заказа, либо `null` — если заказ ещё не отгружен.
ShipmentSummary? shipmentSummaryOf(OrderModel order) {
  final shippedAt = order.shippedAt;
  if (shippedAt == null) return null;
  return ShipmentSummary(
    shippedAt: shippedAt,
    shippedBy: (order.shippedBy ?? '').trim(),
    shippedQty: order.shippedQty,
    producedQty: order.actualQty,
    plannedQty: order.product.quantity.toDouble(),
  );
}

/// Что стало с завершённым заказом — три состояния архива.
///
/// Завершение производства и отгрузка — разные события: заказ месяцами лежит
/// готовым на складе, пока за ним не приедут. Статуса, который бы это
/// различал, у заказа нет (у всех троих `completed`), поэтому состояние
/// выводится из отметок отгрузки и выработки.
enum ArchiveShipmentState {
  /// Товар уехал к заказчику: стоит `shipped_at`.
  shipped,

  /// Не отгружен, но произведён — лежит на складе готовой продукции.
  inStock,

  /// Не отгружен, и произведённое количество неизвестно.
  notShipped,
}

/// Состояние архивного заказа. Отдельная чистая функция, потому что по нему
/// красится бейдж в списке, а «на складе» от «не отгружен» отличает ровно
/// одно: знаем ли мы, что заказ что-то произвёл.
ArchiveShipmentState archiveShipmentStateOf(OrderModel order) {
  if (order.shippedAt != null) return ArchiveShipmentState.shipped;
  final produced = order.actualQty ?? 0;
  return produced > 0
      ? ArchiveShipmentState.inStock
      : ArchiveShipmentState.notShipped;
}

/// Подпись состояния для бейджа.
String archiveShipmentLabel(ArchiveShipmentState state) {
  switch (state) {
    case ArchiveShipmentState.shipped:
      return 'Отгружен';
    case ArchiveShipmentState.inStock:
      return 'На складе';
    case ArchiveShipmentState.notShipped:
      return 'Не отгружен';
  }
}

/// По какой дате фильтруют архив.
///
/// Дат у архивного заказа три, и они расходятся на недели: заказ оформили в
/// августе, доделали в сентябре, отгрузили в октябре. Одной «датой заказа»
/// такой архив не обыскать, поэтому основание выбирается явно.
enum ArchiveDateBasis {
  /// Дата оформления заказа (`order_date`). У возобновлённого из архива
  /// заказа это дата ВОЗОБНОВЛЕНИЯ: новое поколение создаётся сегодняшним
  /// числом.
  created,

  /// Завершение производства (`completed_at`).
  completed,

  /// Отгрузка заказчику (`shipped_at`).
  shipped,
}

/// Дата заказа по выбранному основанию, либо `null` — события ещё не было.
///
/// Заказ без нужной даты из выборки с периодом выпадает: поставить его на шкалу
/// нечем, а подставлять соседнюю дату значило бы соврать («не отгружен» попал
/// бы в отчёт об отгрузках за неделю).
DateTime? archiveDateOf(OrderModel order, ArchiveDateBasis basis) {
  switch (basis) {
    case ArchiveDateBasis.created:
      return order.orderDate;
    case ArchiveDateBasis.completed:
      return order.completedAt;
    case ArchiveDateBasis.shipped:
      return order.shippedAt;
  }
}

/// Подпись основания для кнопки выбора.
String archiveDateBasisLabel(ArchiveDateBasis basis) {
  switch (basis) {
    case ArchiveDateBasis.created:
      return 'Дата создания';
    case ArchiveDateBasis.completed:
      return 'Дата завершения';
    case ArchiveDateBasis.shipped:
      return 'Дата отгрузки';
  }
}

/// Попадает ли заказ в период по выбранному основанию.
///
/// Границы включительные и по КАЛЕНДАРНОМУ дню: `showDateRangePicker` отдаёт
/// полночь, и заказ, отгруженный в тот же день днём, иначе не попал бы в
/// собственный период.
bool archiveOrderInRange(
  OrderModel order,
  ArchiveDateBasis basis,
  DateTime start,
  DateTime end,
) {
  final value = archiveDateOf(order, basis);
  if (value == null) return false;
  final day = DateTime(value.year, value.month, value.day);
  final from = DateTime(start.year, start.month, start.day);
  final to = DateTime(end.year, end.month, end.day);
  return !day.isBefore(from) && !day.isAfter(to);
}

/// Количество без хвоста «.0» у целых: тиражи почти всегда целые.
String formatShipmentQty(double? qty) {
  if (qty == null) return '—';
  final rounded = (qty * 100).round() / 100;
  if (rounded == rounded.roundToDouble()) {
    return rounded.toStringAsFixed(0);
  }
  var text = rounded.toStringAsFixed(2);
  text = text.replaceFirst(RegExp(r'0+$'), '');
  return text.replaceFirst(RegExp(r'\.$'), '');
}

/// Подпись расхождения с тиражом, либо пустая строка — когда всё сошлось.
String formatShipmentDeviation(double? deviation) {
  if (deviation == null) return '';
  final rounded = (deviation * 100).round() / 100;
  if (rounded == 0) return '';
  final sign = rounded > 0 ? '+' : '−';
  return '$sign${formatShipmentQty(rounded.abs())}';
}

/// Кто отгрузил — с прочерком вместо пустоты.
String formatShippedBy(String shippedBy) {
  final name = shippedBy.trim();
  return name.isEmpty ? '—' : name;
}
