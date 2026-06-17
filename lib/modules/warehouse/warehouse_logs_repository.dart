import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/app_auth.dart';

/// Тип действия склада.
enum WarehouseLogAction { arrival, writeoff, inventory }

/// Запись лога склада с уже обогащёнными данными о товаре.
class WarehouseLogEntry {
  WarehouseLogEntry({
    required this.id,
    required this.typeKey,
    required this.action,
    required this.description,
    required this.quantity,
    required this.unit,
    required this.timestampIso,
    this.itemId,
    this.format,
    this.grammage,
    this.note,
    this.byName,
    this.sourceTable,
  }) : timestamp = _tryParseDate(timestampIso);

  final String id;
  final String typeKey;
  final WarehouseLogAction action;
  final String description;
  final double quantity;
  final String unit;
  final String timestampIso;
  final DateTime? timestamp;
  final String? itemId;

  final String? format;
  final String? grammage;
  final String? note;
  final String? byName;
  final String? sourceTable;

  static DateTime? _tryParseDate(String iso) {
    if (iso.isEmpty) return null;
    try {
      return DateTime.parse(iso);
    } catch (_) {
      return null;
    }
  }
}

/// Набор логов (приходы/списания/инвентаризации) по одному типу склада.
class WarehouseLogsBundle {
  const WarehouseLogsBundle({
    required this.typeKey,
    required this.arrivals,
    required this.writeoffs,
    required this.inventories,
  });

  final String typeKey;
  final List<WarehouseLogEntry> arrivals;
  final List<WarehouseLogEntry> writeoffs;
  final List<WarehouseLogEntry> inventories;

  List<WarehouseLogEntry> allEntries() => [
        ...arrivals,
        ...writeoffs,
        ...inventories,
      ];
}

/// Репозиторий для получения логов склада из Supabase.
class WarehouseLogsRepository {
  WarehouseLogsRepository._();

  static final SupabaseClient _client = Supabase.instance.client;

  /// Нормализованные ключи типов складских таблиц.
  static const List<String> supportedTypes = <String>[
    'paint',
    'material',
    'paper',
    'stationery',
    'pens',
  ];

  /// Читабельные подписи типов.
  static const Map<String, String> typeLabels = <String, String>{
    'paint': 'Краски',
    'material': 'Материалы',
    'paper': 'Бумага',
    'stationery': 'Канцтовары',
    'pens': 'Ручки',
  };

  static const Map<String, Map<String, String>> _woMap =
      <String, Map<String, String>>{
    'paint': {
      'table': 'paints_writeoffs',
      'fk': 'paint_id',
      'qty': 'qty',
      'note': 'note'
    },
    'material': {
      'table': 'materials_writeoffs',
      'fk': 'material_id',
      'qty': 'qty',
      'note': 'note'
    },
    'paper': {
      'table': 'papers_writeoffs',
      'fk': 'paper_id',
      'qty': 'qty',
      'note': 'note'
    },
    'stationery': {
      'table': 'warehouse_stationery_writeoffs',
      'fk': 'item_id',
      'qty': 'qty',
      'note': 'reason'
    },
    'pens': {
      'table': 'warehouse_pens_writeoffs',
      'fk': 'item_id',
      'qty': 'qty',
      'note': 'reason'
    },
  };

  static const Map<String, Map<String, String>> _invMap =
      <String, Map<String, String>>{
    'paint': {
      'table': 'paints_inventories',
      'fk': 'paint_id',
      'qty': 'counted_qty',
      'note': 'note'
    },
    'material': {
      'table': 'materials_inventories',
      'fk': 'material_id',
      'qty': 'counted_qty',
      'note': 'note'
    },
    'paper': {
      'table': 'papers_inventories',
      'fk': 'paper_id',
      'qty': 'counted_qty',
      'note': 'note'
    },
    'stationery': {
      'table': 'warehouse_stationery_inventories',
      'fk': 'item_id',
      'qty': 'factual',
      'note': 'note'
    },
    'pens': {
      'table': 'warehouse_pens_inventories',
      'fk': 'item_id',
      'qty': 'counted_qty',
      'note': 'note'
    },
  };

