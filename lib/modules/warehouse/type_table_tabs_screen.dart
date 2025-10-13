// lib/modules/warehouse/type_table_tabs_screen.dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'warehouse_provider.dart';
import '../../services/doc_db.dart';
import 'tmc_model.dart';
import '../../utils/auth_helper.dart';
import 'add_entry_dialog.dart';
import '../../utils/kostanay_time.dart';

/// Экран с вкладками для просмотра записей склада заданного типа.
///
/// Вкладки:
/// 1) Список – текущие остатки;
/// 2) Списания – лог списаний;
/// 3) Инвентаризация – лог инвентаризаций.
class TypeTableTabsScreen extends StatefulWidget {
  final String type;
  final String title;
  final bool enablePhoto;

  const TypeTableTabsScreen({
    super.key,
    required this.type,
    required this.title,
    this.enablePhoto = false,
  });

  @override
  State<TypeTableTabsScreen> createState() => _TypeTableTabsScreenState();
}

class _TypeTableTabsScreenState extends State<TypeTableTabsScreen>
    with TickerProviderStateMixin {
  // === Paper: multi-filter ===
  final Set<String> _fltPaperNames = {};
  final Set<String> _fltPaperFormats = {};
  final Set<String> _fltPaperGrammages = {};
  List<String> _allPaperNames = [];
  List<String> _allPaperFormats = [];
  List<String> _allPaperGrammages = [];

  void _rebuildPaperFilterDicts() {
    final names = <String>{};
    final formats = <String>{};
    final grammages = <String>{};
    for (final p in _items) {
      if (p.description.trim().isNotEmpty) names.add(p.description.trim());
      final f = (p.format ?? '').trim();
      final g = (p.grammage ?? '').trim();
      if (f.isNotEmpty) formats.add(f);
      if (g.isNotEmpty) grammages.add(g);
    }
    _allPaperNames = names.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    _allPaperFormats = formats.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    _allPaperGrammages = grammages.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  List<TmcModel> _applyPaperMultiFilters(List<TmcModel> src) {
    return src.where((e) {
      final okN =
          _fltPaperNames.isEmpty || _fltPaperNames.contains(e.description);
      final okF = _fltPaperFormats.isEmpty ||
          ((e.format ?? '').isNotEmpty && _fltPaperFormats.contains(e.format));
      final okG = _fltPaperGrammages.isEmpty ||
          ((e.grammage ?? '').isNotEmpty &&
              _fltPaperGrammages.contains(e.grammage));
      return okN && okF && okG;
    }).toList();
  }

  void _openPaperFilters() {
    _rebuildPaperFilterDicts();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 16,
          ),
          child: StatefulBuilder(
            builder: (ctx, setSt) {
              Widget chips(List<String> all, Set<String> sel, String title) =>
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        for (final v in all)
                          FilterChip(
                            label: Text(v),
                            selected: sel.contains(v),
                            onSelected: (on) => setSt(() {
                              if (on) {
                                sel.add(v);
                              } else {
                                sel.remove(v);
                              }
                            }),
                          ),
                      ]),
                    ],
                  );
              return SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    chips(_allPaperNames, _fltPaperNames, 'Названия'),
                    const SizedBox(height: 12),
                    chips(_allPaperFormats, _fltPaperFormats, 'Форматы'),
                    const SizedBox(height: 12),
                    chips(_allPaperGrammages, _fltPaperGrammages, 'Грамажи'),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton(
                          onPressed: () {
                            setSt(() {
                              _fltPaperNames.clear();
                              _fltPaperFormats.clear();
                              _fltPaperGrammages.clear();
                            });
                          },
                          child: const Text('Сбросить'),
                        ),
                        ElevatedButton(
                          onPressed: () {
                            setState(() {});
                            Navigator.pop(ctx);
                          },
                          child: const Text('Применить'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  late final TabController _tabs;
  RealtimeChannel? _rt;
  // Основные позиции
  List<TmcModel> _items = [];

  // Логи
  List<_LogRow> _writeoffs = [];
  List<_LogRow> _inventories = [];
  List<_LogRow> _arrivals = [];

  String _sortField = 'date';
  bool _sortDesc = true;
  String _query = '';

  final TextEditingController _searchController = TextEditingController();

  // ====== Мапы соответствий типа -> таблицы Supabase и названия FK/полей ======
  static const Map<String, Map<String, String>> _woMap = {
    'paint': {
      'table': 'paints_writeoffs',
      'fk': 'paint_id',
      'qty': 'qty',
      'note': 'reason'
    },
    'material': {
      'table': 'materials_writeoffs',
      'fk': 'material_id',
      'qty': 'qty',
      'note': 'reason'
    },
    'paper': {
      'table': 'papers_writeoffs',
      'fk': 'paper_id',
      'qty': 'qty',
      'note': 'reason'
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

  static const Map<String, Map<String, String>> _invMap = {
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
      'table': 'paper_inventories',
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

  // Карта таблиц для «Приходов» (arrivals)
  static const Map<String, Map<String, String>> _arrMap = {
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

  String _normalizeType(String raw) {
    final t = raw.trim().toLowerCase();
    if (t.startsWith('краск')) return 'paint';
    if (t.startsWith('матер')) return 'material';
    if (t.startsWith('бума')) return 'paper';
    if (t.startsWith('канц')) return 'stationery';
    if (t.startsWith('руч') || t.startsWith('pens')) return 'pens';
    if (_woMap.containsKey(t) || _invMap.containsKey(t)) return t;
    return t;
  }

  /// Возможные названия базовой таблицы (для enrich логов)
  List<String> _baseTables(String typeKey) {
    switch (typeKey) {
      case 'paint':
        return const ['paints', 'paint'];
      case 'material':
        return const ['materials', 'material'];
      case 'paper':
        return const ['papers', 'paper'];
      case 'stationery':
        return const [
          'warehouse_stationery',
          'stationery',
          'warehouse_stationeries'
        ];
      case 'pens':
        return const ['warehouse_pens', 'pens'];
      default:
        return const ['papers'];
    }
  }

  /// Кандидаты таблиц для логов списаний
  List<String> _writeoffTables(String typeKey) {
    final hint = _woMap[typeKey]?['table'];
    final base = <String>[
      if (hint != null) hint,
      if (typeKey == 'stationery') 'warehouse_stationery_writeoffs',
      if (typeKey == 'pens') 'warehouse_pens_writeoffs',
      if (typeKey == 'paper') 'paper_writeoffs',
      if (typeKey == 'paint') 'paints_writeoffs',
      if (typeKey == 'material') 'materials_writeoffs',
    ];
    final seen = <String>{};
    return base.where((e) => seen.add(e)).toList();
  }

  /// Кандидаты таблиц для логов инвентаризаций
  List<String> _inventoryTables(String typeKey) {
    final hint = _invMap[typeKey]?['table'];
    final base = <String>[
      if (hint != null) hint,
      if (typeKey == 'stationery') 'warehouse_stationery_inventories',
      if (typeKey == 'pens') 'warehouse_pens_inventories',
      if (typeKey == 'paper') 'paper_inventories',
      if (typeKey == 'paint') 'paints_inventories',
      if (typeKey == 'material') 'materials_inventories',
    ];
    final seen = <String>{};
    return base.where((e) => seen.add(e)).toList();
  }

  /// Кандидаты таблиц для логов приходов
  List<String> _arrivalTables(String typeKey) {
    final hint = _arrMap[typeKey]?['table'];
    final base = <String>[
      if (hint != null) hint,
      if (typeKey == 'stationery') 'warehouse_stationery_arrivals',
      if (typeKey == 'pens') 'warehouse_pens_arrivals',
      if (typeKey == 'stationery') 'stationery_arrivals',
      if (typeKey == 'paper') 'papers_arrivals',
      if (typeKey == 'paint') 'paints_arrivals',
      if (typeKey == 'material') 'materials_arrivals',
    ];
    final seen = <String>{};
    return base.where((e) => seen.add(e)).toList();
  }

  /// Поля базовой таблицы, которые нужно вытаскивать для обогащения логов.
  String _baseSelectFieldsForLogs(String typeKey) {
    if (typeKey == 'paper') {
      return 'id, description, unit, format, grammage';
    }
    return 'id, description, unit';
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final t = widget.type.toLowerCase();
      context.read<WarehouseProvider>().setStationeryKey(
            (t.startsWith('руч') || t.startsWith('pens'))
                ? 'ручки'
                : 'канцелярия',
          );
    });
    _tabs = TabController(length: 4, vsync: this);
    _tabs.addListener(() {
      if (mounted) setState(() {});
    });
    _loadAll();
    _setupRealtime();
  }

  Future<void> _loadAll() async {
    final provider = Provider.of<WarehouseProvider>(context, listen: false);
    try {
      await provider.fetchTmc();
    } catch (_) {}

    final items = provider.getTmcByType(widget.type);
    final typeKey = _normalizeType(widget.type);

    final writeoffs = await _fetchWriteoffs(typeKey);
    final inventories = await _fetchInventories(typeKey);
    final arrivals = await _fetchArrivals(typeKey);

    if (!mounted) return;
    setState(() {
      _items = items;
      _writeoffs = writeoffs;
      _inventories = inventories;
      _arrivals = arrivals;
    });
    _notifyThresholds();
    _resort();
  }

  void _setupRealtime() {
    try {
      final s = Supabase.instance.client;
      _rt?.unsubscribe();

      final typeKey = _normalizeType(widget.type);
      final bases = _baseTables(typeKey);
      final woTables = _writeoffTables(typeKey);
      final invTables = _inventoryTables(typeKey);

      final ch = s.channel('wh_${DateTime.now().millisecondsSinceEpoch}');
      for (final t in [...bases, ...woTables, ...invTables]) {
        ch.onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: t,
          callback: (payload) => _loadAll(),
        );
        ch.onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: t,
          callback: (payload) => _loadAll(),
        );
        ch.onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: t,
          callback: (payload) => _loadAll(),
        );
      }
      ch.subscribe();
      _rt = ch;
    } catch (_) {}
  }

  @override
  void didUpdateWidget(covariant TypeTableTabsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.type != widget.type) {
      _setupRealtime();
      _loadAll();
    }
  }

  @override
  void dispose() {
    try {
      _rt?.unsubscribe();
    } catch (_) {}
    _tabs.dispose();
    super.dispose();
  }

  // ------- ВСПОМОГАТЕЛЬНЫЕ ПАРСЕРЫ / СЕЛЕКТЫ -------
  num? _pickNumDynamic(Map<String, dynamic> e, List<String?> keys) {
    for (final k in keys) {
      if (k == null) continue;
      final v = e[k];
      if (v is num) return v;
      if (v is String) {
        final d = double.tryParse(v.replaceAll(',', '.'));
        if (d != null) return d;
      }
    }
    return null;
  }

  String? _pickStr(Map<String, dynamic> e, List<String?> keys) {
    for (final k in keys) {
      if (k == null) continue;
      final v = e[k];
      if (v == null) continue;
      return v.toString();
    }
    return null;
  }

  String? _pickId(Map<String, dynamic> e, List<String?> keys) {
    for (final k in keys) {
      if (k == null) continue;
      final v = e[k];
      if (v == null) continue;
      return v.toString();
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> _selectAnyTable({
    required List<String> tables,
    required String selectFields,
    String? orderBy,
    bool ascending = true,
  }) async {
    final s = Supabase.instance.client;
    for (final t in tables) {
      try {
        final q = s.from(t).select(selectFields);
        final data = orderBy == null
            ? await q
            : await q.order(orderBy, ascending: ascending);
        return (data as List).cast<Map<String, dynamic>>();
      } catch (_) {
        // попробуем следующий
      }
    }
    return [];
  }

  /// Универсальный выбор по списку id (пытается по списку таблиц)
  Future<List<Map<String, dynamic>>> _selectByIdsAny({
    required List<String> tables,
    required String fk,
    required List ids,
    String orderBy = 'description',
    bool ascending = true,
    String selectFields = '*',
  }) async {
    final s = Supabase.instance.client;
    for (final table in tables) {
      try {
        final b = s.from(table).select(selectFields);
        final data = ids.isEmpty
            ? await b.order(orderBy, ascending: ascending)
            : await b
                .or(ids.map((e) => '$fk.eq.$e').join(','))
                .order(orderBy, ascending: ascending);
        return (data as List).cast<Map<String, dynamic>>();
      } catch (_) {
        // следующая таблица
      }
    }
    return [];
  }

  /// Получить все списания по типу и обогатить описанием/единицей/форматом/граммажом.
  Future<List<_LogRow>> _fetchWriteoffs(String typeKey) async {
    final woTables = _writeoffTables(typeKey);
    final logs = <Map<String, dynamic>>[];

    for (final table in woTables) {
      final part = await _selectAnyTable(
        tables: [table],
        selectFields: '*',
        orderBy: 'created_at',
        ascending: false,
      );
      if (part.isNotEmpty) logs.addAll(part);
    }
    if (logs.isEmpty) return [];

    final fkCandidates = <String?>[
      _woMap[typeKey]?['fk'],
      'item_id',
      'stationery_id',
      'paper_id',
      'paint_id',
      'material_id',
      'tmc_id',
      'fk_id'
    ];

    final ids = logs
        .map((e) => _pickId(e, fkCandidates))
        .where((v) => v != null)
        .toSet()
        .toList();

    final baseRows = await _selectByIdsAny(
      tables: _baseTables(typeKey),
      fk: 'id',
      ids: ids,
      selectFields: _baseSelectFieldsForLogs(typeKey),
    );
    final baseMap = {for (final r in baseRows) r['id']: r};

    return logs.map((e) {
      final id = (e['id'] ?? '').toString();
      final baseId = _pickId(e, fkCandidates);
      final baseRow = baseMap[baseId] ?? {};
      final descr = (baseRow['description'] ?? '').toString();
      final unit = (baseRow['unit'] ?? '').toString();
      final fmt = baseRow['format']?.toString();
      final gram = baseRow['grammage']?.toString();
      final qty = _pickNumDynamic(e, [
            _woMap[typeKey]?['qty'],
            'quantity',
            'qty',
            'amount',
            'count'
          ]) ??
          0;
      final dateIso =
          (e['created_at'] ?? e['date'] ?? e['timestamp'] ?? '').toString();
      final note =
          _pickStr(e, [_woMap[typeKey]?['note'], 'note', 'reason', 'comment']);
      final by = _pickStr(e, [
        'by_name',
        'byName',
        'by',
        'user_name',
        'employee_name',
        'operator',
        'who'
      ]);
      return _LogRow(
        id: id,
        description: descr,
        quantity: qty.toDouble(),
        unit: unit,
        dateIso: dateIso,
        note: note,
        format: fmt,
        grammage: gram,
        byName: by,
      );
    }).toList();
  }

  /// Получить инвентаризации по типу и обогатить описанием/единицей/форматом/граммажом.
  Future<List<_LogRow>> _fetchInventories(String typeKey) async {
    final invTables = _inventoryTables(typeKey);
    final logs = <Map<String, dynamic>>[];

    for (final table in invTables) {
      final part = await _selectAnyTable(
        tables: [table],
        selectFields: '*',
        orderBy: 'created_at',
        ascending: false,
      );
      if (part.isNotEmpty) logs.addAll(part);
    }
    if (logs.isEmpty) return [];

    final fkCandidates = <String?>[
      _invMap[typeKey]?['fk'],
      'item_id',
      'stationery_id',
      'paper_id',
      'paint_id',
      'material_id',
      'tmc_id',
      'fk_id'
    ];

    final ids = logs
        .map((e) => _pickId(e, fkCandidates))
        .where((v) => v != null)
        .toSet()
        .toList();

    final baseRows = await _selectByIdsAny(
      tables: _baseTables(typeKey),
      fk: 'id',
      ids: ids,
      selectFields: _baseSelectFieldsForLogs(typeKey),
    );
    final baseMap = {for (final r in baseRows) r['id']: r};

    return logs.map((e) {
      final id = (e['id'] ?? '').toString();
      final baseId = _pickId(e, fkCandidates);
      final baseRow = baseMap[baseId] ?? {};
      final descr = (baseRow['description'] ?? '').toString();
      final unit = (baseRow['unit'] ?? '').toString();
      final fmt = baseRow['format']?.toString();
      final gram = baseRow['grammage']?.toString();
      final qty = _pickNumDynamic(e,
              [_invMap[typeKey]?['qty'], 'counted_qty', 'quantity', 'qty']) ??
          0;
      final dateIso =
          (e['created_at'] ?? e['date'] ?? e['timestamp'] ?? '').toString();
      final note =
          _pickStr(e, [_invMap[typeKey]?['note'], 'note', 'reason', 'comment']);
      final by = _pickStr(e, [
        'by_name',
        'byName',
        'by',
        'user_name',
        'employee_name',
        'operator',
        'who'
      ]);
      return _LogRow(
        id: id,
        description: descr,
        quantity: qty.toDouble(),
        unit: unit,
        dateIso: dateIso,
        note: note,
        format: fmt,
        grammage: gram,
        byName: by,
      );
    }).toList();
  }

  /// Получить приходы по типу и обогатить описанием/единицей/форматом/граммажом.
  Future<List<_LogRow>> _fetchArrivals(String typeKey) async {
    final arrTables = _arrivalTables(typeKey);
    final logs = <Map<String, dynamic>>[];

    for (final table in arrTables) {
      final part = await _selectAnyTable(
        tables: [table],
        selectFields: '*',
        orderBy: 'created_at',
        ascending: false,
      );
      if (part.isNotEmpty) logs.addAll(part);
    }
    if (logs.isEmpty) return [];

    final fkCandidates = <String?>[
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
    final ids =
        logs.map((e) => _pickId(e, fkCandidates)).whereType<String>().toList();

    final baseRows = await _selectByIdsAny(
      tables: _baseTables(typeKey),
      fk: 'id',
      ids: ids,
      selectFields: _baseSelectFieldsForLogs(typeKey),
    );
    final baseMap = {for (final r in baseRows) r['id']: r};

    return logs.map((e) {
      final id = (e['id'] ?? '').toString();
      final baseId = _pickId(e, fkCandidates);
      final baseRow = baseMap[baseId] ?? {};
      final descr = (baseRow['description'] ?? '').toString();
      final unit = (baseRow['unit'] ?? '').toString();
      final fmt = baseRow['format']?.toString();
      final gram = baseRow['grammage']?.toString();
      final qty = _pickNumDynamic(e, [
            _arrMap[typeKey]?['qty'],
            'quantity',
            'qty',
            'amount',
            'added_qty',
          ]) ??
          0;
      final dateIso =
          (e['created_at'] ?? e['date'] ?? e['timestamp'] ?? '').toString();
      final note =
          _pickStr(e, [_arrMap[typeKey]?['note'], 'note', 'comment', 'reason']);
      final by = _pickStr(e, [
        'by_name',
        'byName',
        'by',
        'user_name',
        'employee_name',
        'operator',
        'who'
      ]);
      return _LogRow(
        id: id,
        description: descr,
        quantity: qty.toDouble(),
        unit: unit,
        dateIso: dateIso,
        note: note,
        format: fmt,
        grammage: gram,
        byName: by,
      );
    }).toList();
  }

  // --- сортировка ---
  void _resort() {
    int cmpNum(num? a, num? b) => (a ?? -1e9).compareTo((b ?? -1e9));
    int cmpDate(String a, String b) {
      late DateTime pa, pb;
      try {
        pa = DateTime.parse(a);
      } catch (_) {
        pa = DateTime.fromMillisecondsSinceEpoch(0);
      }
      try {
        pb = DateTime.parse(b);
      } catch (_) {
        pb = DateTime.fromMillisecondsSinceEpoch(0);
      }
      return pa.compareTo(pb);
    }

    int Function(TmcModel, TmcModel) itemComparator;
    switch (_sortField) {
      case 'quantity':
        itemComparator = (a, b) => cmpNum(a.quantity, b.quantity);
        break;
      case 'date':
      default:
        itemComparator = (a, b) => cmpDate(a.date, b.date);
        break;
    }

    int Function(_LogRow, _LogRow) logComparator;
    switch (_sortField) {
      case 'quantity':
        logComparator = (a, b) => cmpNum(a.quantity, b.quantity);
        break;
      case 'date':
      default:
        logComparator = (a, b) => cmpDate(a.dateIso, b.dateIso);
        break;
    }

    setState(() {
      _items.sort(itemComparator);
      _writeoffs.sort(logComparator);
      _inventories.sort(logComparator);
      _arrivals.sort(logComparator);
      if (_sortDesc) {
        _items = _items.reversed.toList();
        _writeoffs = _writeoffs.reversed.toList();
        _inventories = _inventories.reversed.toList();
        _arrivals = _arrivals.reversed.toList();
      }
    });
  }

  /// Фильтр по тексту для позиций
  List<TmcModel> _applyFilterItems(List<TmcModel> src) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return src;
    return src
        .where((e) =>
            e.description.toLowerCase().contains(q) ||
            (e.note ?? '').toLowerCase().contains(q))
        .toList();
  }

  /// Фильтр по тексту для логов
  List<_LogRow> _applyFilterLogs(List<_LogRow> src) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return src;
    return src
        .where((e) =>
            e.description.toLowerCase().contains(q) ||
            (e.note ?? '').toLowerCase().contains(q))
        .toList();
  }

  Future<void> _deleteTable() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить таблицу?'),
        content: Text(
            'Все записи типа: "${widget.type}" будут удалены безвозвратно.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Удалить')),
        ],
      ),
    );
    if (ok == true) {
      await Provider.of<WarehouseProvider>(context, listen: false)
          .deleteType(widget.type);
      try {
        final db = DocDB();
        final rows = await db.whereEq('warehouse_types', 'name', widget.type);
        for (final row in rows) {
          final rid = row['id'] as String?;
          if (rid != null) await db.deleteById(rid);
        }
      } catch (_) {}
      if (mounted) Navigator.of(context).pop();
    }
  }

  Widget _scrollableTable(Widget table) {
    final vertical = ScrollController();
    final horizontal = ScrollController();
    return Scrollbar(
      controller: vertical,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: vertical,
        child: Scrollbar(
          controller: horizontal,
          thumbVisibility: true,
          notificationPredicate: (notif) =>
              notif.metrics.axis == Axis.horizontal,
          child: SingleChildScrollView(
            controller: horizontal,
            scrollDirection: Axis.horizontal,
            child: table,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final typeKey = _normalizeType(widget.type);
    const protectedTypes = {'paper', 'stationery', 'paint', 'pens'};
    final canDeleteTable = !protectedTypes.contains(typeKey);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Список'),
            Tab(text: 'Списания'),
            Tab(text: 'Приходы'),
            Tab(text: 'Инвентаризация'),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Поле сортировки',
            onSelected: (v) {
              setState(() => _sortField = v);
              _resort();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'date', child: Text('По дате/времени')),
              PopupMenuItem(value: 'quantity', child: Text('По количеству')),
            ],
            icon: const Icon(Icons.sort),
          ),
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Очистить поиск',
            onPressed: () {
              setState(() {
                _query = '';
                _searchController.clear();
              });
            },
          ),
          IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Обновить данные',
              onPressed: _loadAll),
          if (canDeleteTable)
            IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Удалить таблицу',
                onPressed: _deleteTable),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Поиск…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: (typeKey == 'paper')
                    ? IconButton(
                        icon: const Icon(Icons.filter_list),
                        onPressed: _openPaperFilters)
                    : null,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onChanged: (val) => setState(() => _query = val),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _listTab(),
                _writeoffsTab(),
                _arrivalsTab(),
                _inventoryTab(),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openAddDialog,
        icon: const Icon(Icons.add),
        label: const Text('Добавить'),
      ),
    );
  }

  /// --- Вкладка «Список» ---
  Widget _listTab() {
    final base = _normalizeType(widget.type) == 'paper'
        ? _applyPaperMultiFilters(List<TmcModel>.from(_items))
        : List<TmcModel>.from(_items);
    final items = _applyFilterItems(base);
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Card(
        elevation: 2,
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: items.isEmpty
              ? const Center(child: Text('Нет данных'))
              : _scrollableTable(
                  DataTable(
                    columnSpacing: 24,
                    columns: [
                      const DataColumn(label: Text('№')),
                      const DataColumn(label: Text('Наименование')),
                      const DataColumn(label: Text('Кол-во')),
                      const DataColumn(label: Text('Ед.')),
                      if (items.any((i) =>
                          i.format != null && i.format!.trim().isNotEmpty))
                        const DataColumn(label: Text('Формат')),
                      if (items.any((i) =>
                          i.grammage != null && i.grammage!.trim().isNotEmpty))
                        const DataColumn(label: Text('Граммаж')),
                      if (_normalizeType(widget.type) != 'paper' &&
                          items.any((i) => i.weight != null))
                        const DataColumn(label: Text('Вес (кг)')),
                      if (items.any(
                          (i) => i.note != null && i.note!.trim().isNotEmpty))
                        const DataColumn(label: Text('Заметки')),
                      if (widget.enablePhoto)
                        const DataColumn(label: Text('Фото')),
                      const DataColumn(label: Text('Действия')),
                    ],
                    rows: List<DataRow>.generate(items.length, (i) {
                      final item = items[i];
                      String fmtNum(num? v, {int frac = 2}) => v == null
                          ? ''
                          : (v is int
                              ? '$v'
                              : (v as double).toStringAsFixed(frac));
                      return DataRow(cells: [
                        DataCell(Text('${i + 1}')),
                        DataCell(Text(item.description)),
                        DataCell(Text(fmtNum(item.quantity, frac: 2))),
                        DataCell(Text(item.unit)),
                        if (items.any((i) =>
                            i.format != null && i.format!.trim().isNotEmpty))
                          DataCell(Text(item.format ?? '')),
                        if (items.any((i) =>
                            i.grammage != null &&
                            i.grammage!.trim().isNotEmpty))
                          DataCell(Text(item.grammage ?? '')),
                        if (_normalizeType(widget.type) != 'paper' &&
                            items.any((i) => i.weight != null))
                          DataCell(Text(fmtNum(item.weight, frac: 2))),
                        if (items.any(
                            (i) => i.note != null && i.note!.trim().isNotEmpty))
                          DataCell(Text(item.note ?? '')),
                        if (widget.enablePhoto)
                          DataCell(Row(children: [
                            Builder(builder: (context) {
                              Uint8List? bytes;
                              try {
                                if (item.imageBase64 != null &&
                                    item.imageBase64!.isNotEmpty) {
                                  bytes = base64Decode(item.imageBase64!);
                                }
                              } catch (_) {}
                              Widget preview;
                              if (bytes != null && bytes.isNotEmpty) {
                                preview = ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: Image.memory(bytes,
                                      width: 50, height: 50, fit: BoxFit.cover),
                                );
                              } else if (item.imageUrl != null &&
                                  item.imageUrl!.isNotEmpty) {
                                preview = ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: Image.network(item.imageUrl!,
                                      width: 50, height: 50, fit: BoxFit.cover),
                                );
                              } else {
                                preview = const Icon(Icons.image_not_supported);
                              }
                              return preview;
                            }),
                            IconButton(
                                icon: const Icon(Icons.add_a_photo),
                                tooltip: 'Сменить фото',
                                onPressed: () => _changePhoto(item)),
                          ])),
                        DataCell(Row(children: [
                          IconButton(
                              icon: const Icon(Icons.edit, size: 20),
                              tooltip: 'Редактировать',
                              onPressed: () => _editItem(item)),
                          IconButton(
                              icon: const Icon(Icons.add, size: 20),
                              tooltip: 'Пополнить',
                              onPressed: () => _increase(item)),
                          IconButton(
                              icon: const Icon(Icons.remove_circle_outline,
                                  size: 20),
                              tooltip: 'Списать',
                              onPressed: () => _writeOff(item)),
                          IconButton(
                              icon: const Icon(Icons.inventory_2_outlined,
                                  size: 20),
                              tooltip: 'Инвентаризация',
                              onPressed: () => _inventory(item)),
                          IconButton(
                              icon: const Icon(Icons.delete, size: 20),
                              tooltip: 'Удалить',
                              onPressed: () => _deleteItem(item)),
                        ])),
                      ]);
                    }),
                  ),
                ),
        ),
      ),
    );
  }

  /// --- Вкладка «Списания» ---
  Widget _writeoffsTab() {
    final rows = _applyFilterLogs(List<_LogRow>.from(_writeoffs));
    final showFmt = rows.any((r) => (r.format ?? '').trim().isNotEmpty);
    final showGram = rows.any((r) => (r.grammage ?? '').trim().isNotEmpty);

    final columns = <DataColumn>[
      const DataColumn(label: Text('№')),
      const DataColumn(label: Text('Наименование')),
      const DataColumn(label: Text('Кол-во')),
      const DataColumn(label: Text('Ед.')),
      if (showFmt) const DataColumn(label: Text('Формат')),
      if (showGram) const DataColumn(label: Text('Граммаж')),
      const DataColumn(label: Text('Дата')),
      const DataColumn(label: Text('Комментарий')),
      const DataColumn(label: Text('Сотрудник')),
    ];

    return Padding(
      padding: const EdgeInsets.all(8),
      child: Card(
        elevation: 2,
        child: rows.isEmpty
            ? const Center(heightFactor: 4, child: Text('Нет списаний'))
            : _scrollableTable(
                DataTable(
                  columnSpacing: 24,
                  columns: columns,
                  rows: List<DataRow>.generate(rows.length, (i) {
                    final r = rows[i];
                    final cells = <DataCell>[
                      DataCell(Text('${i + 1}')),
                      DataCell(Text(r.description)),
                      DataCell(Text(r.quantity.toStringAsFixed(2))),
                      DataCell(Text(r.unit)),
                      if (showFmt) DataCell(Text(r.format ?? '')),
                      if (showGram) DataCell(Text(r.grammage ?? '')),
                      DataCell(Text(_fmtDate(r.dateIso))),
                      DataCell(Text(r.note ?? '')),
                      DataCell(Text(r.byName ?? '')),
                    ];
                    return DataRow(cells: cells);
                  }),
                ),
              ),
      ),
    );
  }

  /// --- Вкладка «Приходы» ---
  Widget _arrivalsTab() {
    final rows = _applyFilterLogs(List<_LogRow>.from(_arrivals));
    final showFmt = rows.any((r) => (r.format ?? '').trim().isNotEmpty);
    final showGram = rows.any((r) => (r.grammage ?? '').trim().isNotEmpty);

    final columns = <DataColumn>[
      const DataColumn(label: Text('№')),
      const DataColumn(label: Text('Наименование')),
      const DataColumn(label: Text('Кол-во')),
      const DataColumn(label: Text('Ед.')),
      if (showFmt) const DataColumn(label: Text('Формат')),
      if (showGram) const DataColumn(label: Text('Граммаж')),
      const DataColumn(label: Text('Дата')),
      const DataColumn(label: Text('Комментарий')),
      const DataColumn(label: Text('Сотрудник')),
    ];

    return Padding(
      padding: const EdgeInsets.all(8),
      child: Card(
        elevation: 2,
        child: rows.isEmpty
            ? const Center(heightFactor: 4, child: Text('Нет приходов'))
            : _scrollableTable(
                DataTable(
                  columnSpacing: 24,
                  columns: columns,
                  rows: List<DataRow>.generate(rows.length, (i) {
                    final r = rows[i];
                    final cells = <DataCell>[
                      DataCell(Text('${i + 1}')),
                      DataCell(Text(r.description)),
                      DataCell(Text(r.quantity.toStringAsFixed(2))),
                      DataCell(Text(r.unit)),
                      if (showFmt) DataCell(Text(r.format ?? '')),
                      if (showGram) DataCell(Text(r.grammage ?? '')),
                      DataCell(Text(_fmtDate(r.dateIso))),
                      DataCell(Text(r.note ?? '')),
                      DataCell(Text(r.byName ?? '')),
                    ];
                    return DataRow(cells: cells);
                  }),
                ),
              ),
      ),
    );
  }

  /// --- Вкладка «Инвентаризация» ---
  Widget _inventoryTab() {
    final rows = _applyFilterLogs(List<_LogRow>.from(_inventories));
    final showFmt = rows.any((r) => (r.format ?? '').trim().isNotEmpty);
    final showGram = rows.any((r) => (r.grammage ?? '').trim().isNotEmpty);

    final columns = <DataColumn>[
      const DataColumn(label: Text('№')),
      const DataColumn(label: Text('Наименование')),
      const DataColumn(label: Text('Кол-во')),
      const DataColumn(label: Text('Ед.')),
      if (showFmt) const DataColumn(label: Text('Формат')),
      if (showGram) const DataColumn(label: Text('Граммаж')),
      const DataColumn(label: Text('Дата')),
      const DataColumn(label: Text('Заметка')),
      const DataColumn(label: Text('Сотрудник')),
    ];

    return Padding(
      padding: const EdgeInsets.all(8),
      child: Card(
        elevation: 2,
        child: rows.isEmpty
            ? const Center(heightFactor: 4, child: Text('Нет инвентаризаций'))
            : _scrollableTable(
                DataTable(
                  columnSpacing: 24,
                  columns: columns,
                  rows: List<DataRow>.generate(rows.length, (i) {
                    final r = rows[i];
                    final cells = <DataCell>[
                      DataCell(Text('${i + 1}')),
                      DataCell(Text(r.description)),
                      DataCell(Text(r.quantity.toStringAsFixed(2))),
                      DataCell(Text(r.unit)),
                      if (showFmt) DataCell(Text(r.format ?? '')),
                      if (showGram) DataCell(Text(r.grammage ?? '')),
                      DataCell(Text(_fmtDate(r.dateIso))),
                      DataCell(Text(r.note ?? '')),
                      DataCell(Text(r.byName ?? '')),
                    ];
                    return DataRow(cells: cells);
                  }),
                ),
              ),
      ),
    );
  }

  /// Форматирование даты для логов.
  String _fmtDate(String iso) {
    final formatted = formatKostanayTimestamp(iso, fallback: '—');
    if (formatted == '—') return formatted;
    final parts = formatted.split(' ');
    if (parts.length < 2) return formatted;
    final dateParts = parts.first.split('-');
    if (dateParts.length != 3) return formatted;
    return '${dateParts[2]}.${dateParts[1]} ${parts[1]}';
  }

  /// Диалог добавления новой записи.
  Future<void> _openAddDialog() async {
    await showDialog(
        context: context,
        builder: (_) => AddEntryDialog(initialTable: widget.type));
    await _loadAll();
  }

  /// Диалог редактирования.
  Future<void> _editItem(TmcModel item) async {
    await showDialog(
        context: context, builder: (_) => AddEntryDialog(existing: item));
    await _loadAll();
  }

  /// Пополнение.
  Future<void> _increase(TmcModel item) async {
    final typeKey = _normalizeType(widget.type);
    if (typeKey == 'paper') {
      await _increasePaper(item);
      return;
    }
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Пополнить: ${item.description}'),
        content: TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Сколько добавить'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Добавить')),
        ],
      ),
    );
    if (ok == true) {
      final v = double.tryParse(c.text.replaceAll(',', '.')) ?? 0;
      if (v <= 0) return;

      try {
        await _logArrival(
            typeKey: _normalizeType(widget.type), itemId: item.id, qty: v);
      } catch (_) {}
      await _loadAll();
    }
  }

  /// Лог прихода (универсально по типу)
  Future<void> _logArrival({
    required String typeKey,
    required String itemId,
    required double qty,
    String? note,
  }) async {
    final s = Supabase.instance.client;
    final tables = _arrivalTables(typeKey);
    final fkCandidates = <String>[
      'item_id',
      'stationery_id',
      'paper_id',
      'paint_id',
      'material_id',
      'tmc_id',
      'fk_id',
      if (_arrMap[typeKey]?['fk'] != null) _arrMap[typeKey]!['fk']!
    ];
    final qtyCandidates = <String>[
      'qty',
      'quantity',
      'amount',
      'count',
      if (_arrMap[typeKey]?['qty'] != null) _arrMap[typeKey]!['qty']!
    ];
    final noteCandidates = <String>[
      'note',
      'comment',
      'reason',
      if (_arrMap[typeKey]?['note'] != null) _arrMap[typeKey]!['note']!
    ];

    for (final t in tables) {
      for (final fk in fkCandidates) {
        try {
          final payload = <String, dynamic>{fk: itemId};
          final __by = (AuthHelper.currentUserName ?? '').trim().isEmpty
              ? (AuthHelper.isTechLeader ? 'Технический лидер' : '—')
              : AuthHelper.currentUserName!;
          payload['by_name'] = __by;
          bool setQty = false;
          for (final q in qtyCandidates) {
            if (!setQty) {
              payload[q] = qty;
              setQty = true;
            }
          }
          if (note != null && note.isNotEmpty) {
            bool setNote = false;
            for (final n in noteCandidates) {
              if (!setNote) {
                payload[n] = note;
                setNote = true;
              }
            }
          }
          try {
            await s.from(t).insert(payload);
            return;
          } on PostgrestException catch (e) {
            if ((e.message ?? '').contains('by_name') ||
                (e.code ?? '') == '42703') {
              final p2 = Map<String, dynamic>.from(payload)..remove('by_name');
              await s.from(t).insert(p2);
              return;
            }
            rethrow;
          }
        } catch (_) {
          // try next combination
        }
      }
    }
  }

  Future<void> _increasePaper(TmcModel item) async {
    String method = 'meters';
    final metersC = TextEditingController();
    final weightC = TextEditingController();
    final diameterC = TextEditingController();
    double? format = double.tryParse((item.format ?? '').replaceAll(',', '.'));
    double? grammage =
        double.tryParse((item.grammage ?? '').replaceAll(',', '.'));
    final formKey = GlobalKey<FormState>();

    double? _computeFromWeight(double wKg, double fmt, double g) {
      return ((wKg * 1000) / g) / (fmt / 100.0);
    }

    double? _computeFromDiameter(double d, double fmt, double g, bool isWhite) {
      final r_m = (d / 2.0) / 100.0;
      final area_m2 = r_m * r_m * 3.14;
      final k = (isWhite ? 8.8 : 7.75) * fmt;
      final res = ((area_m2 * k) * 1000.0) / g / (fmt / 100.0);
      return res;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text('Пополнить бумагу: ${item.description}'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    value: method,
                    items: const [
                      DropdownMenuItem(
                          value: 'meters', child: Text('Ввести метры')),
                      DropdownMenuItem(
                          value: 'weight', child: Text('По весу (кг)')),
                      DropdownMenuItem(
                          value: 'diameter', child: Text('По диаметру (см)')),
                    ],
                    onChanged: (v) => setS(() => method = v ?? 'meters'),
                    decoration: const InputDecoration(labelText: 'Способ'),
                  ),
                  SizedBox(height: 8),
                  if (method == 'meters')
                    TextFormField(
                      controller: metersC,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Метров'),
                      validator: (v) {
                        final d =
                            double.tryParse((v ?? '').replaceAll(',', '.'));
                        return (d == null || d <= 0) ? 'Укажите метры' : null;
                      },
                    ),
                  if (method == 'weight') ...[
                    TextFormField(
                      controller: weightC,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Вес (кг)'),
                      validator: (v) {
                        final d =
                            double.tryParse((v ?? '').replaceAll(',', '.'));
                        return (d == null || d <= 0) ? 'Укажите вес' : null;
                      },
                    ),
                    SizedBox(height: 8),
                    TextFormField(
                      initialValue: (item.format ?? ''),
                      onChanged: (v) =>
                          format = double.tryParse(v.replaceAll(',', '.')),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration:
                          const InputDecoration(labelText: 'Формат (см)'),
                    ),
                    SizedBox(height: 8),
                    TextFormField(
                      initialValue: (item.grammage ?? ''),
                      onChanged: (v) =>
                          grammage = double.tryParse(v.replaceAll(',', '.')),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration:
                          const InputDecoration(labelText: 'Грамаж (г/м²)'),
                    ),
                  ],
                  if (method == 'diameter') ...[
                    TextFormField(
                      controller: diameterC,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration:
                          const InputDecoration(labelText: 'Диаметр (см)'),
                      validator: (v) {
                        final d =
                            double.tryParse((v ?? '').replaceAll(',', '.'));
                        return (d == null || d <= 0) ? 'Укажите диаметр' : null;
                      },
                    ),
                    SizedBox(height: 8),
                    TextFormField(
                      initialValue: (item.format ?? ''),
                      onChanged: (v) =>
                          format = double.tryParse(v.replaceAll(',', '.')),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration:
                          const InputDecoration(labelText: 'Формат (см)'),
                    ),
                    SizedBox(height: 8),
                    TextFormField(
                      initialValue: (item.grammage ?? ''),
                      onChanged: (v) =>
                          grammage = double.tryParse(v.replaceAll(',', '.')),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration:
                          const InputDecoration(labelText: 'Грамаж (г/м²)'),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Отмена')),
            FilledButton(
                onPressed: () {
                  if (!formKey.currentState!.validate()) return;
                  Navigator.pop(ctx, true);
                },
                child: const Text('Пополнить')),
          ],
        ),
      ),
    );
    if (ok != true) return;

    double addMeters = 0;
    final nameLow = item.description.toLowerCase();
    final isWhite = nameLow.contains('белый') || nameLow.contains(' бел');
    final isBrown = nameLow.contains('коричнев');

    if (method == 'meters') {
      addMeters = double.tryParse(metersC.text.replaceAll(',', '.')) ?? 0;
    } else if (method == 'weight') {
      if (format == null || format == 0 || grammage == null || grammage == 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Укажите формат и грамаж')));
        }
        return;
      }
      final w = double.tryParse(weightC.text.replaceAll(',', '.')) ?? 0;
      addMeters = _computeFromWeight(w, format!, grammage!) ?? 0;
    } else if (method == 'diameter') {
      if (format == null || format == 0 || grammage == null || grammage == 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Укажите формат и грамаж')));
        }
        return;
      }
      final d = double.tryParse(diameterC.text.replaceAll(',', '.')) ?? 0;
      final white = isWhite && !isBrown;
      addMeters = _computeFromDiameter(d, format!, grammage!, white) ?? 0;
    }
    if (addMeters <= 0) return;
    final provider = Provider.of<WarehouseProvider>(context, listen: false);
    await provider.addPaperArrival(paperId: item.id, qty: addMeters);
    await _loadAll();
  }

  Future<void> _writeOff(TmcModel item) async {
    final qtyC = TextEditingController();
    final commentC = TextEditingController();
    final result = await showDialog<double?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Списать: ${item.description}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: qtyC,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Количество'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: commentC,
              decoration: const InputDecoration(
                  labelText: 'Комментарий (необязательно)'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Отмена')),
          TextButton(
            onPressed: () {
              final v = double.tryParse(qtyC.text.replaceAll(',', '.'));
              Navigator.of(ctx).pop(v);
            },
            child: const Text('Списать'),
          ),
        ],
      ),
    );

    if (result == null || result <= 0) return;
    // Не позволяем списать больше, чем есть (для канцтоваров/ручек)
    final __t = _normalizeType(widget.type);
    if ((__t == 'stationery' || __t == 'pens') && result > item.quantity) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Нельзя списать больше, чем на складе')),
        );
      }
      return;
    }

    final typeKey = _normalizeType(widget.type);
    try {
      if (typeKey == 'stationery' || typeKey == 'pens') {
        final provider = Provider.of<WarehouseProvider>(context, listen: false);
        await provider.writeOff(
          itemId: item.id,
          qty: result,
          reason: commentC.text.trim().isEmpty ? null : commentC.text.trim(),
        );
      } else {
        final provider = Provider.of<WarehouseProvider>(context, listen: false);
        await provider.registerShipment(
          id: item.id,
          type: widget.type,
          qty: result,
          reason: commentC.text.trim().isEmpty ? null : commentC.text.trim(),
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text('Списано ${result.toStringAsFixed(2)} ${item.unit}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Ошибка списания: $e')));
      }
    }

    await _loadAll();
  }

  /// Инвентаризация
  Future<void> _inventory(TmcModel item) async {
    final qtyC = TextEditingController(text: item.quantity.toStringAsFixed(2));
    final noteC = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Инвентаризация: ${item.description}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: qtyC,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration:
                  const InputDecoration(labelText: 'Фактическое количество'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: noteC,
              decoration:
                  const InputDecoration(labelText: 'Заметка (необязательно)'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Сохранить')),
        ],
      ),
    );

    if (ok != true) return;
    final factual = double.tryParse(qtyC.text.replaceAll(',', '.'));
    if (factual == null || factual < 0) return;

    final typeKey = _normalizeType(widget.type);
    try {
      if (typeKey == 'stationery' || typeKey == 'pens') {
        final provider = Provider.of<WarehouseProvider>(context, listen: false);
        await provider.inventorySet(
          itemId: item.id,
          newQty: factual,
          note: noteC.text.trim().isEmpty ? null : noteC.text.trim(),
        );
      } else {
        final provider = Provider.of<WarehouseProvider>(context, listen: false);
        await provider.updateTmcQuantity(id: item.id, newQuantity: factual);

        final s = Supabase.instance.client;
        final tableCandidates = _inventoryTables(typeKey);
        final fkCandidates = <String>[
          'item_id',
          'stationery_id',
          'paper_id',
          'paint_id',
          'material_id',
          'tmc_id',
          'fk_id',
          if (_invMap[typeKey]?['fk'] != null) _invMap[typeKey]!['fk']!
        ];
        final qtyCandidates = <String>[
          'counted_qty',
          'quantity',
          'qty',
          if (_invMap[typeKey]?['qty'] != null) _invMap[typeKey]!['qty']!
        ];
        final noteCandidates = <String>[
          'note',
          'reason',
          'comment',
          if (_invMap[typeKey]?['note'] != null) _invMap[typeKey]!['note']!
        ];

        bool inserted = false;
        for (final table in tableCandidates) {
          for (final fk in fkCandidates) {
            for (final qtyCol in qtyCandidates) {
              try {
                final payload = <String, dynamic>{
                  fk: item.id,
                  'by_name': ((AuthHelper.currentUserName ?? '').trim().isEmpty
                      ? (AuthHelper.isTechLeader ? 'Технический лидер' : '—')
                      : AuthHelper.currentUserName!),
                  qtyCol: factual,
                };
                final note = noteC.text.trim();
                if (note.isNotEmpty) {
                  payload[noteCandidates.first] = note;
                }
                try {
                  await s.from(table).insert(payload);
                  inserted = true;
                } on PostgrestException catch (e) {
                  if ((e.message ?? '').contains('by_name') ||
                      (e.code ?? '') == '42703') {
                    final p2 = Map<String, dynamic>.from(payload)
                      ..remove('by_name');
                    await s.from(table).insert(p2);
                    inserted = true;
                  } else {
                    rethrow;
                  }
                }
                break;
              } catch (_) {}
            }
            if (inserted) break;
          }
          if (inserted) break;
        }

        if (!inserted) {
          throw Exception(
              'Не удалось вставить лог инвентаризации: нет подходящей таблицы/колонок');
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Инвентаризация сохранена (${factual.toStringAsFixed(2)} ${item.unit})')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Ошибка инвентаризации: $e')));
      }
    }

    await _loadAll();
  }

  /// Смена фотографии.
  Future<void> _changePhoto(TmcModel item) async {
    final picker = ImagePicker();
    final src = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              leading: const Icon(Icons.photo),
              title: const Text('Галерея'),
              onTap: () => Navigator.pop(context, ImageSource.gallery)),
          ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('Камера'),
              onTap: () => Navigator.pop(context, ImageSource.camera)),
        ]),
      ),
    );
    if (src == null) return;
    final img = await picker.pickImage(source: src, imageQuality: 85);
    if (img == null) return;
    final bytes = await img.readAsBytes();

    try {
      await Provider.of<WarehouseProvider>(context, listen: false).updateTmc(
        id: item.id,
        imageBytes: bytes,
        imageContentType: 'image/jpeg',
      );
      await _loadAll();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Не удалось обновить фото: $e')));
      }
    }
  }

  Future<void> _deleteItem(TmcModel item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Удалить запись?'),
        content: Text('Будет удалена «${item.description}».'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Удалить')),
        ],
      ),
    );
    if (ok == true) {
      await Provider.of<WarehouseProvider>(context, listen: false)
          .deleteTmc(item.id);
      await _loadAll();
    }
  }

  /// Уведомления о низком остатке (пока без логики порогов – заглушка, чтобы не падала сборка).
  void _notifyThresholds() {
    // TODO: сюда можно добавить проверку порогов и показ SnackBar/диалога.
    // Метод оставлен пустым намеренно, чтобы убрать ошибку "не определён".
  }
}

class _LogRow {
  final String id;
  final String description;
  final double quantity;
  final String unit;
  final String dateIso;
  final String? note;
  final String? format;
  final String? grammage;
  final String? byName;

  const _LogRow({
    required this.id,
    required this.description,
    required this.quantity,
    required this.unit,
    required this.dateIso,
    this.note,
    this.format,
    this.grammage,
    this.byName,
  });
}
