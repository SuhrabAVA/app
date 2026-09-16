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

import '../../services/realtime_sync_service.dart';
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

/// Формула фактического количества — строка справочника
/// `actual_qty_formulas`.
@immutable
class ActualQtyFormulaRef {
  const ActualQtyFormulaRef({
    required this.code,
    required this.title,
    required this.description,
  });

  final String code;
  final String title;
  final String description;

  factory ActualQtyFormulaRef.fromMap(Map<String, dynamic> map) =>
      ActualQtyFormulaRef(
        code: (map['code'] ?? '').toString(),
        title: (map['title'] ?? '').toString(),
        description: (map['description'] ?? '').toString(),
      );
}

/// Блок формы заказа — строка справочника `order_form_blocks`.
@immutable
class OrderFormBlock {
  const OrderFormBlock({
    required this.code,
    required this.title,
    this.affectsInput,
    this.sortOrder = 0,
    this.canHide = true,
  });

  final String code;
  final String title;

  /// Какой вход автосборщика обнуляется при скрытии блока.
  ///
  /// В этом срезе не применяется — построение очереди пока не трогаем. Поле
  /// нужно редактору, чтобы предупредить техлида о будущем эффекте.
  final String? affectsInput;

  final int sortOrder;

  /// Можно ли выключить блок. `false` — блок в форме всегда, но потребовать
  /// его заполнение техлид может: см. `order_form_blocks.can_hide`.
  final bool canHide;

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
      canHide: map['can_hide'] != false,
    );
  }
}

/// Условие обязательности блока — строка
/// `product_type_form_block_conditions`.
///
/// Механизм повторяет условия этапов: закрытый справочник предикатов, AND
/// между условиями одного блока, отсутствие условий = «всегда».
class OrderBlockCondition {
  const OrderBlockCondition({
    required this.predicate,
    this.negate = false,
    this.param,
  });

  final String predicate;
  final bool negate;
  final String? param;

  static OrderBlockCondition? tryFromMap(Map<String, dynamic> map) {
    final predicate = (map['predicate'] ?? '').toString().trim();
    if (predicate.isEmpty) return null;
    final param = (map['param_text'] ?? map['param'])?.toString().trim();
    return OrderBlockCondition(
      predicate: predicate,
      negate: map['negate'] == true,
      param: (param == null || param.isEmpty) ? null : param,
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
  ProductTypeSettings._() {
    RealtimeSyncService.instance.registerRefreshHandler(
      owner: this,
      resource: RealtimeResource.productTypeSettings,
      handler: () async {
        if (_loaded) await ensureLoaded(force: true);
      },
    );
  }

  static final ProductTypeSettings instance = ProductTypeSettings._();

  SupabaseClient get _sb => Supabase.instance.client;

  bool _loaded = false;
  Future<void>? _loading;
  bool _reloadRequested = false;

  List<ProductTypeRef> _types = const <ProductTypeRef>[];
  List<OrderFormBlock> _blocks = const <OrderFormBlock>[];
  List<WorkplaceRef> _workplaces = const <WorkplaceRef>[];
  List<ActualQtyFormulaRef> _formulas = const <ActualQtyFormulaRef>[];

  /// product_type_id → опубликованная версия настроек.
  final Map<String, ProductTypeConfig> _publishedByType =
      <String, ProductTypeConfig>{};

  /// config_id → block_code → is_visible. Отсутствие ключа = блок виден.
  final Map<String, Map<String, bool>> _visibilityByConfig =
      <String, Map<String, bool>>{};

  /// config_id → block_code → is_required. Отсутствие ключа = не обязателен.
  ///
  /// Умолчание противоположно видимости, и намеренно: невидимый блок обязан
  /// быть необязательным, а новый блок в справочнике не должен задним числом
  /// уронить в черновики все заказы типа продукта.
  final Map<String, Map<String, bool>> _requiredByConfig =
      <String, Map<String, bool>>{};

  /// config_id → block_code → условия обязательности (AND).
  ///
  /// Отсутствие ключа = «обязателен всегда», как у этапов: условия — это
  /// сужение требования, а не его источник.
  final Map<String, Map<String, List<OrderBlockCondition>>>
      _blockConditionsByConfig =
      <String, Map<String, List<OrderBlockCondition>>>{};

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

  /// Коды блоков в порядке справочника — им же упорядочены сообщения о
  /// незаполненном, чтобы список читался в порядке полей формы.
  List<String> get formBlockCodes =>
      _blocks.map((block) => block.code).toList(growable: false);

  Map<String, String> get formBlockTitles => <String, String>{
        for (final block in _blocks) block.code: block.title,
      };

  /// Справочник рабочих мест для выпадающих списков редактора маршрута.
  List<WorkplaceRef> get workplaces => List.unmodifiable(_workplaces);

  /// Справочник формул фактического количества.
  ///
  /// Закрытый список: каждый код реализован функцией в Dart, поэтому новая
  /// формула — это релиз приложения, а не строка в таблице.
  List<ActualQtyFormulaRef> get actualQtyFormulas =>
      List.unmodifiable(_formulas);

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
      if (_loading != null) {
        _reloadRequested = true;
        return _loading!;
      }
      _loaded = false;
    }
    if (_loaded) return Future<void>.value();
    final active = _loading;
    if (active != null) return active;
    final future = _runLoadLoop();
    _loading = future;
    return future.whenComplete(() {
      if (identical(_loading, future)) _loading = null;
    });
  }

