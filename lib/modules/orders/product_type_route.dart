/// Сборка очереди этапов по настройкам типа продукта.
///
/// Читает то, что миграции 20260807 положили в базу: product_type_stages
/// (оба уровня), product_type_stage_workplaces, product_type_stage_conditions.
/// Отдаёт тот же `List<BuiltOrderStage>`, что и зашитый в код
/// `buildOrderStages`, поэтому вся постобработка —
/// `normalizeBuiltOrderStageQueue` с дедупом, канонизацией алиасов и
/// принудительными именами Бабинорезки, Флексопечати и Упаковки — работает
/// поверх без изменений. Новый сборщик отвечает только за СОСТАВ.
///
/// Боевой путь на него не переключён: `buildOrderStageQueue` по-прежнему
/// вызывает старые правила. Переключение — фаза 3.5, после P0-A.
library;

import 'order_handle_type.dart';
import 'stage_queue_builder.dart';

/// Рабочее место этапа. При `selection_mode = one_of` строка — это вариант.
class RouteStageWorkplace {
  const RouteStageWorkplace({
    required this.rowId,
    required this.workplaceId,
    this.variantTitle,
    this.isDefault = false,
    this.sortOrder = 0,
  });

  /// `product_type_stage_workplaces.id` — на него ссылаются под-этапы.
  final String rowId;
  final String workplaceId;
  final String? variantTitle;
  final bool isDefault;
  final int sortOrder;

  factory RouteStageWorkplace.fromMap(Map<String, dynamic> map) {
    final title = (map['variantTitle'] ?? map['variant_title'])?.toString();
    return RouteStageWorkplace(
      rowId: (map['rowId'] ?? map['id']).toString(),
      workplaceId: (map['workplaceId'] ?? map['workplace_id']).toString(),
      variantTitle: (title == null || title.trim().isEmpty) ? null : title,
      isDefault: (map['isDefault'] ?? map['is_default']) == true,
      sortOrder: ((map['sortOrder'] ?? map['sort_order']) as num?)?.toInt() ?? 0,
    );
  }
}

/// Условие появления этапа. Условия этапа соединяются через AND; пустой
/// список означает «всегда».
class RouteCondition {
  const RouteCondition({
    required this.predicate,
    this.negate = false,
    this.param,
  });

  final String predicate;
  final bool negate;
  final String? param;

  factory RouteCondition.fromMap(Map<String, dynamic> map) {
    final param = (map['param'] ?? map['param_text'])?.toString();
    return RouteCondition(
      predicate: (map['predicate'] ?? '').toString(),
      negate: map['negate'] == true,
      param: (param == null || param.isEmpty) ? null : param,
    );
  }
}

class RouteStage {
  const RouteStage({
    required this.rowId,
    required this.key,
    required this.title,
    required this.position,
    required this.level,
    this.parentVariantId,
    this.selectionMode = 'all',
    this.isEnabled = true,
    this.isPinnedLast = false,
    this.workplaces = const <RouteStageWorkplace>[],
    this.conditions = const <RouteCondition>[],
  });

  final String rowId;

  /// Уходит в `prod_plan_stages.stage_group_key`.
  final String key;

  /// Метка редактора. Для `one_of` имя этапа в очереди берётся НЕ отсюда,
  /// а из `variantTitle` выбранного варианта — см. [_stageName].
  final String title;

  final int position;
  final int level;

  /// `product_type_stage_workplaces.id` варианта-владельца, если это под-этап.
  final String? parentVariantId;

  final String selectionMode;
  final bool isEnabled;
  final bool isPinnedLast;
  final List<RouteStageWorkplace> workplaces;
  final List<RouteCondition> conditions;

  bool get isSwitchable => selectionMode == 'one_of';

  factory RouteStage.fromMap(Map<String, dynamic> map) {
    final parent = (map['parentVariantId'] ?? map['parent_variant_id'])
        ?.toString();
    return RouteStage(
      rowId: (map['rowId'] ?? map['id']).toString(),
      key: (map['key'] ?? map['stage_group_key']).toString(),
      title: (map['title'] ?? '').toString(),
      position: ((map['position']) as num?)?.toInt() ?? 0,
      level: ((map['level']) as num?)?.toInt() ?? 0,
      parentVariantId: (parent == null || parent.isEmpty) ? null : parent,
      selectionMode:
          (map['selectionMode'] ?? map['selection_mode'] ?? 'all').toString(),
      isEnabled: (map['isEnabled'] ?? map['is_enabled']) != false,
      isPinnedLast: (map['isPinnedLast'] ?? map['is_pinned_last']) == true,
      workplaces: <RouteStageWorkplace>[
        for (final w in (map['workplaces'] as List? ?? const []))
          RouteStageWorkplace.fromMap(Map<String, dynamic>.from(w as Map)),
      ]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)),
      conditions: <RouteCondition>[
        for (final c in (map['conditions'] as List? ?? const []))
          RouteCondition.fromMap(Map<String, dynamic>.from(c as Map)),
      ],
    );
  }
}

