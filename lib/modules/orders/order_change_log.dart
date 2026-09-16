/// Что именно изменилось в заказе — для истории заказа.
///
/// ЗАЧЕМ
/// История писала на каждое сохранение одну строку «Изменён заказ». По ней
/// нельзя ответить ни на один вопрос, ради которого в историю и заходят: кто
/// поменял тираж, когда переставили срок, почему у заказа другой заказчик.
/// Здесь заказ сравнивается с самим собой до правки, и каждое поле называется
/// словами: было → стало.
///
/// ЧЕГО ЗДЕСЬ НЕТ, И ЭТО НАМЕРЕННО
///   * бумага — у неё своё, более подробное событие «Изменение бумаги»
///     (`_describePaperChanges`): там метраж, ширина, количество по БЛ и
///     дельта в метрах по каждой позиции. Дублировать её строкой «Материал:
///     было → стало» значило бы писать одно и то же дважды и врать в
///     подробностях;
///   * дополнительные опции — своё событие «Изменение опций»
///     (`describeOrderExtraOptionChanges`);
///   * краски — их нет в [OrderModel], они лежат таблицей `order_paints`.
///
/// Только чистые функции: кто автор и куда это писать — снаружи.
library;

import 'material_model.dart';
import 'order_model.dart';

/// Одно изменённое поле.
class OrderFieldChange {
  const OrderFieldChange({
    required this.label,
    required this.before,
    required this.after,
  });

  final String label;

  /// Текст значения. Пустая строка — поле не было заполнено.
  final String before;
  final String after;

  bool get isFilling => before.isEmpty && after.isNotEmpty;
  bool get isClearing => before.isNotEmpty && after.isEmpty;

  /// «Тираж: 1000 → 2000», «Срок: не указан → 17.09.2026».
  String get line {
    const dash = 'не указано';
    final from = before.isEmpty ? dash : before;
    final to = after.isEmpty ? dash : after;
    return '$label: $from → $to';
  }

  @override
  bool operator ==(Object other) =>
      other is OrderFieldChange &&
      other.label == label &&
      other.before == before &&
      other.after == after;

  @override
  int get hashCode => Object.hash(label, before, after);

  @override
  String toString() => line;
}

/// Поля заказа, изменившиеся между двумя его состояниями.
///
/// Порядок — как в форме заказа: сотрудник читает список изменений в том же
/// порядке, в каком видит поля на экране.
List<OrderFieldChange> diffOrderFields({
  required OrderModel before,
  required OrderModel after,
}) {
  final changes = <OrderFieldChange>[];

  void compare(String label, String from, String to) {
    if (from.trim() == to.trim()) return;
    changes.add(OrderFieldChange(
      label: label,
      before: from.trim(),
      after: to.trim(),
    ));
  }

  compare('Заказчик', before.customer, after.customer);
  compare('Менеджер', before.manager, after.manager);
  compare('Дата заказа', _date(before.orderDate), _date(after.orderDate));
  compare('Срок', _date(before.dueDate), _date(after.dueDate));
  compare('Тип продукта', before.product.type, after.product.type);
  compare(
    'Тираж',
    _number(before.product.quantity),
    _number(after.product.quantity),
  );
  compare('Размеры', _dimensions(before), _dimensions(after));
  compare('Рулон', _number(before.product.roll), _number(after.product.roll));
  compare(
    'Количество в строке бумаги',
    (before.product.blQuantity ?? '').trim(),
    (after.product.blQuantity ?? '').trim(),
  );
  compare(
    'Длина L',
    _number(before.product.length, unit: 'м'),
    _number(after.product.length, unit: 'м'),
  );
  compare('Картон', _choice(before.cardboard), _choice(after.cardboard));
  compare('Ручки', _choice(before.handle), _choice(after.handle));
  compare(
    'Подрезка',
    _flag(before.additionalParams, 'Подрезка'),
    _flag(after.additionalParams, 'Подрезка'),
  );
  compare('Приладка', _number(before.makeready), _number(after.makeready));
  compare('ВАЛ', _number(before.val), _number(after.val));
  compare('Печатная форма', _form(before), _form(after));
  compare('Комментарий', before.comments, after.comments);
  // Статус НЕ сравнивается: его меняет не сотрудник, а пересчёт
  // обеспеченности — на каждом сохранении, часто дважды подряд. В истории это
  // выглядело как правка человека, которой не было.
  // Основной материал сравнивается только по НАЗВАНИЮ и только когда своего
  // события про бумагу не будет: подробности метража пишет «Изменение бумаги».
  compare('Основная бумага', _mainPaper(before), _mainPaper(after));

  return changes;
}

