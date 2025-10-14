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

  static const Map<String, Map<String, String>> _woMap = <String, Map<String, String>>{
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
      'table': 'paper_writeoffs',
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

  static const Map<String, Map<String, String>> _invMap = <String, Map<String, String>>{
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
      'qty': 'counted_qty',
      'note': 'note'
    },
    'pens': {
      'table': 'warehouse_pens_inventories',
      'fk': 'item_id',
      'qty': 'counted_qty',
      'note': 'note'
    },
  };

  static const Map<String, Map<String, String>> _arrMap = <String, Map<String, String>>{
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
    final Map<String, WarehouseLogsBundle> result = <String, WarehouseLogsBundle>{};
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
    final List<WarehouseLogEntry> inventories = await _fetchInventories(typeKey);

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
      final List<String?> attemptedOrders = <String?>[orderBy, if (orderBy != null) ...{
        'created_at',
        'createdAt',
        'createdat',
        'date',
        'timestamp',
      }, null];
      final Set<String?> seen = <String?>{};
      for (final String? order in attemptedOrders.where((String? c) => seen.add(c))) {
        try {
          final PostgrestFilterBuilder<dynamic> query =
              _client.from(table).select(selectFields);
          final dynamic data = order == null
              ? await query
              : await query.order(order, ascending: ascending);
          return (data as List).cast<Map<String, dynamic>>();
        } on PostgrestException catch (error) {
          final String code = (error.code?.toString() ?? '').toLowerCase();
          final String message = (error.message?.toString() ?? '').toLowerCase();
          final String details = (error.details?.toString() ?? '').toLowerCase();
          final String? orderLower = order?.toLowerCase();
          final bool columnMissing = orderLower != null &&
              (code == '42703' ||
                  message.contains(orderLower) &&
                      message.contains('column') ||
                  details.contains(orderLower) &&
                      details.contains('column'));
          if (columnMissing) {
            continue;
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
  }) async {
    for (final String table in tables) {
      try {
        final PostgrestFilterBuilder<dynamic> baseQuery =
            _client.from(table).select(selectFields);
        final PostgrestTransformBuilder<dynamic> query = ids.isEmpty
            ? baseQuery.order(orderBy, ascending: ascending)
            : baseQuery
                .or(ids.map((dynamic e) => '$fk.eq.$e').join(','))
                .order(orderBy, ascending: ascending);
        final dynamic data = await query;
        return (data as List).cast<Map<String, dynamic>>();
      } catch (error, stack) {
        debugPrint('WarehouseLogsRepository: $error for table $table');
        debugPrintStack(stackTrace: stack);
      }
    }
    return <Map<String, dynamic>>[];
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
        return const <String>['warehouse_pens', 'pens'];
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
      if (typeKey == 'stationery') 'stationery_inventories',
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
    if (typeKey == 'paper') {
      return 'id, description, unit, format, grammage';
    }
    return 'id, description, unit';
  }

  static WarehouseLogEntry _mapToEntry({
    required Map<String, dynamic> raw,
    required Map<String, dynamic>? baseRow,
    required String typeKey,
    required WarehouseLogAction action,
    required String? itemId,
    required num qty,
  }) {
    final String description = (baseRow?['description'] ?? '').toString();
    final String unit = (baseRow?['unit'] ?? '').toString();
    final String? format = baseRow?['format']?.toString();
    final String? grammage = baseRow?['grammage']?.toString();
    final String timestampIso = (raw['created_at'] ?? raw['date'] ?? raw['timestamp'] ?? '').toString();
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
      if (part.isNotEmpty) rawLogs.addAll(part.map((Map<String, dynamic> row) {
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
    );
    final Map<String, Map<String, dynamic>> baseMap = <String, Map<String, dynamic>>{
      for (final Map<String, dynamic> row in baseRows) row['id'].toString(): row
    };

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
      return _mapToEntry(
        raw: e,
        baseRow: baseRow,
        typeKey: typeKey,
        action: WarehouseLogAction.writeoff,
        itemId: itemId,
        qty: qty,
      );
    }).toList();
  }

  static Future<List<WarehouseLogEntry>> _fetchInventories(String typeKey) async {
    final List<String> tables = _inventoryTables(typeKey);
    final List<Map<String, dynamic>> rawLogs = <Map<String, dynamic>>[];

    for (final String table in tables) {
      final List<Map<String, dynamic>> part = await _selectAnyTable(
        tables: <String>[table],
        selectFields: '*',
        orderBy: 'created_at',
        ascending: false,
      );
      if (part.isNotEmpty) rawLogs.addAll(part.map((Map<String, dynamic> row) {
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
    );
    final Map<String, Map<String, dynamic>> baseMap = <String, Map<String, dynamic>>{
      for (final Map<String, dynamic> row in baseRows) row['id'].toString(): row
    };

    return rawLogs.map((Map<String, dynamic> e) {
      final String? itemId = _pickId(e, fkCandidates);
      final Map<String, dynamic>? baseRow =
          itemId == null ? null : baseMap[itemId];
      final num qty = _pickNumDynamic(e, <String?>[
            _invMap[typeKey]?['qty'],
            'counted_qty',
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
      if (part.isNotEmpty) rawLogs.addAll(part.map((Map<String, dynamic> row) {
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
    );
    final Map<String, Map<String, dynamic>> baseMap = <String, Map<String, dynamic>>{
      for (final Map<String, dynamic> row in baseRows) row['id'].toString(): row
    };

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
