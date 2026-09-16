/// Дополнительные опции заказа: справочник типа продукта и снимок в заказе.
///
/// Здесь только модели и чистые функции. Чтение справочника, редактор и блок
/// формы — следующие фазы; на этот файл они опираются, чтобы правила «что
/// показать» и «что записать» жили в одном месте и проверялись тестами без
/// поднятия виджетов.
///
/// ДВА ИСТОЧНИКА ПРАВДЫ, И ЭТО НАМЕРЕННО
///   * ПОКАЗ заказа (просмотр, архив, производство) строится ТОЛЬКО из снимка
///     — [decodeOrderExtraOptions]. Справочник в этот путь не заходит вообще,
///     поэтому переименование или удаление варианта не меняет ни одного уже
///     сохранённого заказа. Это и есть требование «открыл через год — видишь
///     то, что выбрали».
///   * ФОРМА заказа строится из справочника, поверх которого лёг снимок, —
///     [buildOrderExtraOptionRows]. Иначе новые опции не появлялись бы в
///     старом заказе, а снятые с учёта продолжали бы предлагаться.
///
/// Формат снимка описан в миграции 20260910_order_extra_options.sql.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Значения `order_option_defs.kind`.
const String kOrderOptionKindBoolean = 'boolean';
const String kOrderOptionKindSelect = 'select';

/// `value_id` опции Да/Нет. Код, а не текст: подпись в интерфейсе может
/// смениться, а сохранённые заказы сравнивать между собой всё равно нужно.
const String kOrderOptionYes = 'yes';
const String kOrderOptionNo = 'no';

/// Подпись значения Да/Нет; `null` — код неизвестен.
String? orderOptionBooleanLabel(String? valueId) => switch (valueId) {
      kOrderOptionYes => 'Да',
      kOrderOptionNo => 'Нет',
      _ => null,
    };

/// Вариант опции — строка `order_option_values`.
@immutable
class OrderOptionValue {
  const OrderOptionValue({
    required this.id,
    required this.title,
    this.sortOrder = 0,
    this.isActive = true,
  });

  final String id;
  final String title;
  final int sortOrder;

  /// Мягкое удаление: неактивный вариант не предлагается в новых заказах, но
  /// остаётся выбранным там, где его уже выбрали.
  final bool isActive;

  static OrderOptionValue? tryFromMap(Map<String, dynamic> map) {
    final id = _text(map, const ['id']);
    final title = _text(map, const ['title']);
    if (id.isEmpty || title.isEmpty) return null;
    return OrderOptionValue(
      id: id,
      title: title,
      sortOrder: _int(map, const ['sort_order', 'sortOrder']),
      isActive: _bool(map, const ['is_active', 'isActive']),
    );
  }
}

/// Опция — строка `order_option_defs` вместе со своими вариантами.
@immutable
class OrderOptionDef {
  const OrderOptionDef({
    required this.id,
    required this.productTypeId,
    required this.title,
    required this.kind,
    this.sortOrder = 0,
    this.isActive = true,
    this.values = const <OrderOptionValue>[],
  });

  final String id;
  final String productTypeId;
  final String title;
  final String kind;
  final int sortOrder;
  final bool isActive;

  /// Для [kOrderOptionKindBoolean] всегда пуст: Да/Нет в справочнике не живёт.
  final List<OrderOptionValue> values;

  bool get isBoolean => kind == kOrderOptionKindBoolean;
  bool get isSelect => kind == kOrderOptionKindSelect;

  static OrderOptionDef? tryFromMap(
    Map<String, dynamic> map, {
    List<OrderOptionValue> values = const <OrderOptionValue>[],
  }) {
    final id = _text(map, const ['id']);
    final title = _text(map, const ['title']);
    final kind = _text(map, const ['kind']);
    if (id.isEmpty || title.isEmpty) return null;
    if (kind != kOrderOptionKindBoolean && kind != kOrderOptionKindSelect) {
      return null;
    }
    return OrderOptionDef(
      id: id,
      productTypeId: _text(map, const ['product_type_id', 'productTypeId']),
      title: title,
      kind: kind,
      sortOrder: _int(map, const ['sort_order', 'sortOrder']),
      isActive: _bool(map, const ['is_active', 'isActive']),
      values: kind == kOrderOptionKindSelect
          ? (values.toList()..sort(_compareValues))
          : const <OrderOptionValue>[],
    );
  }
}

/// Выбранное значение — один элемент снимка `orders.extra_options`.
///
/// Названия здесь — копии на момент сохранения, а не ссылки. Поэтому у класса
/// нет и не должно появиться метода, который дочитывает подпись из
/// справочника: это ровно та связь, ради разрыва которой снимок и заведён.
@immutable
class OrderOptionSelection {
  const OrderOptionSelection({
    required this.optionId,
    required this.title,
    required this.kind,
    required this.valueId,
    required this.valueLabel,
    this.sortOrder = 0,
  });

