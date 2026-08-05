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

  /// product_type_id → опубликованная версия настроек.
  final Map<String, ProductTypeConfig> _publishedByType =
      <String, ProductTypeConfig>{};

  /// config_id → block_code → is_visible. Отсутствие ключа = блок виден.
  final Map<String, Map<String, bool>> _visibilityByConfig =
      <String, Map<String, bool>>{};

  bool get isLoaded => _loaded;

  List<ProductTypeRef> get productTypes => List.unmodifiable(_types);

  List<String> get productTypeTitles =>
      _types.map((t) => t.title).toList(growable: false);

  List<OrderFormBlock> get formBlocks => List.unmodifiable(_blocks);

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

    _loaded = true;
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
  }) {
    _types = types;
    _blocks = blocks;
    _publishedByType
      ..clear()
      ..addAll(publishedByType);
    _visibilityByConfig
      ..clear()
      ..addAll(visibilityByConfig);
    _loaded = true;
  }

  @visibleForTesting
  void resetForTesting() {
    _types = const <ProductTypeRef>[];
    _blocks = const <OrderFormBlock>[];
    _publishedByType.clear();
    _visibilityByConfig.clear();
    _loaded = false;
    _loading = null;
  }
}
