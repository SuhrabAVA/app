/// Строки списания краски на флексопечати: одна строка на один слот.
///
/// ЗАЧЕМ
/// Диалог списания собирает список из двух источников — краски текущего заказа
/// и очередь отложенных списаний предыдущих заказов, — и дальше этот список
/// живёт как один массив: его правит оператор, он же переживает открытие
/// редактора красок и повторную загрузку. Достаточно одной лишней копии
/// строки, чтобы RPC списала одну и ту же краску дважды: на складе это
/// незаметно, пока хватает остатка, а когда не хватает — отказ приходит с
/// числами, которые не сходятся ни с чем («доступно 8300» при полном складе,
/// потому что 8300 — остаток ПОСЛЕ двух списаний).
///
/// Повтор одного слота не бывает правильным ни в каком сценарии: у заказа одна
/// краска — один расход, у очереди одна долговая строка — одно списание.
/// Поэтому дубли снимаются до отправки, а не ловятся проверкой остатка.
library;

/// Тождество слота списания.
///
/// Для очереди это id долговой строки: она и есть слот. Для красок заказа —
/// пара «заказ + краска»: id, если он известен, иначе нормализованное
/// название, потому что часть красок вписана текстом и id не имеет.
String flexPaintRowKey(Map<String, dynamic> row, {required bool pending}) {
  String field(List<String> keys) {
    for (final key in keys) {
      final value = row[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  if (pending) {
    final id = field(const ['pending_writeoff_id', 'pendingWriteoffId', 'id']);
    if (id.isNotEmpty) return 'pending::$id';
  }

  final orderId =
      field(const ['source_order_id', 'sourceOrderId', 'order_id', 'orderId']);

  // НАЗВАНИЕ ПЕРВИЧНО, id — запасной. Это не вкус, а следствие данных: у одной
  // и той же краски строка из состава заказа несёт paint_id, а строка, собранная
  // по имени (краску вписали текстом, справочник подставился не везде), его не
  // несёт. Ключ по id разводил такие строки в разные слоты, и одна и та же
  // краска уходила в RPC дважды — склад проседал на два расхода подряд, а
  // отказывала третья проверка.
  //
  // Название есть у каждой строки, поэтому оно и служит тождеством. Разные
  // карточки с одинаковым описанием схлопнулись бы ошибочно, но в справочнике
  // описание — это и есть имя краски, по нему же её ищет сервер
  // (lower(trim(description))).
  final name = field(const ['paint_name', 'paintName', 'name'])
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (name.isNotEmpty) return '$orderId::name::$name';

  final paintId = field(const ['paint_id', 'paintId', 'material_id']);
  return '$orderId::paint::$paintId';
}

/// Убирает повторы слотов, сохраняя порядок.
///
/// Побеждает ПОСЛЕДНЯЯ копия: список правит оператор, и свежая строка несёт
/// его ввод, а ранняя — то, что подставилось при загрузке.
List<Map<String, dynamic>> dedupeFlexPaintRows(
  List<Map<String, dynamic>> rows, {
  required bool pending,
}) {
  final byKey = <String, Map<String, dynamic>>{};
  final order = <String>[];
  for (final row in rows) {
    final key = flexPaintRowKey(row, pending: pending);
    if (!byKey.containsKey(key)) order.add(key);
    byKey[key] = row;
  }
  return <Map<String, dynamic>>[for (final key in order) byKey[key]!];
}

/// Убирает из очереди долги, которые в этом же запросе уже списываются как
/// краски заказа.
///
/// ЗАЧЕМ ОТДЕЛЬНО ОТ [dedupeFlexPaintRows]
/// Тот снимает повторы ВНУТРИ списка, а этот — ПЕРЕСЕЧЕНИЕ двух списков. Долг
/// и строка заказа — разные объекты (у долга свой id), но если они про одну и
/// ту же пару «заказ + краска», то списание одно: краска расходуется один раз.
///
/// Так выглядел живой отказ: собственный долг заказа не отфильтровался от
/// текущего списка (сравнение id заказа строкой), и одна и та же зелёная
/// уходила в RPC трижды. Склад проседал на два расхода подряд, третья проверка
/// отказывала — «доступно 8300» при складе 85 000, где 8300 это остаток ПОСЛЕ
/// двух списаний.
///
/// Сервер от этого не защищает: он доверяет присланному списку и спишет
/// столько раз, сколько строк придёт.
List<Map<String, dynamic>> dropPendingRowsAlreadyInCurrent({
  required List<Map<String, dynamic>> currentRows,
  required List<Map<String, dynamic>> pendingRows,
}) {
  final occupied = <String>{
    for (final row in currentRows) flexPaintRowKey(row, pending: false),
  };
  return <Map<String, dynamic>>[
    for (final row in pendingRows)
      if (!occupied.contains(flexPaintRowKey(row, pending: false))) row,
  ];
}
