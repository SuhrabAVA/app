/// Обязательные блоки заказа: без них заказ не уходит в «Готов к запуску».
///
/// ЗАЧЕМ
/// Проверка обеспеченности разрешительная по построению: она отвечает на
/// вопрос «хватает ли того, что выбрано», и пустой заказ проходит её как
/// «нехватки нет». Поэтому заказ без единой бумаги спокойно доезжал до
/// готовности. Требование «без чего заказ не готов» зависит от типа продукта
/// и в код не зашивается: техлид отмечает блоки флагом
/// `product_type_form_blocks.is_required`.
///
/// Здесь только чистые функции: что считать заполненным и чего не хватает.
/// Кто читает справочник и кто меняет статус — снаружи.
library;

import 'material_model.dart';
import 'order_handle_type.dart';
import 'order_model.dart';
import 'product_type_settings.dart';

/// Основная бумага заказа.
///
/// В `order_form_blocks` появилась позже остальных и особая: скрыть её нельзя
/// (форма без материала не форма), а вот потребовать — можно и нужно. Ради
/// этого у справочника есть `can_hide`.
const String kOrderFormBlockMaterial = 'material';

/// Какие блоки заказа заполнены.
///
/// Смысл «заполнено» у каждого блока свой и держится здесь, а не в вызывающем
/// коде: правило читают и форма, и пересчёт статусов, и разъехаться они не
/// должны.
///
///   * `material` — выбрана хотя бы одна бумага;
///   * `bl_quantity` — у продукта указано количество по БЛ;
///   * `paints` — в заказ вписана хотя бы одна краска;
///   * `form` — заказу назначена печатная форма (номер или код);
///   * `pdf` — к заказу приложен файл;
///   * `cardboard` — картон выбран (значение не «нет»);
///   * `trimming` — подрезка отмечена в параметрах;
///   * `handle` — тип ручки выбран (значение не «-»);
///   * `makeready` — приладка больше нуля;
///   * `extra_papers` — есть бумага сверх основной;
///   * `roll` — рулон заполнен.
///
/// [paintLineCount] и [hasPdf] приходят снаружи: красок и файлов в
/// [OrderModel] нет, они лежат своими таблицами.
Set<String> filledOrderBlocks({
  required OrderModel order,
  required int paintLineCount,
  required bool hasPdf,
}) {
  final papers = order.paperMaterials.isNotEmpty
      ? order.paperMaterials
      : <MaterialModel>[if (order.material != null) order.material!];

  final filled = <String>{};

  if (papers.any((paper) => _paperFilled(paper))) {
    filled.add(kOrderFormBlockMaterial);
  }
  if (papers.where(_paperFilled).length > 1) {
    filled.add(kOrderFormBlockExtraPapers);
  }
  // blQuantity хранится строкой, а не числом: в форме это свободное поле.
  // Пустая строка и «0» одинаково означают «не заполнено».
  final blQuantity = (order.product.blQuantity ?? '').trim();
  if (blQuantity.isNotEmpty && double.tryParse(blQuantity.replaceAll(',', '.')) != 0) {
    filled.add(kOrderFormBlockBlQuantity);
  }
  if (paintLineCount > 0) {
    filled.add(kOrderFormBlockPaints);
  }
  if (order.hasForm ||
      order.newFormNo != null ||
      (order.formCode?.trim().isNotEmpty ?? false)) {
    filled.add(kOrderFormBlockForm);
  }
  if (hasPdf || (order.pdfUrl?.trim().isNotEmpty ?? false)) {
    filled.add(kOrderFormBlockPdf);
  }
  final cardboard = order.cardboard.trim().toLowerCase();
  if (cardboard.isNotEmpty && cardboard != 'нет' && cardboard != '-') {
    filled.add(kOrderFormBlockCardboard);
  }
  if (order.additionalParams.any(
    (param) => param.trim().toLowerCase() == 'подрезка',
  )) {
    filled.add(kOrderFormBlockTrimming);
  }
  final handle = order.handle.trim();
  if (handle.isNotEmpty && handle != '-') {
    filled.add(kOrderFormBlockHandle);
  }
  if (order.makeready > 0) {
    filled.add(kOrderFormBlockMakeready);
  }
  if ((order.product.roll ?? 0) > 0) {
    filled.add(kOrderFormBlockRoll);
  }

  return filled;
}

/// Бумага считается выбранной, когда у неё есть название или ссылка на склад.
///
/// Пустая строка-заготовка позицией не является — тот же критерий, что у
/// [materialsWithoutQuantity] в `order_launch_rules.dart`. Количество здесь
/// НЕ проверяется: «выбрана, но без метража» — отдельное правило с отдельным
/// сообщением, и подменять одно другим значило бы врать менеджеру о причине.
bool _paperFilled(MaterialModel paper) =>
    paper.name.trim().isNotEmpty || (paper.id ?? '').trim().isNotEmpty;

