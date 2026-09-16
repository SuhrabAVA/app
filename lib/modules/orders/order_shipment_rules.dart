/// Отгрузка заказа партиями: что уже отгружено и что ещё можно.
///
/// Отгрузка перестала быть одним событием. Тираж забирают частями, и на
/// каждый вопрос — «сколько осталось», «закрыт ли заказ», «можно ли столько» —
/// отвечает журнал отгрузок, а не поле в заказе.
///
/// Здесь только арифметика и правила. Запись, склад и история — снаружи.
library;

/// Как отгружают: разом или частями.
///
/// Разница НЕ в количестве, а в том, что происходит с заказом после. Разом —
/// заказ закрывается и уходит в архив, даже если фактически сделали больше.
/// Частями — закрывается только когда отгружено всё фактическое.
enum ShipmentMode { whole, partial }

/// Одна партия отгрузки — строка `order_shipments`.
class OrderShipment {
  const OrderShipment({
    required this.id,
    required this.qty,
    required this.shippedAt,
    required this.shippedBy,
    this.hasDocument = false,
    this.note,
  });

  final String id;
  final double qty;
  final DateTime shippedAt;

  /// Имя на момент отгрузки — снимок, не ссылка.
  final String shippedBy;

  final bool hasDocument;
  final String? note;

  OrderShipment copyWith({bool? hasDocument}) => OrderShipment(
        id: id,
        qty: qty,
        shippedAt: shippedAt,
        shippedBy: shippedBy,
        hasDocument: hasDocument ?? this.hasDocument,
        note: note,
      );

  static OrderShipment? tryFromMap(Map<String, dynamic> map) {
    final id = (map['id'] ?? '').toString().trim();
    final qty = _toDouble(map['qty']);
    if (id.isEmpty || qty == null || qty <= 0) return null;
    final at = _toDate(map['shipped_at'] ?? map['created_at']);
    if (at == null) return null;
    return OrderShipment(
      id: id,
      qty: qty,
      shippedAt: at,
      shippedBy: (map['shipped_by'] ?? '').toString().trim(),
      hasDocument: map['has_document'] == true,
      note: (map['note'] ?? '').toString().trim().isEmpty
          ? null
          : (map['note'] ?? '').toString().trim(),
    );
  }
}

/// Сколько всего отгружено по журналу.
///
/// Считается по журналу, а не по `orders.shipped_qty`: то поле хранит
/// количество ПОСЛЕДНЕЙ партии, и складывать его с журналом — двойной счёт.
double shippedTotal(Iterable<OrderShipment> shipments) {
  var total = 0.0;
  for (final shipment in shipments) {
    total += shipment.qty;
  }
  return total;
}

/// Сколько ещё можно отгрузить; никогда не отрицательно.
///
/// Отрицательный остаток — это те же ноль: если по журналу отгрузили больше
/// факта (пересчёт факта задним числом), запрещать нечего, но и предлагать
/// «минус двести» нельзя.
double remainingToShip({
  required double actualQty,
  required Iterable<OrderShipment> shipments,
}) {
  final left = actualQty - shippedTotal(shipments);
  return left > 0 ? left : 0;
}

/// Отгружено всё фактическое — заказ пора закрывать.
///
/// Допуск в сотую: количества дробные (метры, килограммы), и точное равенство
/// double здесь не срабатывает — заказ навсегда остался бы открытым с
/// остатком 0.0000001.
bool isFullyShipped({
  required double actualQty,
  required Iterable<OrderShipment> shipments,
}) {
  if (actualQty <= 0) return true;
  return shippedTotal(shipments) >= actualQty - 0.01;
}

/// Закроется ли заказ этой отгрузкой.
///
/// Правило, ради которого режим вообще существует:
///   * разом — закрывается всегда, остаток списывается как лишнее;
///   * частями — только когда добрали до фактического количества. Отсюда и
///     требование заказчика «выбрал частями, но списал весь факт — заказ
///     уходит из завершённых»: считать отдельно этот случай не нужно, он
///     получается сам.
bool shipmentClosesOrder({
  required ShipmentMode mode,
  required double actualQty,
  required Iterable<OrderShipment> shipments,
  required double qty,
}) {
  if (mode == ShipmentMode.whole) return true;
  return isFullyShipped(
    actualQty: actualQty,
    shipments: [
      ...shipments,
      OrderShipment(
        id: '_new',
        qty: qty,
        shippedAt: DateTime.fromMillisecondsSinceEpoch(0),
        shippedBy: '',
      ),
    ],
  );
}

/// Почему столько отгрузить нельзя; `null` — можно.
String? shipmentQuantityError({
  required double qty,
  required double actualQty,
  required Iterable<OrderShipment> shipments,
}) {
  if (qty.isNaN || qty.isInfinite || qty <= 0) {
    return 'Количество для отгрузки должно быть больше нуля.';
  }
  final left = remainingToShip(actualQty: actualQty, shipments: shipments);
  if (left <= 0) {
    return 'Заказ уже отгружен полностью.';
  }
  if (qty > left + 0.01) {
    return 'Нельзя отгрузить больше остатка: '
        'к отгрузке ${formatShippedQty(qty)}, '
        'осталось ${formatShippedQty(left)}.';
  }
  return null;
}

/// Число для показа: без хвоста нулей, но с сотыми, когда они есть.
///
/// Имя отличается от `formatShipmentQty` в `shipment_summary.dart` намеренно:
/// тот принимает `double?` и живёт в отчётах архива. Одноимённые функции в
/// двух библиотеках сделали бы любой файл, импортирующий обе, неспособным
/// сослаться ни на одну из них.
String formatShippedQty(double value) {
  if (value.isNaN || value.isInfinite) return '0';
  if ((value - value.roundToDouble()).abs() < 0.005) {
    return value.round().toString();
  }
  return value
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

/// Строка истории про отгрузку.
String describeShipment({
  required double qty,
  required bool hasDocument,
  required double remaining,
  required bool closed,
}) {
  final parts = <String>[
    'Отгружено: ${formatShippedQty(qty)}',
    hasDocument ? 'Документ: есть' : 'Документ: нет',
    if (!closed) 'Осталось: ${formatShippedQty(remaining)}',
    if (closed) 'Заказ отгружен полностью',
  ];
  return parts.join('\n');
}

/// Строка истории про переключение галочки документа.
String describeDocumentToggle({
  required OrderShipment shipment,
  required bool hasDocument,
}) {
  final when = _formatDateTime(shipment.shippedAt);
  return 'Отгрузка $when (${formatShippedQty(shipment.qty)}): '
      'документ ${hasDocument ? 'отмечен' : 'снят'}';
}

String _formatDateTime(DateTime value) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(value.day)}.${two(value.month)}.${value.year} '
      '${two(value.hour)}:${two(value.minute)}';
}

double? _toDouble(Object? raw) {
  if (raw is num) return raw.toDouble();
  if (raw is String) {
    return double.tryParse(raw.trim().replaceAll(',', '.'));
  }
  return null;
}

DateTime? _toDate(Object? raw) {
  if (raw is DateTime) return raw;
  if (raw is String && raw.trim().isNotEmpty) {
    return DateTime.tryParse(raw.trim());
  }
  return null;
}