  static const Map<String, Map<String, String>> _arrMap =
      <String, Map<String, String>>{
    'paint': {
      'table': 'paints_arrivals',
      'fk': 'paint_id',
      'qty': 'qty',
      'note': 'note'
    },
    'material': {
      'table': 'materials_arrivals',
      'fk': 'material_id',
      'qty': 'qty',
      'note': 'note'
    },
    'paper': {
      'table': 'papers_arrivals',
      'fk': 'paper_id',
      'qty': 'qty',
      'note': 'note'
    },
    'stationery': {
      'table': 'warehouse_stationery_arrivals',
      'fk': 'item_id',
      'qty': 'qty',
      'note': 'note'
    },
    'pens': {
      'table': 'warehouse_pens_arrivals',
      'fk': 'item_id',
      'qty': 'qty',
      'note': 'note'
    },
  };

  /// Загрузить логи по всем поддерживаемым типам.
  static Future<Map<String, WarehouseLogsBundle>> fetchAllBundles() async {
    final Map<String, WarehouseLogsBundle> result =
        <String, WarehouseLogsBundle>{};
    for (final String type in supportedTypes) {
      final bundle = await fetchBundle(type);
      result[bundle.typeKey] = bundle;
    }
    return result;
  }

  /// Загрузить логи для одного типа склада.
  static Future<WarehouseLogsBundle> fetchBundle(String rawType) async {
    await AppAuth.ensureSignedIn();
    final String typeKey = normalizeType(rawType);
    final List<WarehouseLogEntry> arrivals = await _fetchArrivals(typeKey);
    final List<WarehouseLogEntry> writeoffs = await _fetchWriteoffs(typeKey);
    final List<WarehouseLogEntry> inventories =
        await _fetchInventories(typeKey);

    return WarehouseLogsBundle(
      typeKey: typeKey,
      arrivals: arrivals,
      writeoffs: writeoffs,
      inventories: inventories,
    );
  }

  /// Нормализовать название типа (краски/материалы/...).
  static String normalizeType(String raw) {
    final String t = raw.trim().toLowerCase();
    if (t.startsWith('краск')) return 'paint';
    if (t.startsWith('матер')) return 'material';
    if (t.startsWith('бума')) return 'paper';
    if (t.startsWith('канц')) return 'stationery';
    if (t.startsWith('руч') || t.startsWith('pens')) return 'pens';
    if (supportedTypes.contains(t)) return t;
    return t;
  }

  static String typeLabel(String key) => typeLabels[key] ?? key;

  static Future<List<Map<String, dynamic>>> _selectAnyTable({
    required List<String> tables,
    required String selectFields,
    String? orderBy,
    bool ascending = true,
  }) async {
    for (final String table in tables) {
      final List<String?> attemptedOrders = <String?>[
        orderBy,
        if (orderBy != null) ...{
          'created_at',
          'createdAt',
          'createdat',
          'date',
          'timestamp',
        },
        null
      ];
      final Set<String?> seen = <String?>{};
      for (final String? order
          in attemptedOrders.where((String? c) => seen.add(c))) {
        try {
          final PostgrestFilterBuilder<dynamic> query =
              _client.from(table).select(selectFields);
          final dynamic data = order == null
              ? await query
              : await query.order(order, ascending: ascending);
          return (data as List).cast<Map<String, dynamic>>();
        } on PostgrestException catch (error) {
          final String code = (error.code?.toString() ?? '').toLowerCase();
          final String message =
              (error.message?.toString() ?? '').toLowerCase();
          final String details =
              (error.details?.toString() ?? '').toLowerCase();
          final String? orderLower = order?.toLowerCase();
          final bool columnMissing = orderLower != null &&
              (code == '42703' ||
                  message.contains(orderLower) && message.contains('column') ||
                  details.contains(orderLower) && details.contains('column'));
          if (columnMissing) {
            continue;
          }
          if (_isMissingRelationError(error, table)) {
            break;
          }
          debugPrint('WarehouseLogsRepository: $error for table $table');
        } catch (error, stack) {
          debugPrint('WarehouseLogsRepository: $error for table $table');
          debugPrintStack(stackTrace: stack);
        }
        break;
      }
    }
    return <Map<String, dynamic>>[];
  }