/// Маршрут одного типа продукта — опубликованная версия настроек.
class ProductTypeRoute {
  const ProductTypeRoute({
    required this.productTypeId,
    required this.title,
    required this.configId,
    this.stages = const <RouteStage>[],
  });

  final String productTypeId;
  final String title;
  final String configId;
  final List<RouteStage> stages;

  Iterable<RouteStage> get switchableStages =>
      stages.where((s) => s.isSwitchable);

  factory ProductTypeRoute.fromMap(Map<String, dynamic> map) {
    return ProductTypeRoute(
      productTypeId: (map['id'] ?? map['productTypeId']).toString(),
      title: (map['title'] ?? '').toString(),
      configId: (map['configId'] ?? map['config_id'] ?? '').toString(),
      stages: <RouteStage>[
        for (final s in (map['stages'] as List? ?? const []))
          RouteStage.fromMap(Map<String, dynamic>.from(s as Map)),
      ],
    );
  }
}

/// Собирает очередь этапов заказа по настройкам типа продукта.
///
/// Возвращает то же, что и `buildOrderStages`, — постобработка общая.
List<BuiltOrderStage> buildOrderStagesFromRoute(
  OrderStageQueueDraft draft,
  ProductTypeRoute route,
) {
  // 1. Для каждого переключаемого этапа определяем выбранный вариант.
  //    Запоминаем и id рабочего места (пойдёт в очередь), и id СТРОКИ
  //    варианта — по нему включаются под-этапы.
  final selectedWorkplaceByStage = <String, String>{};
  final activeVariantRowIds = <String>{};

  for (final stage in route.stages) {
    if (!stage.isSwitchable || !stage.isEnabled) continue;
    if (stage.workplaces.isEmpty) continue;
    final variant = _selectedVariant(draft, stage);
    selectedWorkplaceByStage[stage.rowId] = variant.workplaceId;
    activeVariantRowIds.add(variant.rowId);
  }

  // 2. Отбираем этапы. Под-этап живёт, только пока выбран его вариант;
  //    отрицания в условиях для этого не нужно — «не Труба» выражено тем,
  //    чьим под-этапом является строка.
  final selected = <RouteStage>[];
  for (final stage in route.stages) {
    if (!stage.isEnabled) continue;
    if (stage.workplaces.isEmpty) continue;
    if (stage.level == 1 &&
        !activeVariantRowIds.contains(stage.parentVariantId)) {
      continue;
    }
    if (!_conditionsHold(draft, stage)) continue;
    selected.add(stage);
  }

  // 3. Порядок сквозной по конфигу: под-этапы варианта встают на СВОЮ
  //    позицию, а не следом за переключателем. У П-образного пакета между
  //    переключателем (3) и «Вставкой картона» (6) стоят два общих этапа —
  //    контейнерная модель такого не выразила бы. Второй ключ сортировки
  //    делает порядок детерминированным: три этапа ручек делят одну позицию.
  selected.sort((a, b) {
    final byPosition = a.position.compareTo(b.position);
    if (byPosition != 0) return byPosition;
    return a.key.compareTo(b.key);
  });

  final tail = selected.where((s) => s.isPinnedLast).toList(growable: false);
  final body = selected.where((s) => !s.isPinnedLast).toList(growable: false);
  final ordered = <RouteStage>[...body, ...tail];

  return <BuiltOrderStage>[
    for (var i = 0; i < ordered.length; i++)
      _toBuiltStage(ordered[i], selectedWorkplaceByStage, i + 1),
  ];
}

BuiltOrderStage _toBuiltStage(
  RouteStage stage,
  Map<String, String> selectedWorkplaceByStage,
  int sortOrder,
) {
  final workplaceIds =
      stage.workplaces.map((w) => w.workplaceId).toList(growable: false);
  final selectedId = stage.isSwitchable
      ? (selectedWorkplaceByStage[stage.rowId] ?? workplaceIds.first)
      : workplaceIds.first;

  return BuiltOrderStage(
    stageKey: stage.key,
    stageName: _stageName(stage, selectedId),
    workplaceIds: workplaceIds,
    sortOrder: sortOrder,
    isSwitchable: stage.isSwitchable,
    selectedWorkplaceId: selectedId,
  );
}

