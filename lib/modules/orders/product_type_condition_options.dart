/// Условия этапа: перевод предикатов в человеческий текст и набор вариантов
/// для редактора.
///
/// Чистые функции без Flutter — редактор условия и строка списка обязаны
/// говорить об одном и том же одинаково, а разные формулировки в двух местах
/// разъезжаются на первой же правке.
library;

import 'product_type_route.dart';

/// Значения `handle_type_is`. Совпадают с именами значений enum
/// `OrderHandleType` — их же проверяет `set_product_type_stage_condition` и
/// `validate_product_type_config`.
const Map<String, String> kHandleTypeParamLabels = <String, String>{
  'flat': 'плоская',
  'twisted': 'кручёная',
  'dieCut': 'вырубка',
};

/// Вариант выбора в редакторе условия.
class ConditionOption {
  const ConditionOption({
    required this.predicate,
    required this.label,
    this.requiresParam = false,
  });

  /// null — «всегда», то есть отсутствие строк условий.
  final String? predicate;
  final String label;
  final bool requiresParam;
}

/// Закрытый набор — техлид выбирает из списка, но не сочиняет выражения.
///
/// Порядок и состав повторяют `order_predicates`; «всегда» стоит первым,
/// потому что это состояние по умолчанию у большинства этапов.
const List<ConditionOption> kConditionOptions = <ConditionOption>[
  ConditionOption(predicate: null, label: 'всегда'),
  ConditionOption(predicate: 'has_paint', label: 'если есть краски'),
  ConditionOption(predicate: 'has_cardboard', label: 'если есть картон'),
  ConditionOption(predicate: 'has_trimming', label: 'если есть подрезка'),
  ConditionOption(
    predicate: 'needs_bobbin_cutting',
    label: 'если ширина заказа меньше формата бумаги',
  ),
  ConditionOption(
    predicate: 'handle_type_is',
    label: 'если тип ручки',
    requiresParam: true,
  ),
];

/// Человеческая подпись условия для строки списка и вкладки «Условия».
String conditionLabel(RouteCondition condition) {
  final base = switch (condition.predicate) {
    'has_paint' => 'есть краски',
    'has_cardboard' => 'есть картон',
    'has_trimming' => 'есть подрезка',
    'needs_bobbin_cutting' => 'заказ уже формата бумаги',
    'handle_type_is' =>
      'ручка ${kHandleTypeParamLabels[condition.param] ?? condition.param ?? ''}',
    _ => condition.predicate,
  };
  return condition.negate ? 'не $base' : base;
}

/// Подпись условий этапа целиком: «всегда» либо перечисление через «и».
String stageConditionSummary(RouteStage stage) {
  if (stage.conditions.isEmpty) return 'всегда';
  return 'если: ${stage.conditions.map(conditionLabel).join(' и ')}';
}

/// Варианты условия ОБЯЗАТЕЛЬНОСТИ БЛОКА формы.
///
/// Список отличается от [kConditionOptions] не по вкусу, а по возможностям:
/// `needs_bobbin_cutting` считается по списку бумаг с допуском, и у проверки
/// блоков таких данных нет; `has_form` наоборот умеет только она — сборщик
/// очереди про печатную форму не спрашивает. Разделение записано в
/// `order_predicates.scope`.
const List<ConditionOption> kBlockConditionOptions = <ConditionOption>[
  ConditionOption(predicate: null, label: 'всегда'),
  ConditionOption(predicate: 'has_form', label: 'если есть печатная форма'),
  ConditionOption(predicate: 'has_paint', label: 'если есть краски'),
  ConditionOption(predicate: 'has_cardboard', label: 'если есть картон'),
  ConditionOption(predicate: 'has_trimming', label: 'если есть подрезка'),
  ConditionOption(
    predicate: 'handle_type_is',
    label: 'если тип ручки',
    requiresParam: true,
  ),
];

/// Человеческая подпись условия блока.
///
/// Своя, а не [conditionLabel]: тот принимает `RouteCondition` — строку из
/// таблицы этапов, и подгонять одну модель под две таблицы значило бы связать
/// их изменения.
String blockConditionLabel({
  required String predicate,
  required bool negate,
  String? param,
}) {
  final base = switch (predicate) {
    'has_form' => 'есть печатная форма',
    'has_paint' => 'есть краски',
    'has_cardboard' => 'есть картон',
    'has_trimming' => 'есть подрезка',
    'handle_type_is' =>
      'ручка ${kHandleTypeParamLabels[param] ?? param ?? ''}',
    _ => predicate,
  };
  return negate ? 'не $base' : base;
}