/// Текст события истории; `null` — ничего не изменилось.
///
/// Автор в текст НЕ подставляется: у события есть своя колонка `user_id`, и
/// имя, вписанное вдобавок в описание, разъезжается с ней при переименовании
/// сотрудника.
String? describeOrderFieldChanges(List<OrderFieldChange> changes) {
  if (changes.isEmpty) return null;
  return changes.map((change) => change.line).join('\n');
}

/// Состав заказа в момент создания — первая запись в его истории.
///
/// Пишется отдельно от изменений: у нового заказа «до» не существует, и
/// показывать «Тираж: не указано → 1000» по каждому полю значило бы утопить
/// первую запись в шуме. Здесь перечислено только заполненное.
String describeOrderCreation(OrderModel order) {
  final parts = <String>[
    if (order.customer.trim().isNotEmpty) 'Заказчик: ${order.customer.trim()}',
    if (order.product.type.trim().isNotEmpty)
      'Тип продукта: ${order.product.type.trim()}',
    if (order.product.quantity > 0)
      'Тираж: ${_number(order.product.quantity)}',
    if (_dimensions(order).isNotEmpty) 'Размеры: ${_dimensions(order)}',
    if (_mainPaper(order).isNotEmpty) 'Бумага: ${_mainPaper(order)}',
    if (_choice(order.cardboard).isNotEmpty)
      'Картон: ${_choice(order.cardboard)}',
    if (_choice(order.handle).isNotEmpty) 'Ручки: ${_choice(order.handle)}',
    if (order.makeready > 0) 'Приладка: ${_number(order.makeready)}',
    if (_date(order.dueDate).isNotEmpty) 'Срок: ${_date(order.dueDate)}',
    if (order.comments.trim().isNotEmpty)
      'Комментарий: ${order.comments.trim()}',
  ];
  return parts.isEmpty ? 'Заказ создан' : parts.join('\n');
}

// ===== Форматирование значений =====
//
// Значение в истории — это ТЕКСТ НА МОМЕНТ СОБЫТИЯ. Хранить его иначе нельзя:
// справочники правятся, и ссылка показала бы сегодняшнее название вместо
// того, что человек видел, когда менял.

String _date(DateTime? value) {
  if (value == null) return '';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(value.day)}.${two(value.month)}.${value.year}';
}

String _number(num? value, {String unit = ''}) {
  if (value == null || value == 0) return '';
  final text = value % 1 == 0
      ? value.toInt().toString()
      : value.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
  return unit.isEmpty ? text : '$text $unit';
}

String _dimensions(OrderModel order) {
  final p = order.product;
  if (p.width <= 0 && p.height <= 0 && p.depth <= 0) return '';
  String side(double value) => value <= 0 ? '—' : _number(value);
  return '${side(p.width)}×${side(p.height)}×${side(p.depth)}';
}

/// «нет» и «-» — это пусто, а не значение: в форме они означают «не выбрано».
String _choice(String value) {
  final text = value.trim();
  if (text.isEmpty || text == '-' || text.toLowerCase() == 'нет') return '';
  return text;
}

String _flag(List<String> params, String name) {
  final has = params.any(
    (param) => param.trim().toLowerCase() == name.toLowerCase(),
  );
  return has ? 'да' : '';
}

String _form(OrderModel order) {
  final code = (order.formCode ?? '').trim();
  if (code.isNotEmpty) return code;
  final series = (order.formSeries ?? '').trim();
  final number = order.newFormNo;
  if (number == null) return '';
  return series.isEmpty ? '$number' : '$series $number';
}

String _mainPaper(OrderModel order) {
  final papers = order.paperMaterials.isNotEmpty
      ? order.paperMaterials
      : <MaterialModel>[if (order.material != null) order.material!];
  if (papers.isEmpty) return '';
  final main = papers.first;
  final name = main.name.trim();
  if (name.isEmpty) return '';
  final extras = <String>[
    if ((main.format ?? '').trim().isNotEmpty) main.format!.trim(),
    if ((main.grammage ?? '').trim().isNotEmpty) '${main.grammage!.trim()} гр',
  ];
  return extras.isEmpty ? name : '$name (${extras.join(', ')})';
}