  Future<void> _runLoadLoop() async {
    do {
      _reloadRequested = false;
      await _load();
    } while (_reloadRequested);
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
        .select('config_id, block_code, is_visible, is_required');
    // Новые объекты читаются ОТДЕЛЬНО и переживают своё отсутствие.
    //
    // Прогрев настроек держит на себе весь модуль заказов: список типов
    // продукта, видимость блоков формы, маршруты. Одним общим await это
    // означало, что не доехавшая до базы миграция роняет всё сразу — ровно
    // так экран типов продукта и умер с «Could not find the table
    // product_type_form_block_conditions». Пока объекта нет, правильный ответ
    // не «ошибка», а «условий нет» и «скрывать можно всё».
    final canHideByCode = await _readCanHideFlags();
    final blockConditions = await _readBlockConditions();
    final workplaces =
        await _sb.from('workplaces').select('id, name').order('name');
    final formulas = await _sb
        .from('actual_qty_formulas')
        .select('code, title, description')
        .order('sort_order');

    _formulas = <ActualQtyFormulaRef>[
      for (final row in (formulas as List))
        ActualQtyFormulaRef.fromMap(Map<String, dynamic>.from(row as Map)),
    ];

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
        if (OrderFormBlock.fromMap(<String, dynamic>{
          ...Map<String, dynamic>.from(row as Map),
          if (canHideByCode.containsKey((row['code'] ?? '').toString()))
            'can_hide': canHideByCode[(row['code'] ?? '').toString()],
        }) case final block?)
          block,
    ];

    _publishedByType.clear();
    for (final row in (configs as List)) {
      final config =
          ProductTypeConfig.fromMap(Map<String, dynamic>.from(row as Map));
      if (config != null) _publishedByType[config.productTypeId] = config;
    }

    _visibilityByConfig.clear();
    _requiredByConfig.clear();
    for (final row in (overrides as List)) {
      final map = Map<String, dynamic>.from(row as Map);
      final configId = (map['config_id'] ?? '').toString();
      final code = (map['block_code'] ?? '').toString();
      if (configId.isEmpty || code.isEmpty) continue;
      _visibilityByConfig.putIfAbsent(configId, () => <String, bool>{})[code] =
          map['is_visible'] != false;
      _requiredByConfig.putIfAbsent(configId, () => <String, bool>{})[code] =
          map['is_required'] == true;
    }

    _blockConditionsByConfig.clear();
    for (final row in blockConditions) {
      final map = Map<String, dynamic>.from(row as Map);
      final configId = (map['config_id'] ?? '').toString();
      final code = (map['block_code'] ?? '').toString();
      final condition = OrderBlockCondition.tryFromMap(map);
      if (configId.isEmpty || code.isEmpty || condition == null) continue;
      _blockConditionsByConfig
          .putIfAbsent(configId, () => <String, List<OrderBlockCondition>>{})
          .putIfAbsent(code, () => <OrderBlockCondition>[])
          .add(condition);
    }