/// Имя этапа в очереди.
///
/// Для переключаемого этапа берётся у ВЫБРАННОГО варианта, а не из
/// `product_type_stages.title`: в старом коде эту роль играет `_selectedName`,
/// и оператор видит «Фри», а не «Формирование дна». Поле title — метка
/// редактора; переименование меняет подпись и никогда не ключ.
String _stageName(RouteStage stage, String selectedWorkplaceId) {
  if (!stage.isSwitchable) return stage.title;
  for (final w in stage.workplaces) {
    if (w.workplaceId != selectedWorkplaceId) continue;
    final title = w.variantTitle;
    if (title != null && title.trim().isNotEmpty) return title;
  }
  return stage.title;
}

/// Какой вариант переключаемого этапа берём.
///
/// Порядок тот же, что у `_selectedForSwitchable` в старом билдере:
/// сначала явный выбор по ключу этапа, затем одиночный
/// `selectedSwitchableStageId`, если он принадлежит этому этапу, иначе
/// вариант по умолчанию.
///
/// Одно отличие: старый код умеет ещё и legacy-ключи групп
/// (`v_bottom_stage`, `p_package_stage`), которых в схеме нет — там
/// `switchableStageKey` сверяется и с ними. Здесь сверка идёт только с
/// ключом этапа.
RouteStageWorkplace _selectedVariant(
  OrderStageQueueDraft draft,
  RouteStage stage,
) {
  final byStageKey = draft.selectedSwitchableStageIdsByStageKey[stage.key];
  final explicit = _workplaceById(stage, byStageKey);
  if (explicit != null) return explicit;

  final keyFilter = draft.switchableStageKey;
  if (keyFilter == null || keyFilter == stage.key) {
    final single = _workplaceById(stage, draft.selectedSwitchableStageId);
    if (single != null) return single;
  }

  for (final w in stage.workplaces) {
    if (w.isDefault) return w;
  }
  return stage.workplaces.first;
}

RouteStageWorkplace? _workplaceById(RouteStage stage, String? workplaceId) {
  if (workplaceId == null || workplaceId.isEmpty) return null;
  for (final w in stage.workplaces) {
    if (w.workplaceId == workplaceId) return w;
  }
  return null;
}

bool _conditionsHold(OrderStageQueueDraft draft, RouteStage stage) {
  for (final condition in stage.conditions) {
    final value = _evaluatePredicate(draft, condition);
    if (condition.negate ? value : !value) return false;
  }
  return true;
}

/// Неизвестный предикат даёт false — этап не появляется.
///
/// Внешний ключ на `order_predicates` гарантирует, что в базе лежат только
/// коды из справочника, поэтому сюда можно попасть лишь при расхождении
/// версий: в справочник добавили предикат, а приложение ещё старое. Тихо
/// добавить этап в таком случае опаснее, чем тихо не добавить.
bool _evaluatePredicate(OrderStageQueueDraft draft, RouteCondition condition) {
  switch (condition.predicate) {
    case 'has_paint':
      return draft.hasPaint;
    case 'has_cardboard':
      return draft.hasCardboard;
    case 'has_trimming':
      return draft.hasTrimming;
    case 'needs_bobbin_cutting':
      return _needsBobbinCutting(draft);
    case 'handle_type_is':
      return _handleTypeName(draft.handleType) == condition.param;
    default:
      return false;
  }
}

/// Повторяет `_OrderStageQueueBuilder._needsBobbinCutting`.
///
/// Готовый флаг `requiresBobbinCutting` имеет приоритет: его считает
/// `requiresBobbinCuttingForOrder` по всему списку бумаг заказа, и свести это
/// к сравнению двух полей нельзя — там итерация по коллекции, разбор числа из
/// строки формата и допуск.
bool _needsBobbinCutting(OrderStageQueueDraft draft) {
  final explicit = draft.requiresBobbinCutting;
  if (explicit != null) return explicit;
  final orderWidth = draft.orderWidthB;
  final material = draft.materialWidth;
  if (orderWidth == null || material == null) return false;
  return orderWidth > 0 && material > 0 && orderWidth < material;
}

String? _handleTypeName(Object? handleType) {
  if (handleType is OrderHandleType) return handleType.name;
  final raw = handleType?.toString().trim();
  if (raw == null || raw.isEmpty) return null;
  // На случай, если тип пришёл строкой вида 'OrderHandleType.flat'.
  final dot = raw.lastIndexOf('.');
  return dot >= 0 ? raw.substring(dot + 1) : raw;
}