/// Коды обязательных блоков, которые не заполнены.
///
/// Порядок — как в справочнике блоков ([order]), чтобы сообщение читалось в
/// том же порядке, в каком поля идут в форме. Неизвестные коды сохраняются в
/// конце: справочник живёт в базе и может обогнать релиз, а молча проглотить
/// требование — худшее из поведений.
List<String> missingRequiredBlockCodes({
  required Set<String> requiredCodes,
  required Set<String> filledCodes,
  List<String> order = const <String>[],
}) {
  final missing = requiredCodes.where((code) => !filledCodes.contains(code));
  final known = <String>[
    for (final code in order)
      if (missing.contains(code)) code,
  ];
  final unknown = missing.where((code) => !order.contains(code)).toList()
    ..sort();
  return <String>[...known, ...unknown];
}

/// Незаполненные обязательные блоки С УЧЁТОМ условий.
///
/// Единственная точка, где требование и его условие сходятся вместе. Форма
/// заказа и пересчёт статусов зовут её обе: разойдись они здесь, форма
/// показывала бы одно, а сервер решал другое.
///
/// [conditionsFor] отдаёт условия блока: пустой список — «обязателен всегда».
List<String> missingRequiredBlocksForOrder({
  required Set<String> requiredCodes,
  required Set<String> filledCodes,
  required List<OrderBlockCondition> Function(String blockCode) conditionsFor,
  String? handleTypeName,
  List<String> order = const <String>[],
}) {
  final effective = <String>{
    for (final code in requiredCodes)
      if (blockRequirementApplies(
        conditions: conditionsFor(code),
        filledCodes: filledCodes,
        handleTypeName: handleTypeName,
      ))
        code,
  };
  return missingRequiredBlockCodes(
    requiredCodes: effective,
    filledCodes: filledCodes,
    order: order,
  );
}

/// Сообщение менеджеру: чего не хватает, человеческими названиями.
///
/// `null` — всё обязательное заполнено.
String? missingRequiredBlocksMessage({
  required List<String> missingCodes,
  required Map<String, String> titlesByCode,
}) {
  if (missingCodes.isEmpty) return null;
  final titles = <String>[
    for (final code in missingCodes) titlesByCode[code] ?? code,
  ];
  return 'Не заполнено: ${titles.join(', ')}.';
}

/// Предикаты, доступные условиям блоков (`order_predicates.scope`).
///
/// Список закрыт и повторяет справочник: каждый код реализован здесь функцией,
/// и предикат, которого тут нет, читается как «условие не выполнено».
const List<String> kBlockConditionPredicates = <String>[
  'has_paint',
  'has_form',
  'has_cardboard',
  'has_trimming',
  'handle_type_is',
];

/// Действует ли требование к блоку на этом заказе.
///
/// Пустой список условий — действует всегда. Иначе должны выполниться ВСЕ.
///
/// НЕИЗВЕСТНЫЙ ПРЕДИКАТ ЧИТАЕТСЯ КАК «НЕ ВЫПОЛНЕНО», то есть требование НЕ
/// применяется. Направление выбрано осознанно и противоположно условиям
/// этапов: там тихо не добавить этап безопаснее, чем тихо добавить, а здесь
/// тихо запереть заказ в черновике хуже, чем тихо его пропустить. Такое бывает
/// ровно при расхождении версий: в справочник добавили предикат, а приложение
/// ещё старое.
bool blockRequirementApplies({
  required List<OrderBlockCondition> conditions,
  required Set<String> filledCodes,
  String? handleTypeName,
}) {
  for (final condition in conditions) {
    final value = _evaluateBlockPredicate(
      condition: condition,
      filledCodes: filledCodes,
      handleTypeName: handleTypeName,
    );
    if (value == null) return false;
    if (condition.negate ? value : !value) return false;
  }
  return true;
}

/// `null` — предикат неизвестен этой версии приложения.
bool? _evaluateBlockPredicate({
  required OrderBlockCondition condition,
  required Set<String> filledCodes,
  required String? handleTypeName,
}) {
  switch (condition.predicate) {
    case 'has_paint':
      return filledCodes.contains(kOrderFormBlockPaints);
    case 'has_form':
      return filledCodes.contains(kOrderFormBlockForm);
    case 'has_cardboard':
      return filledCodes.contains(kOrderFormBlockCardboard);
    case 'has_trimming':
      return filledCodes.contains(kOrderFormBlockTrimming);
    case 'handle_type_is':
      return handleTypeName != null && handleTypeName == condition.param;
    default:
      return null;
  }
}

/// Тип ручки заказа строкой — параметр предиката `handle_type_is`.
String orderHandleTypeName(OrderModel order) =>
    orderHandleTypeFromDescription(order.handle).name;