    await _loadRoutes();
    _loaded = true;
  }

  /// `code → can_hide`; пустая карта — колонки ещё нет.
  ///
  /// Отдельным запросом, а не колонкой в общем select: PostgREST отвечает
  /// ошибкой на весь запрос, если хоть одной колонки нет, и справочник блоков
  /// пропал бы целиком вместе с формой заказа.
  Future<Map<String, bool>> _readCanHideFlags() async {
    try {
      final rows = await _sb.from('order_form_blocks').select('code, can_hide');
      return <String, bool>{
        for (final row in (rows as List))
          (Map<String, dynamic>.from(row as Map)['code'] ?? '').toString():
              Map<String, dynamic>.from(row)['can_hide'] != false,
      }..remove('');
    } catch (e) {
      debugPrint('ℹ️ order_form_blocks.can_hide недоступна: $e');
      return const <String, bool>{};
    }
  }

  /// Условия обязательности блоков; пустой список — таблицы ещё нет.
  Future<List<dynamic>> _readBlockConditions() async {
    try {
      final rows = await _sb
          .from('product_type_form_block_conditions')
          .select('config_id, block_code, predicate, negate, param_text');
      return rows as List;
    } catch (e) {
      debugPrint('ℹ️ условия блоков формы недоступны: $e');
      return const <dynamic>[];
    }
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
            'title, position, selection_mode, is_enabled, is_pinned_last, '
            'execution_mode, parallel_with_stage_id')
        .inFilter('config_id', configIds);
    final stageRows = <Map<String, dynamic>>[
      for (final row in (stages as List)) Map<String, dynamic>.from(row as Map),
    ];
    final stageIds =
        stageRows.map((r) => r['id'].toString()).toList(growable: false);
    if (stageIds.isEmpty) return const <String, List<RouteStage>>{};

    final workplaces = await _sb
        .from('product_type_stage_workplaces')
        .select(
            'id, stage_id, workplace_id, variant_title, is_default, sort_order')
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

  /// Обязателен ли блок: без него заказ не уходит в «Готов к запуску».
  ///
  /// Умолчание — «не обязателен», и здесь оно строже, чем у видимости:
  /// неизвестный тип продукта или незагруженный кэш НЕ делают блок
  /// обязательным. Ошибиться в эту сторону безопаснее — заказ уйдёт в
  /// готовность, как уходил раньше; обратная ошибка заперла бы в черновиках
  /// все заказы разом, и починить это можно было бы только релизом.
  ///
  /// Скрытый блок обязательным не бывает: требовать заполнить поле, которого
  /// нет в форме, — тупик без выхода. Правило держится здесь, а не только в
  /// редакторе, чтобы старая строка «скрыт и обязателен» не заперла заказы.
  bool isBlockRequired(String productTypeIdOrTitle, String blockCode) {
    final config = publishedConfigFor(productTypeIdOrTitle);
    if (config == null) return false;
    if (_visibilityByConfig[config.id]?[blockCode] == false) return false;
    return _requiredByConfig[config.id]?[blockCode] ?? false;
  }

  /// Условия обязательности блока: пустой список — «обязателен всегда».
  List<OrderBlockCondition> blockConditions(
    String productTypeIdOrTitle,
    String blockCode,
  ) {
    final config = publishedConfigFor(productTypeIdOrTitle);
    if (config == null) return const <OrderBlockCondition>[];
    return _blockConditionsByConfig[config.id]?[blockCode] ??
        const <OrderBlockCondition>[];
  }

  /// Коды блоков, отмеченных обязательными, — без учёта условий.
  ///
  /// Нужны там, где ещё неизвестно, что в заказе заполнено: по этому списку
  /// решается, стоит ли вообще дочитывать краски и файлы.
  Set<String> requiredBlockCodes(String productTypeIdOrTitle) => <String>{
        for (final block in _blocks)
          if (isBlockRequired(productTypeIdOrTitle, block.code)) block.code,
      };

  @visibleForTesting
  void seedForTesting({
    List<ProductTypeRef> types = const <ProductTypeRef>[],
    List<OrderFormBlock> blocks = const <OrderFormBlock>[],
    Map<String, ProductTypeConfig> publishedByType =
        const <String, ProductTypeConfig>{},
    Map<String, Map<String, bool>> visibilityByConfig =
        const <String, Map<String, bool>>{},
    Map<String, Map<String, bool>> requiredByConfig =
        const <String, Map<String, bool>>{},
    Map<String, Map<String, List<OrderBlockCondition>>>
        blockConditionsByConfig =
        const <String, Map<String, List<OrderBlockCondition>>>{},
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
    _requiredByConfig
      ..clear()
      ..addAll(requiredByConfig);
    _blockConditionsByConfig
      ..clear()
      ..addAll(blockConditionsByConfig);
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
    _requiredByConfig.clear();
    _blockConditionsByConfig.clear();
    _routesByType.clear();
    _loaded = false;
    _loading = null;
    _reloadRequested = false;
  }
}
