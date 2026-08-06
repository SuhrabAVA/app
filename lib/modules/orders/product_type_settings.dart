/// Настройки типов продукта: какие блоки формы заказа активны.
///
/// До миграции 20260806 зависимость формы от типа продукта существовала ровно
/// одна и была зашита в код — `supportsCardboardForProductType()`. Теперь она
/// живёт в данных: `product_type_configs` (версия настроек на тип продукта) и
/// `product_type_form_blocks` (отклонения от умолчания).
///
/// Кэш на сессию. Справочник типов, блоки и настройки читаются одним прогревом,
/// поэтому при открытии заказа отдельного запроса не делается.
library;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'product_type_route.dart';

/// Коды блоков формы заказа. Совпадают с `order_form_blocks.code`.
const String kOrderFormBlockCardboard = 'cardboard';
const String kOrderFormBlockTrimming = 'trimming';
const String kOrderFormBlockHandle = 'handle';
const String kOrderFormBlockPaints = 'paints';
const String kOrderFormBlockForm = 'form';
const String kOrderFormBlockPdf = 'pdf';
const String kOrderFormBlockMakeready = 'makeready';
const String kOrderFormBlockExtraPapers = 'extra_papers';
const String kOrderFormBlockRoll = 'roll';
const String kOrderFormBlockBlQuantity = 'bl_quantity';

/// Тип продукта — строка справочника `warehouse_categories`.
@immutable
class ProductTypeRef {
  const ProductTypeRef({required this.id, required this.title});

  final String id;
  final String title;

  static ProductTypeRef? fromMap(Map<String, dynamic> map) {
    final id = (map['id'] ?? '').toString().trim();
    final title = (map['title'] ?? map['code'] ?? '').toString().trim();
    if (id.isEmpty || title.isEmpty) return null;
    return ProductTypeRef(id: id, title: title);
  }
}

/// Рабочее место — строка справочника `public.workplaces`.
///
/// Нужен редактору маршрута: рабочие места этапа выбираются из списка, а не
/// вводятся текстом. Свободный ввод вернул бы опечатки в идентификаторах,
/// ради которых заведён реестр `production_ids.dart`.
@immutable
class WorkplaceRef {
  const WorkplaceRef({required this.id, required this.name});

  final String id;
  final String name;

  static WorkplaceRef? fromMap(Map<String, dynamic> map) {
    final id = (map['id'] ?? '').toString().trim();
    final name = (map['name'] ?? '').toString().trim();
    if (id.isEmpty) return null;
    return WorkplaceRef(id: id, name: name.isEmpty ? id : name);
  }
}

/// Блок формы заказа — строка справочника `order_form_blocks`.
@immutable
class OrderFormBlock {
  const OrderFormBlock({
    required this.code,
    required this.title,
    this.affectsInput,
    this.sortOrder = 0,
  });

  final String code;
  final String title;

  /// Какой вход автосборщика обнуляется при скрытии блока.
  ///
  /// В этом срезе не применяется — построение очереди пока не трогаем. Поле
  /// нужно редактору, чтобы предупредить техлида о будущем эффекте.
  final String? affectsInput;

  final int sortOrder;

  bool get affectsStageQueue => (affectsInput ?? '').trim().isNotEmpty;