  static Future<List<Map<String, dynamic>>> _selectByIdsAny({
    required List<String> tables,
    required String fk,
    required List<dynamic> ids,
    String orderBy = 'description',
    bool ascending = true,
    String selectFields = '*',
    String? fallbackSelectFields,
  }) async {
    final List<String> normalizedIds = ids
        .map((dynamic id) => id?.toString().trim())
        .whereType<String>()
        .where((String id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (normalizedIds.isEmpty) {
      return <Map<String, dynamic>>[];
    }

    for (final String table in tables) {
      final List<String?> attemptedOrders = <String?>[
        orderBy,
        'name',
        'title',
        'description',
        'product_name',
        'id',
        null,
      ];
      final List<String> selectCandidates = <String>[
        selectFields,
        if (fallbackSelectFields != null &&
            fallbackSelectFields.isNotEmpty &&
            fallbackSelectFields != selectFields)
          fallbackSelectFields,
      ];
      final Set<String?> seen = <String?>{};
      for (final String select in selectCandidates) {
        seen.clear();
        for (final String? order
            in attemptedOrders.where((String? value) => seen.add(value))) {
          try {
            final PostgrestFilterBuilder<dynamic> baseQuery =
                _client.from(table).select(select);
            final PostgrestFilterBuilder<dynamic> filteredQuery =
                baseQuery.inFilter(fk, normalizedIds);
            final dynamic data = order == null
                ? await filteredQuery
                : await filteredQuery.order(order, ascending: ascending);
            return (data as List).cast<Map<String, dynamic>>();
          } on PostgrestException catch (error) {
            final String code = (error.code?.toString() ?? '').toLowerCase();
            final String message =
                (error.message?.toString() ?? '').toLowerCase();
            final String details =
                (error.details?.toString() ?? '').toLowerCase();
            final String? orderLower = order?.toLowerCase();
            final bool orderColumnMissing = orderLower != null &&
                (code == '42703' ||
                    message.contains(orderLower) && message.contains('column') ||
                    details.contains(orderLower) && details.contains('column'));

            final bool selectColumnMissing = code == '42703' ||
                message.contains('column') ||
                details.contains('column');

            if (orderColumnMissing) {
              continue;
            }
            if (selectColumnMissing) {
              break;
            }
            if (_isMissingRelationError(error, table) ||
                _isRecoverableSchemaProbeError(error)) {
              break;
            }
            debugPrint('WarehouseLogsRepository: $error for table $table');
          } catch (error, stack) {
            debugPrint('WarehouseLogsRepository: $error for table $table');
            debugPrintStack(stackTrace: stack);
          }
          break;
        }
      }
    }
    return <Map<String, dynamic>>[];
  }

  static bool _isRecoverableSchemaProbeError(PostgrestException error) {
    final String code = (error.code?.toString() ?? '').toLowerCase();
    final String message = (error.message?.toString() ?? '').toLowerCase();
    final String details = (error.details?.toString() ?? '').toLowerCase();

    return code == '400' &&
        (message == 'bad request' || message.contains('bad request')) &&
        (details.isEmpty || details == 'bad request');
  }

  static bool _isMissingRelationError(
      PostgrestException error, String relationName) {
    final String code = (error.code?.toString() ?? '').toLowerCase();
    if (code == '42p01' ||
        code == 'pgrst201' ||
        code == 'pgrst202' ||
        code == 'pgrst301' ||
        code == 'pgrst302') {
      return true;
    }

    final String message = (error.message?.toString() ?? '').toLowerCase();
    final String details = (error.details?.toString() ?? '').toLowerCase();
    final String hint = (error.hint?.toString() ?? '').toLowerCase();
    final String relationLower = relationName.toLowerCase();

    bool matches(String source) {
      if (source.isEmpty) return false;
      return source.contains(relationLower) &&
          (source.contains('does not exist') ||
              source.contains('could not find') ||
              source.contains('missing') ||
              source.contains('not found'));
    }

    return matches(message) || matches(details) || matches(hint);
  }

  static num? _pickNumDynamic(Map<String, dynamic> e, List<String?> keys) {
    for (final String? key in keys) {
      if (key == null) continue;
      final dynamic value = e[key];
      if (value is num) return value;
      if (value is String) {
        final num? parsed = num.tryParse(value.replaceAll(',', '.'));
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  static String? _pickStr(Map<String, dynamic> e, List<String?> keys) {
    for (final String? key in keys) {
      if (key == null) continue;
      final dynamic value = e[key];
      if (value == null) continue;
      return value.toString();
    }
    return null;
  }

  static String? _pickId(Map<String, dynamic> e, List<String?> keys) {
    for (final String? key in keys) {
      if (key == null) continue;
      final dynamic value = e[key];
      if (value == null) continue;
      return value.toString();
    }
    return null;
  }

  static final RegExp _uuidLikePattern = RegExp(
    r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
  );

  static bool _isUuidLike(String value) => _uuidLikePattern.hasMatch(value.trim());

  static String _firstMeaningful(Iterable<dynamic> values) {
    for (final dynamic value in values) {
      final String text = (value ?? '').toString().trim();
      if (text.isEmpty) continue;
      final String lower = text.toLowerCase();
      if (lower == 'null' || lower == 'undefined' || lower == 'nan') continue;
      if (text == '-' || text == '—') continue;
      if (_isUuidLike(text)) continue;
      return text;
    }
    return '';
  }

  static String _shortId(String id) {
    final String trimmed = id.trim();
    if (trimmed.length <= 8) return trimmed;
    return trimmed.substring(0, 8);
  }

  static String? _extractOrderIdFromNote(String? note) {
    final String source = (note ?? '').trim();
    if (source.isEmpty) return null;
    return _uuidLikePattern.firstMatch(source)?.group(0);
  }

  static Set<String> _extractOrderIdsFromWriteoffRows(
    List<Map<String, dynamic>> rows,
    String typeKey,
  ) {
    final Set<String> ids = <String>{};
    for (final Map<String, dynamic> row in rows) {
      final String orderId = (_pickStr(row, const <String?>[
                'order_id',
                'orderId',
                'source_order_id',
                'sourceOrderId',
              ]) ??
              '')
          .trim();
      if (orderId.isNotEmpty) ids.add(orderId);
      final String? note = _pickStr(row, <String?>[
        _woMap[typeKey]?['note'],
        'note',
        'reason',
        'comment',
      ]);
      final String? noteOrderId = _extractOrderIdFromNote(note);
      if (noteOrderId != null && noteOrderId.trim().isNotEmpty) {
        ids.add(noteOrderId.trim());
      }
    }
    return ids;
  }

  static Set<String> _extractEmployeeIdsFromWriteoffRows(
    List<Map<String, dynamic>> rows,
  ) {
    final Set<String> ids = <String>{};
    for (final Map<String, dynamic> row in rows) {
      for (final String? key in const <String?>[
        'employee_id',
        'employeeId',
        'worker_id',
        'user_id',
        'userId',
        'by_id',
        'byId',
      ]) {
        final String value = (_pickStr(row, <String?>[key]) ?? '').trim();
        if (value.isNotEmpty) ids.add(value);
      }
      final String displayed = (_pickStr(row, const <String?>[
                'by_name',
                'byName',
                'by',
                'user_name',
                'employee_name',
                'employee',
                'operator',
                'who',
              ]) ??
              '')
          .trim();
      if (displayed.isNotEmpty && _isUuidLike(displayed)) ids.add(displayed);
    }
    return ids;
  }

  static Future<Map<String, String>> _loadOrderLabelsByIds(
    Set<String> orderIds,
  ) async {
    if (orderIds.isEmpty) return const <String, String>{};
    final List<Map<String, dynamic>> rows = await _selectByIdsAny(
      tables: const <String>['orders'],
      fk: 'id',
      ids: orderIds.toList(growable: false),
      selectFields:
          'id, assignment_id, title, name, order_name, product_name, customer, new_form_no, form_code, data, product',
      fallbackSelectFields: '*',
    );
    final Map<String, String> labels = <String, String>{};
    for (final Map<String, dynamic> row in rows) {
      final String orderId = (row['id'] ?? '').toString().trim();
      if (orderId.isEmpty) continue;
      final dynamic dataRaw = row['data'];
      final Map<String, dynamic> data = dataRaw is Map
          ? Map<String, dynamic>.from(dataRaw as Map)
          : <String, dynamic>{};
      final dynamic productRaw = row['product'];
      final Map<String, dynamic> product = productRaw is Map
          ? Map<String, dynamic>.from(productRaw as Map)
          : <String, dynamic>{};
      final dynamic dataProductRaw = data['product'];
      final Map<String, dynamic> dataProduct = dataProductRaw is Map
          ? Map<String, dynamic>.from(dataProductRaw as Map)
          : <String, dynamic>{};

      final String formNo = _firstMeaningful(<dynamic>[
        row['new_form_no'],
        row['form_code'],
        data['new_form_no'],
        data['form_code'],
      ]);
      final String title = _firstMeaningful(<dynamic>[
        row['assignment_id'],
        row['title'],
        row['order_name'],
        row['product_name'],
        row['customer'],
        data['assignment_id'],
        data['title'],
        data['order_name'],
        data['product_name'],
        data['customer'],
        product['name'],
        product['title'],
        dataProduct['name'],
        dataProduct['title'],
        row['name'],
        data['name'],
      ]);
      if (formNo.isNotEmpty && title.isNotEmpty) {
        labels[orderId] = '№$formNo / $title';
      } else if (formNo.isNotEmpty) {
        labels[orderId] = '№$formNo';
      } else if (title.isNotEmpty) {
        labels[orderId] = title;
      }
    }
    return labels;
  }

  static Future<Map<String, String>> _loadEmployeeLabelsByIds(
    Set<String> employeeIds,
  ) async {
    if (employeeIds.isEmpty) return const <String, String>{};
    final List<Map<String, dynamic>> rows = await _selectByIdsAny(
      tables: const <String>['employees_view', 'employees'],
      fk: 'id',
      ids: employeeIds.toList(growable: false),
      selectFields:
          'id, last_name, first_name, patronymic, full_name, display_name, name, login',
      fallbackSelectFields: '*',
    );
    final Map<String, String> labels = <String, String>{};
    for (final Map<String, dynamic> row in rows) {
      final String employeeId = (row['id'] ?? '').toString().trim();
      if (employeeId.isEmpty) continue;
      final String fullName = _firstMeaningful(<dynamic>[
        row['full_name'],
        row['display_name'],
        row['name'],
      ]);
      final String composed = <String>[
        (row['last_name'] ?? row['lastName'] ?? '').toString().trim(),
        (row['first_name'] ?? row['firstName'] ?? '').toString().trim(),
        (row['patronymic'] ?? '').toString().trim(),
      ].where((String part) => part.isNotEmpty).join(' ');
      final String login = _firstMeaningful(<dynamic>[row['login']]);
      final String label = _firstMeaningful(<dynamic>[fullName, composed, login]);
      if (label.isNotEmpty) labels[employeeId] = label;
    }
    return labels;
  }

  static String _humanizeWriteoffNote(
    String? rawNote,
    Map<String, String> orderLabels,
  ) {
    final String note = (rawNote ?? '').trim();
    if (note.isEmpty) return '';
    final String? orderId = _extractOrderIdFromNote(note);
    if (orderId == null || orderId.isEmpty) return note;
    final String? label = orderLabels[orderId];
    if (label == null || label.trim().isEmpty) return note;
    return note.replaceFirst(orderId, label.trim());
  }

  static String? _resolveWriteoffEmployeeName(
    Map<String, dynamic> row,
    Map<String, String> employeeLabels,
  ) {
    final String explicitId = (_pickStr(row, const <String?>[
              'employee_id',
              'employeeId',
              'worker_id',
              'user_id',
              'userId',
              'by_id',
              'byId',
            ]) ??
            '')
        .trim();
    if (explicitId.isNotEmpty && employeeLabels[explicitId]?.isNotEmpty == true) {
      return employeeLabels[explicitId];
    }
    final String raw = (_pickStr(row, const <String?>[
              'by_name',
              'byName',
              'by',
              'user_name',
              'employee_name',
              'employee',
              'operator',
              'who',
            ]) ??
            '')
        .trim();
    if (raw.isEmpty) return null;
    if (_isUuidLike(raw)) return employeeLabels[raw] ?? _shortId(raw);
    return raw;
  }

  static String _resolveDescription({
    Map<String, dynamic>? baseRow,
    required Map<String, dynamic> raw,
    required String typeKey,
  }) {
    final List<String> parts = <String>[];
    bool isPlaceholder(String text) {
      final normalized = text.trim();
      return normalized.isEmpty || normalized == '-' || normalized == '—';
    }

    void add(dynamic value) {
      if (value == null) return;
      final String text = value.toString().trim();
      if (text.isEmpty || isPlaceholder(text)) return;
      final bool exists = parts.any(
          (String existing) => existing.toLowerCase() == text.toLowerCase());
      if (!exists) parts.add(text);
    }

    final Map<String, dynamic> base = baseRow ?? const <String, dynamic>{};
    add(base['description']);
    add(base['name']);
    add(base['title']);
    add(base['product_name']);
    add(raw['description']);
    add(raw['name']);
    add(raw['title']);
    add(raw['item_name']);
    add(raw['product_name']);
    if (typeKey == 'pens') {
      add(base['color']);
      add(raw['color']);
    }

    if (parts.isEmpty) return '—';
    return parts.join(' • ');
  }

  static List<String> _baseTables(String typeKey) {
    switch (typeKey) {
      case 'paint':
        return const <String>['paints', 'paint'];
      case 'material':
        return const <String>['materials', 'material'];
      case 'paper':
        return const <String>['papers', 'paper'];
      case 'stationery':
        return const <String>[
          'warehouse_stationery',
          'stationery',
          'warehouse_stationeries',
        ];
      case 'pens':
        return const <String>[
          'warehouse_pens',
          'pens',
        ];
      default:
        return const <String>['papers'];
    }
  }

  static List<String> _writeoffTables(String typeKey) {
    final String? hint = _woMap[typeKey]?['table'];
    final List<String> base = <String>[
      if (hint != null) hint,
      if (typeKey == 'stationery') 'warehouse_stationery_writeoffs',
      if (typeKey == 'pens') 'warehouse_pens_writeoffs',
      if (typeKey == 'paper') 'paper_writeoffs',
      if (typeKey == 'paint') 'paints_writeoffs',
      if (typeKey == 'material') 'materials_writeoffs',
    ];
    final Set<String> seen = <String>{};
    return base.where((String e) => seen.add(e)).toList();
  }

  static List<String> _inventoryTables(String typeKey) {
    final String? hint = _invMap[typeKey]?['table'];
    final List<String> base = <String>[
      if (hint != null) hint,
      if (typeKey == 'stationery') 'warehouse_stationery_inventories',
      if (typeKey == 'pens') 'warehouse_pens_inventories',
      if (typeKey == 'paper') 'papers_inventories',
      if (typeKey == 'paint') 'paints_inventories',
      if (typeKey == 'material') 'materials_inventories',
    ];
    final Set<String> seen = <String>{};
    return base.where((String e) => seen.add(e)).toList();
  }

  static List<String> _arrivalTables(String typeKey) {
    final String? hint = _arrMap[typeKey]?['table'];
    final List<String> base = <String>[
      if (hint != null) hint,
      if (typeKey == 'stationery') 'warehouse_stationery_arrivals',
      if (typeKey == 'pens') 'warehouse_pens_arrivals',
      if (typeKey == 'stationery') 'stationery_arrivals',
      if (typeKey == 'paper') 'papers_arrivals',
      if (typeKey == 'paint') 'paints_arrivals',
      if (typeKey == 'material') 'materials_arrivals',
    ];
    final Set<String> seen = <String>{};
    return base.where((String e) => seen.add(e)).toList();
  }

  static String _baseSelectFieldsForLogs(String typeKey) {
    if (typeKey == 'pens') {
      // У ручек нет колонки description, используем реальные поля, чтобы не
      // получать пустой placeholder в логах.
      return 'id, name, unit, color';
    }
    if (typeKey == 'paper') {
      return 'id, description, unit, format, grammage';
    }
    if (typeKey == 'pens') {
      return 'id, name, color, quantity';
    }
    return 'id, description, unit, name';
  }

  static WarehouseLogEntry _mapToEntry({
    required Map<String, dynamic> raw,
    required Map<String, dynamic>? baseRow,
    required String typeKey,
    required WarehouseLogAction action,
    required String? itemId,
    required num qty,
  }) {
    final String description = _resolveDescription(
      baseRow: baseRow,
      raw: raw,
      typeKey: typeKey,
    );
    final String unit = (_pickStr(
              baseRow ?? const <String, dynamic>{},
              <String?>['unit', 'units'],
            ) ??
            _pickStr(raw, <String?>['unit', 'units']) ??
            '')
        .toString();
    final String? format = baseRow?['format']?.toString();
    final String? grammage = baseRow?['grammage']?.toString();
    final String timestampIso =
        (raw['created_at'] ?? raw['date'] ?? raw['timestamp'] ?? '').toString();
    final String? note = _pickStr(raw, <String?>[
      _woMap[typeKey]?['note'],
      _arrMap[typeKey]?['note'],
      _invMap[typeKey]?['note'],
      'note',
      'reason',
      'comment',
    ]);
    final String? by = _pickStr(raw, <String?>[
      'by_name',
      'byName',
      'by',
      'user_name',
      'employee_name',
      'employee',
      'operator',
      'who',
    ]);

    return WarehouseLogEntry(
      id: (raw['id'] ?? '').toString(),
      itemId: itemId,
      typeKey: typeKey,
      action: action,
      description: description,
      quantity: qty.toDouble(),
      unit: unit,
      format: format,
      grammage: grammage,
      note: note,
      byName: by,
      timestampIso: timestampIso,
      sourceTable: raw['table_name']?.toString(),
    );
  }

  static Future<List<WarehouseLogEntry>> _fetchWriteoffs(String typeKey) async {
    final List<String> tables = _writeoffTables(typeKey);
    final List<Map<String, dynamic>> rawLogs = <Map<String, dynamic>>[];

    for (final String table in tables) {
      final List<Map<String, dynamic>> part = await _selectAnyTable(
        tables: <String>[table],
        selectFields: '*',
        orderBy: 'created_at',
        ascending: false,
      );
      if (part.isNotEmpty)
        rawLogs.addAll(part.map((Map<String, dynamic> row) {
          return <String, dynamic>{...row, 'table_name': table};
        }));
    }
    if (rawLogs.isEmpty) return <WarehouseLogEntry>[];

    final List<String?> fkCandidates = <String?>[
      _woMap[typeKey]?['fk'],
      'item_id',
      'stationery_id',
      'paper_id',
      'paint_id',
      'material_id',
      'tmc_id',
      'fk_id',
    ];

    final List<String> ids = rawLogs
        .map((Map<String, dynamic> e) => _pickId(e, fkCandidates))
        .whereType<String>()
        .toSet()
        .toList();

    final List<Map<String, dynamic>> baseRows = await _selectByIdsAny(
      tables: _baseTables(typeKey),
      fk: 'id',
      ids: ids,
      selectFields: _baseSelectFieldsForLogs(typeKey),
      fallbackSelectFields: '*',
    );
    final Map<String, Map<String, dynamic>> baseMap =
        <String, Map<String, dynamic>>{
      for (final Map<String, dynamic> row in baseRows) row['id'].toString(): row
    };

    final Map<String, String> orderLabels = await _loadOrderLabelsByIds(
      _extractOrderIdsFromWriteoffRows(rawLogs, typeKey),
    );
    final Map<String, String> employeeLabels = await _loadEmployeeLabelsByIds(
      _extractEmployeeIdsFromWriteoffRows(rawLogs),
    );

    return rawLogs.map((Map<String, dynamic> e) {
      final String? itemId = _pickId(e, fkCandidates);
      final Map<String, dynamic>? baseRow =
          itemId == null ? null : baseMap[itemId];
      final num qty = _pickNumDynamic(e, <String?>[
            _woMap[typeKey]?['qty'],
            'quantity',
            'qty',
            'amount',
            'count',
          ]) ??
          0;
      final Map<String, dynamic> displayRaw = Map<String, dynamic>.from(e);
      final String? rawNote = _pickStr(displayRaw, <String?>[
        _woMap[typeKey]?['note'],
        'note',
        'reason',
        'comment',
      ]);
      final String noteColumn = _woMap[typeKey]?['note'] ?? 'reason';
      final String explicitOrderId = (_pickStr(displayRaw, const <String?>[
                'order_id',
                'orderId',
                'source_order_id',
                'sourceOrderId',
              ]) ??
              '')
          .trim();
      final String humanizedNote = _humanizeWriteoffNote(rawNote, orderLabels);
      displayRaw[noteColumn] = humanizedNote.isNotEmpty
          ? humanizedNote
          : (orderLabels[explicitOrderId]?.isNotEmpty == true
              ? 'Заказ ${orderLabels[explicitOrderId]}'
              : humanizedNote);
      displayRaw['by_name'] = _resolveWriteoffEmployeeName(
        displayRaw,
        employeeLabels,
      );
      return _mapToEntry(
        raw: displayRaw,
        baseRow: baseRow,
        typeKey: typeKey,
        action: WarehouseLogAction.writeoff,
        itemId: itemId,
        qty: qty,
      );
    }).toList();
  }

  static Future<List<WarehouseLogEntry>> _fetchInventories(
      String typeKey) async {
    final List<String> tables = _inventoryTables(typeKey);
    final List<Map<String, dynamic>> rawLogs = <Map<String, dynamic>>[];

    for (final String table in tables) {
      final List<Map<String, dynamic>> part = await _selectAnyTable(
        tables: <String>[table],
        selectFields: '*',
        orderBy: 'created_at',
        ascending: false,
      );
      if (part.isNotEmpty)
        rawLogs.addAll(part.map((Map<String, dynamic> row) {
          return <String, dynamic>{...row, 'table_name': table};
        }));
    }
    if (rawLogs.isEmpty) return <WarehouseLogEntry>[];

    final List<String?> fkCandidates = <String?>[
      _invMap[typeKey]?['fk'],
      'item_id',
      'stationery_id',
      'paper_id',
      'paint_id',
      'material_id',
      'tmc_id',
      'fk_id',
    ];

    final List<String> ids = rawLogs
        .map((Map<String, dynamic> e) => _pickId(e, fkCandidates))
        .whereType<String>()
        .toSet()
        .toList();

    final List<Map<String, dynamic>> baseRows = await _selectByIdsAny(
      tables: _baseTables(typeKey),
      fk: 'id',
      ids: ids,
      selectFields: _baseSelectFieldsForLogs(typeKey),
      fallbackSelectFields: '*',
    );
    final Map<String, Map<String, dynamic>> baseMap =
        <String, Map<String, dynamic>>{
      for (final Map<String, dynamic> row in baseRows) row['id'].toString(): row
    };

    final Map<String, String> orderLabels = await _loadOrderLabelsByIds(
      _extractOrderIdsFromWriteoffRows(rawLogs, typeKey),
    );
    final Map<String, String> employeeLabels = await _loadEmployeeLabelsByIds(
      _extractEmployeeIdsFromWriteoffRows(rawLogs),
    );

    return rawLogs.map((Map<String, dynamic> e) {
      final String? itemId = _pickId(e, fkCandidates);
      final Map<String, dynamic>? baseRow =
          itemId == null ? null : baseMap[itemId];
      final num qty = _pickNumDynamic(e, <String?>[
            _invMap[typeKey]?['qty'],
            'counted_qty',
            'factual',
            'quantity',
            'qty',
          ]) ??
          0;
      return _mapToEntry(
        raw: e,
        baseRow: baseRow,
        typeKey: typeKey,
        action: WarehouseLogAction.inventory,
        itemId: itemId,
        qty: qty,
      );
    }).toList();
  }

  static Future<List<WarehouseLogEntry>> _fetchArrivals(String typeKey) async {
    final List<String> tables = _arrivalTables(typeKey);
    final List<Map<String, dynamic>> rawLogs = <Map<String, dynamic>>[];

    for (final String table in tables) {
      final List<Map<String, dynamic>> part = await _selectAnyTable(
        tables: <String>[table],
        selectFields: '*',
        orderBy: 'created_at',
        ascending: false,
      );
      if (part.isNotEmpty)
        rawLogs.addAll(part.map((Map<String, dynamic> row) {
          return <String, dynamic>{...row, 'table_name': table};
        }));
    }
    if (rawLogs.isEmpty) return <WarehouseLogEntry>[];

    final List<String?> fkCandidates = <String?>[
      _arrMap[typeKey]?['fk'],
      'item_id',
      'stationery_id',
      'paper_id',
      'paint_id',
      'material_id',
      'tmc_id',
      'fk_id',
      'base_id',
    ];

    final List<String> ids = rawLogs
        .map((Map<String, dynamic> e) => _pickId(e, fkCandidates))
        .whereType<String>()
        .toList();

    final List<Map<String, dynamic>> baseRows = await _selectByIdsAny(
      tables: _baseTables(typeKey),
      fk: 'id',
      ids: ids,
      selectFields: _baseSelectFieldsForLogs(typeKey),
      fallbackSelectFields: '*',
    );
    final Map<String, Map<String, dynamic>> baseMap =
        <String, Map<String, dynamic>>{
      for (final Map<String, dynamic> row in baseRows) row['id'].toString(): row
    };

    final Map<String, String> orderLabels = await _loadOrderLabelsByIds(
      _extractOrderIdsFromWriteoffRows(rawLogs, typeKey),
    );
    final Map<String, String> employeeLabels = await _loadEmployeeLabelsByIds(
      _extractEmployeeIdsFromWriteoffRows(rawLogs),
    );

    return rawLogs.map((Map<String, dynamic> e) {
      final String? itemId = _pickId(e, fkCandidates);
      final Map<String, dynamic>? baseRow =
          itemId == null ? null : baseMap[itemId];
      final num qty = _pickNumDynamic(e, <String?>[
            _arrMap[typeKey]?['qty'],
            'quantity',
            'qty',
            'amount',
            'added_qty',
          ]) ??
          0;
      return _mapToEntry(
        raw: e,
        baseRow: baseRow,
        typeKey: typeKey,
        action: WarehouseLogAction.arrival,
        itemId: itemId,
        qty: qty,
      );
    }).toList();
  }
}