  final String optionId;
  final String title;
  final String kind;

  /// `order_option_values.id` для списка, [kOrderOptionYes]/[kOrderOptionNo]
  /// для Да/Нет.
  final String valueId;

  final String valueLabel;
  final int sortOrder;

  bool get isBoolean => kind == kOrderOptionKindBoolean;

  static OrderOptionSelection? tryFromMap(Map<String, dynamic> map) {
    final optionId = _text(map, const ['option_id', 'optionId']);
    final valueId = _text(map, const ['value_id', 'valueId']);
    final valueLabel = _text(map, const ['value_label', 'valueLabel']);
    // Запись без значения бессмысленна: невыбранные опции в снимок не
    // попадают. Без ярлыка — тем более: показывать было бы нечего, а
    // дочитывать его из справочника запрещено по построению.
    if (optionId.isEmpty || valueId.isEmpty || valueLabel.isEmpty) return null;
    final kind = _text(map, const ['kind']);
    return OrderOptionSelection(
      optionId: optionId,
      title: _text(map, const ['title']),
      kind: kind == kOrderOptionKindBoolean
          ? kOrderOptionKindBoolean
          : kOrderOptionKindSelect,
      valueId: valueId,
      valueLabel: valueLabel,
      sortOrder: _int(map, const ['sort', 'sort_order', 'sortOrder']),
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
        'option_id': optionId,
        'title': title,
        'kind': kind,
        'value_id': valueId,
        'value_label': valueLabel,
        'sort': sortOrder,
      };

  @override
  bool operator ==(Object other) =>
      other is OrderOptionSelection &&
      other.optionId == optionId &&
      other.title == title &&
      other.kind == kind &&
      other.valueId == valueId &&
      other.valueLabel == valueLabel &&
      other.sortOrder == sortOrder;

  @override
  int get hashCode =>
      Object.hash(optionId, title, kind, valueId, valueLabel, sortOrder);

  @override
  String toString() => 'OrderOptionSelection($title: $valueLabel)';
}

/// Разбирает снимок из `orders.extra_options`.
///
/// Терпим к форме: приходит и списком (jsonb), и строкой (кэш, экспорт).
/// Непонятные элементы отбрасываются молча — заказ обязан открыться, даже если
/// в снимке оказался мусор.
List<OrderOptionSelection> decodeOrderExtraOptions(Object? raw) {
  final list = _asList(raw);
  final result = <OrderOptionSelection>[];
  for (final item in list) {
    if (item is! Map) continue;
    final parsed =
        OrderOptionSelection.tryFromMap(Map<String, dynamic>.from(item));
    if (parsed != null) result.add(parsed);
  }
  result.sort(_compareSelections);
  return result;
}

/// Собирает снимок для записи в `orders.extra_options`.
List<Map<String, dynamic>> encodeOrderExtraOptions(
  List<OrderOptionSelection> selections,
) =>
    <Map<String, dynamic>>[
      for (final selection in selections) selection.toMap(),
    ];

/// Строка блока «Дополнительные опции» в форме заказа.
@immutable
class OrderExtraOptionRow {
  const OrderExtraOptionRow({
    required this.optionId,
    required this.title,
    required this.kind,
    required this.sortOrder,
    required this.choices,
    required this.selection,
    required this.isRetired,
  });

  final String optionId;

  /// У действующей опции — актуальное название из справочника, у снятой —
  /// название из снимка заказа.
  final String title;

  final String kind;
  final int sortOrder;

  /// Что предложить на выбор. Для Да/Нет пуст — варианты не из справочника.
  final List<OrderOptionValue> choices;

  final OrderOptionSelection? selection;

  /// Опции больше нет в действующем справочнике, а значение в заказе есть.
  /// Строка показывается ради истории и не редактируется.
  final bool isRetired;

  bool get isBoolean => kind == kOrderOptionKindBoolean;
  bool get isSelect => kind == kOrderOptionKindSelect;
  String? get valueId => selection?.valueId;
  String? get valueLabel => selection?.valueLabel;