  static OrderFormBlock? fromMap(Map<String, dynamic> map) {
    final code = (map['code'] ?? '').toString().trim();
    if (code.isEmpty) return null;
    final affects = (map['affects_input'] ?? '').toString().trim();
    return OrderFormBlock(
      code: code,
      title: (map['title'] ?? code).toString(),
      affectsInput: affects.isEmpty ? null : affects,
      sortOrder: (map['sort_order'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Версия настроек типа продукта — строка `product_type_configs`.
@immutable
class ProductTypeConfig {
  const ProductTypeConfig({
    required this.id,
    required this.productTypeId,
    required this.version,
    required this.status,
  });

  static const String statusDraft = 'draft';
  static const String statusPublished = 'published';
  static const String statusArchived = 'archived';

  final String id;
  final String productTypeId;
  final int version;
  final String status;

  bool get isDraft => status == statusDraft;
  bool get isPublished => status == statusPublished;

  static ProductTypeConfig? fromMap(Map<String, dynamic> map) {
    final id = (map['id'] ?? '').toString().trim();
    final productTypeId = (map['product_type_id'] ?? '').toString().trim();
    if (id.isEmpty || productTypeId.isEmpty) return null;
    return ProductTypeConfig(
      id: id,
      productTypeId: productTypeId,
      version: (map['version'] as num?)?.toInt() ?? 1,
      status: (map['status'] ?? statusDraft).toString(),
    );
  }
}

/// Кэш настроек типов продукта на сессию.
class ProductTypeSettings {
  ProductTypeSettings._();

  static final ProductTypeSettings instance = ProductTypeSettings._();

  SupabaseClient get _sb => Supabase.instance.client;

  bool _loaded = false;
  Future<void>? _loading;

  List<ProductTypeRef> _types = const <ProductTypeRef>[];
  List<OrderFormBlock> _blocks = const <OrderFormBlock>[];
  List<WorkplaceRef> _workplaces = const <WorkplaceRef>[];

  /// product_type_id → опубликованная версия настроек.
  final Map<String, ProductTypeConfig> _publishedByType =
      <String, ProductTypeConfig>{};

  /// config_id → block_code → is_visible. Отсутствие ключа = блок виден.
  final Map<String, Map<String, bool>> _visibilityByConfig =
      <String, Map<String, bool>>{};

  /// product_type_id → маршрут опубликованной версии.
  ///
  /// Читается тем же прогревом, что и блоки формы: сборщику очереди отдельный
  /// запрос при открытии заказа не нужен.
  final Map<String, ProductTypeRoute> _routesByType =
      <String, ProductTypeRoute>{};

  bool get isLoaded => _loaded;

  List<ProductTypeRef> get productTypes => List.unmodifiable(_types);

  List<String> get productTypeTitles =>
      _types.map((t) => t.title).toList(growable: false);

  List<OrderFormBlock> get formBlocks => List.unmodifiable(_blocks);

  /// Справочник рабочих мест для выпадающих списков редактора маршрута.
  List<WorkplaceRef> get workplaces => List.unmodifiable(_workplaces);

  String workplaceName(String workplaceId) {
    for (final w in _workplaces) {
      if (w.id == workplaceId) return w.name;
    }
    return workplaceId;
  }

  /// Загружает справочники и настройки один раз за сессию.
  ///
  /// Параллельные вызовы разделяют один и тот же Future — двойной вызов из
  /// `initState` редактора заказа не приводит к двум запросам.
  Future<void> ensureLoaded({bool force = false}) {
    if (force) {
      _loaded = false;
      _loading = null;
    }
    if (_loaded) return Future<void>.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    final types = await _sb
        .from('warehouse_categories')
        .select('id, title')
        .order('title');
    final blocks = await _sb
        .from('order_form_blocks')
        .select('code, title, affects_input, sort_order')
        .order('sort_order');
    final configs = await _sb
        .from('product_type_configs')
        .select('id, product_type_id, version, status')
        .eq('status', ProductTypeConfig.statusPublished);
    final overrides = await _sb
        .from('product_type_form_blocks')
        .select('config_id, block_code, is_visible');
    final workplaces =
        await _sb.from('workplaces').select('id, name').order('name');

    _workplaces = <WorkplaceRef>[
      for (final row in (workplaces as List))
        if (WorkplaceRef.fromMap(Map<String, dynamic>.from(row as Map))
            case final ref?)
          ref,
    ];

    _types = <ProductTypeRef>[
      for (final row in (types as List))
        if (ProductTypeRef.fromMap(Map<String, dynamic>.from(row as Map))
            case final ref?)
          ref,
    ];
    _blocks = <OrderFormBlock>[
      for (final row in (blocks as List))
        if (OrderFormBlock.fromMap(Map<String, dynamic>.from(row as Map))
            case final block?)
          block,
    ];

    _publishedByType.clear();
    for (final row in (configs as List)) {
      final config =
          ProductTypeConfig.fromMap(Map<String, dynamic>.from(row as Map));
      if (config != null) _publishedByType[config.productTypeId] = config;
    }

    _visibilityByConfig.clear();
    for (final row in (overrides as List)) {
      final map = Map<String, dynamic>.from(row as Map);
      final configId = (map['config_id'] ?? '').toString();
      final code = (map['block_code'] ?? '').toString();
      if (configId.isEmpty || code.isEmpty) continue;
      _visibilityByConfig
          .putIfAbsent(configId, () => <String, bool>{})[code] =
          map['is_visible'] != false;
    }

    await _loadRoutes();
    _loaded = true;
  }

  /// Маршруты опубликованных версий: этапы обоих уровней, их рабочие места и
  /// условия.
  Future<void> _loadRoutes() async {
    _routesByType.clear();
    final configIds = _publishedByType.values.map((c) => c.id).toList();
    if (configIds.isEmpty) return;

    final stagesByConfig = await _fetchStagesByConfig(configIds);
    for (final type in _types) {
      final config = _publishedByType[type.id];
      if (config == null) continue;
      _routesByType[type.id] = ProductTypeRoute(
        productTypeId: type.id,
        title: type.title,
        configId: config.id,
        stages: stagesByConfig[config.id] ?? const <RouteStage>[],
      );
    }
  }

  /// Читает маршрут КОНКРЕТНОЙ версии, минуя кэш.
  ///
  /// Редактору нужен черновик, а кэш держит только опубликованные версии.
  /// После каждой правки данные всё равно перечитываются, поэтому кэшировать
  /// здесь нечего.
  Future<ProductTypeRoute> loadRouteForConfig({
    required String configId,
    required String productTypeId,
    required String title,
  }) async {
    final stagesByConfig = await _fetchStagesByConfig(<String>[configId]);
    return ProductTypeRoute(
      productTypeId: productTypeId,
      title: title,
      configId: configId,
      stages: stagesByConfig[configId] ?? const <RouteStage>[],
    );
  }

  /// Собирает граф этапов трёмя запросами вместо N+1.
  Future<Map<String, List<RouteStage>>> _fetchStagesByConfig(
    List<String> configIds,
  ) async {
    if (configIds.isEmpty) return const <String, List<RouteStage>>{};

    final stages = await _sb
        .from('product_type_stages')
        .select('id, config_id, parent_variant_id, level, stage_group_key, '
            'title, position, selection_mode, is_enabled, is_pinned_last')
        .inFilter('config_id', configIds);
    final stageRows = <Map<String, dynamic>>[
      for (final row in (stages as List)) Map<String, dynamic>.from(row as Map),
    ];
    final stageIds =
        stageRows.map((r) => r['id'].toString()).toList(growable: false);
    if (stageIds.isEmpty) return const <String, List<RouteStage>>{};

    final workplaces = await _sb
        .from('product_type_stage_workplaces')
        .select('id, stage_id, workplace_id, variant_title, is_default, sort_order')
        .inFilter('stage_id', stageIds);
    final conditions = await _sb
        .from('product_type_stage_conditions')
        .select('stage_id, predicate, negate, param_text')
        .inFilter('stage_id', stageIds);

    final workplacesByStage = <String, List<Map<String, dynamic>>>{};
    for (final row in (workplaces as List)) {
      final map = Map<String, dynamic>.from(row as Map);
      workplacesByStage
          .putIfAbsent(map['stage_id'].toString(), () => [])
          .add(map);
    }
    final conditionsByStage = <String, List<Map<String, dynamic>>>{};
    for (final row in (conditions as List)) {
      final map = Map<String, dynamic>.from(row as Map);
      conditionsByStage
          .putIfAbsent(map['stage_id'].toString(), () => [])
          .add(map);
    }

    final stagesByConfig = <String, List<RouteStage>>{};
    for (final row in stageRows) {
      final stageId = row['id'].toString();
      stagesByConfig
          .putIfAbsent(row['config_id'].toString(), () => [])
          .add(RouteStage.fromMap(<String, dynamic>{
            ...row,
            'rowId': stageId,
            'key': row['stage_group_key'],
            'workplaces': workplacesByStage[stageId] ?? const [],
            'conditions': conditionsByStage[stageId] ?? const [],
          }));
    }
    return stagesByConfig;
  }

  /// Маршрут типа продукта; принимает и uuid, и заголовок.
  ProductTypeRoute? routeFor(String productTypeIdOrTitle) {
    final id = resolveProductTypeId(productTypeIdOrTitle);
    return id == null ? null : _routesByType[id];
  }

  /// Сбрасывает кэш — вызывается после публикации новой версии настроек.
  void invalidate() {
    _loaded = false;
    _loading = null;
  }

  /// Принимает и uuid типа продукта, и его заголовок.
  ///
  /// Заголовок нужен потому, что форма заказа до сих пор держит тип строкой в
  /// `product.type`; uuid появился в `orders.product_type_id` только сейчас.
  String? resolveProductTypeId(String productTypeIdOrTitle) {
    final value = productTypeIdOrTitle.trim();
    if (value.isEmpty) return null;
    for (final type in _types) {
      if (type.id == value) return type.id;
    }
    final normalized = value.toLowerCase();
    for (final type in _types) {
      if (type.title.trim().toLowerCase() == normalized) return type.id;
    }
    return null;
  }

  ProductTypeConfig? publishedConfigFor(String productTypeIdOrTitle) {
    final id = resolveProductTypeId(productTypeIdOrTitle);
    return id == null ? null : _publishedByType[id];
  }

  /// Виден ли блок формы для этого типа продукта.
  ///
  /// Отсутствие строки настройки означает «виден» — таблица заполняется только
  /// отклонениями от умолчания. Неизвестный тип продукта или незагруженный кэш
  /// тоже дают «виден»: спрятать нужное поле хуже, чем показать лишнее.
  bool isBlockVisible(String productTypeIdOrTitle, String blockCode) {
    final config = publishedConfigFor(productTypeIdOrTitle);
    if (config == null) return true;
    return _visibilityByConfig[config.id]?[blockCode] ?? true;
  }

  @visibleForTesting
  void seedForTesting({
    List<ProductTypeRef> types = const <ProductTypeRef>[],
    List<OrderFormBlock> blocks = const <OrderFormBlock>[],
    Map<String, ProductTypeConfig> publishedByType =
        const <String, ProductTypeConfig>{},
    Map<String, Map<String, bool>> visibilityByConfig =
        const <String, Map<String, bool>>{},
    Map<String, ProductTypeRoute> routesByType =
        const <String, ProductTypeRoute>{},
  }) {
    _types = types;
    _blocks = blocks;
    _publishedByType
      ..clear()
      ..addAll(publishedByType);
    _visibilityByConfig
      ..clear()
      ..addAll(visibilityByConfig);
    _routesByType
      ..clear()
      ..addAll(routesByType);
    _loaded = true;
  }

  @visibleForTesting
  void resetForTesting() {
    _types = const <ProductTypeRef>[];
    _blocks = const <OrderFormBlock>[];
    _publishedByType.clear();
    _visibilityByConfig.clear();
    _routesByType.clear();
    _loaded = false;
    _loading = null;
  }
}