  /// Новая строка с выбранным значением; `null` — выбор снят.
  ///
  /// Неизвестный код молча снимает выбор, а не оставляет прежний: иначе
  /// рассинхрон списка и значения превратился бы в «кнопка нажимается, а
  /// ничего не меняется».
  OrderExtraOptionRow withChoice(String? nextValueId) {
    final id = (nextValueId ?? '').trim();
    if (id.isEmpty) return _copyWith(selection: null);

    final String? label;
    if (isBoolean) {
      label = orderOptionBooleanLabel(id);
    } else {
      label = choices
          .where((choice) => choice.id == id)
          .map((choice) => choice.title)
          .firstOrNull;
    }
    if (label == null) return _copyWith(selection: null);

    return _copyWith(
      selection: OrderOptionSelection(
        optionId: optionId,
        title: title,
        kind: kind,
        valueId: id,
        valueLabel: label,
        sortOrder: sortOrder,
      ),
    );
  }

  OrderExtraOptionRow _copyWith({required OrderOptionSelection? selection}) =>
      OrderExtraOptionRow(
        optionId: optionId,
        title: title,
        kind: kind,
        sortOrder: sortOrder,
        choices: choices,
        selection: selection,
        isRetired: isRetired,
      );
}

/// Строит строки формы: действующий справочник + сохранённый снимок.
///
/// Порядок: сначала действующие опции в порядке техлида, затем снятые с учёта,
/// но выбранные в этом заказе, — они уходят вниз, чтобы не разрывать список,
/// которым техлид управляет.
///
/// Три случая, ради которых функция вообще существует:
///   * опцию завели ПОСЛЕ создания заказа — строка появляется пустой;
///   * опцию сняли с учёта, а значение в заказе есть — строка остаётся
///     (`isRetired`), значение видно и при пересохранении не теряется;
///   * ВЫБРАННЫЙ вариант сняли с учёта — он подставляется в [choices] сверх
///     действующих. Без этого открытие заказа на редактирование молча
///     сбрасывало бы значение: выпадающий список не нашёл бы своего элемента.
List<OrderExtraOptionRow> buildOrderExtraOptionRows({
  required List<OrderOptionDef> defs,
  required List<OrderOptionSelection> saved,
}) {
  final byOption = <String, OrderOptionSelection>{
    for (final selection in saved) selection.optionId: selection,
  };

  final active = defs.where((def) => def.isActive).toList()..sort(_compareDefs);

  final rows = <OrderExtraOptionRow>[];
  for (final def in active) {
    final selection = byOption.remove(def.id);
    // Список без единого варианта выбирать нечего: строка в форме была бы
    // пустым выпадающим списком, который нельзя ни заполнить, ни понять.
    // Такое состояние нормально и временно — техлид завёл опцию и ещё не
    // добрался до вариантов. А если значение в заказе уже есть, строка
    // остаётся: скрыть её означало бы потерять выбранное при пересохранении.
    if (def.isSelect && selection == null && !def.values.any((v) => v.isActive)) {
      continue;
    }
    rows.add(OrderExtraOptionRow(
      optionId: def.id,
      title: def.title,
      kind: def.kind,
      sortOrder: def.sortOrder,
      choices: def.isSelect ? _choicesFor(def, selection) : const [],
      selection: selection,
      isRetired: false,
    ));
  }

  final retired = byOption.values.toList()..sort(_compareSelections);
  for (final selection in retired) {
    rows.add(OrderExtraOptionRow(
      optionId: selection.optionId,
      title: selection.title,
      kind: selection.kind,
      sortOrder: selection.sortOrder,
      choices: const <OrderOptionValue>[],
      selection: selection,
      isRetired: true,
    ));
  }

  return rows;
}

/// Действующие варианты плюс выбранный, если его сняли с учёта.
List<OrderOptionValue> _choicesFor(
  OrderOptionDef def,
  OrderOptionSelection? selection,
) {
  final result = def.values.where((value) => value.isActive).toList();
  final selectedId = selection?.valueId;
  if (selectedId == null) return result;
  if (result.any((value) => value.id == selectedId)) return result;

  final retired =
      def.values.where((value) => value.id == selectedId).firstOrNull;
  result.add(retired ??
      // Варианта нет в справочнике вовсе — восстанавливаем из снимка, иначе
      // показать выбранное значение будет нечем.
      OrderOptionValue(
        id: selectedId,
        title: selection!.valueLabel,
        sortOrder: selection.sortOrder,
        isActive: false,
      ));
  return result;
}

/// Снимок для записи в заказ.
///
/// Строки без выбора отбрасываются: заполнять опции необязательно, и пустая
/// запись отличалась бы от её отсутствия только шумом в истории.
///
/// У действующих строк подписи пересобираются по СПРАВОЧНИКУ — значит,
/// пересохранение заказа подтягивает переименование варианта. Это осознанно:
/// при пересохранении менеджер видит в форме актуальные названия, и записать
/// в заказ другие означало бы сохранить не то, что было на экране. Заказы, к
/// которым не притрагивались, переименование по-прежнему не задевает.
///
/// У снятых с учёта строк снимок переносится как есть — трогать историю
/// нечем и незачем.
List<OrderOptionSelection> selectionsFromRows(List<OrderExtraOptionRow> rows) {
  final result = <OrderOptionSelection>[];
  for (final row in rows) {
    final selection = row.selection;
    if (selection == null) continue;
    if (row.isRetired) {
      result.add(selection);
      continue;
    }
    result.add(OrderOptionSelection(
      optionId: row.optionId,
      title: row.title,
      kind: row.kind,
      valueId: selection.valueId,
      valueLabel: _currentLabel(row, selection),
      sortOrder: row.sortOrder,
    ));
  }
  result.sort(_compareSelections);
  return result;
}

/// Подпись значения по действующему справочнику строки.
///
/// Запасной вариант — подпись из снимка. Он срабатывает там, где справочник
/// ответа не даёт: вариант удалён насовсем и восстановлен из снимка самим
/// [_choicesFor], либо в снимке лежит код Да/Нет, которого мы не знаем.
String _currentLabel(OrderExtraOptionRow row, OrderOptionSelection selection) {
  if (row.isBoolean) {
    return orderOptionBooleanLabel(selection.valueId) ?? selection.valueLabel;
  }
  return row.choices
          .where((choice) => choice.id == selection.valueId)
          .map((choice) => choice.title)
          .firstOrNull ??
      selection.valueLabel;
}

/// Человекочитаемая разница снимков для журнала заказа; `null` — не изменилось.
///
/// Нужна потому, что опции разрешено править в уже запущенном заказе: без
/// записи в историю смена «Ламинация: Да → Нет» на запущенном заказе не
/// оставила бы следа.
String? describeOrderExtraOptionChanges({
  required List<OrderOptionSelection> before,
  required List<OrderOptionSelection> after,
}) {
  final was = <String, OrderOptionSelection>{
    for (final selection in before) selection.optionId: selection,
  };
  final now = <String, OrderOptionSelection>{
    for (final selection in after) selection.optionId: selection,
  };

  final ids = <String>{...was.keys, ...now.keys}.toList();
  final parts = <String>[];
  // Порядок вывода — как в новом снимке, чтобы строка журнала читалась в том
  // же порядке, что и блок в форме.
  ids.sort((a, b) {
    final left = now[a] ?? was[a]!;
    final right = now[b] ?? was[b]!;
    return _compareSelections(left, right);
  });

  for (final id in ids) {
    final oldValue = was[id];
    final newValue = now[id];
    if (oldValue?.valueId == newValue?.valueId) continue;
    final title = (newValue ?? oldValue)!.title;
    final from = oldValue?.valueLabel ?? '—';
    final to = newValue?.valueLabel ?? '—';
    parts.add('$title: $from → $to');
  }

  return parts.isEmpty ? null : parts.join('; ');
}

// ===== Порядок =====
//
// Везде один и тот же: сначала порядок, заданный техлидом, затем название —
// при равных sort_order строки иначе прыгали бы между открытиями формы.

int _compareDefs(OrderOptionDef a, OrderOptionDef b) {
  final byOrder = a.sortOrder.compareTo(b.sortOrder);
  if (byOrder != 0) return byOrder;
  final byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
  return byTitle != 0 ? byTitle : a.id.compareTo(b.id);
}

int _compareValues(OrderOptionValue a, OrderOptionValue b) {
  final byOrder = a.sortOrder.compareTo(b.sortOrder);
  if (byOrder != 0) return byOrder;
  final byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
  return byTitle != 0 ? byTitle : a.id.compareTo(b.id);
}

int _compareSelections(OrderOptionSelection a, OrderOptionSelection b) {
  final byOrder = a.sortOrder.compareTo(b.sortOrder);
  if (byOrder != 0) return byOrder;
  final byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
  return byTitle != 0 ? byTitle : a.optionId.compareTo(b.optionId);
}

// ===== Разбор =====

List<dynamic> _asList(Object? raw) {
  if (raw is List) return raw;
  if (raw is String && raw.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded;
    } catch (_) {}
  }
  return const <dynamic>[];
}

String _text(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value == null) continue;
    final text = value.toString().trim();
    if (text.isNotEmpty) return text;
  }
  return '';
}

int _int(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
  }
  return 0;
}

/// Умолчание — `true`: строка справочника без явного флага считается
/// действующей, иначе опечатка в запросе спрятала бы весь справочник.
bool _bool(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final text = value.trim().toLowerCase();
      if (text == 'true' || text == 't' || text == '1') return true;
      if (text == 'false' || text == 'f' || text == '0') return false;
    }
  }
  return true;
}
