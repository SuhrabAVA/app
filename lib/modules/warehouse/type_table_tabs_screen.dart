// lib/modules/warehouse/type_table_tabs_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'warehouse_provider.dart';
import '../../services/doc_db.dart';
import 'paint_stock_rules.dart';
import 'paper_multi_filter.dart';
import 'tmc_model.dart';
import '../../utils/auth_helper.dart';
import 'add_entry_dialog.dart';
import '../../utils/kostanay_time.dart';
import 'deleted_records_repository.dart';
import 'paint_deletion_rules.dart';
import 'deleted_records_screen.dart';
import 'stock_journal_repository.dart';
import 'warehouse_logs_repository.dart';
import 'warehouse_table_styles.dart';

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
  // Один фильтр на все четыре вкладки (paper_multi_filter.dart).
  final PaperMultiFilter _paperFilter = PaperMultiFilter();

  bool get _isPaper => _normalizeType(widget.type) == 'paper';

  /// Варианты для чипов: из позиций склада И из журналов — у списаний
  /// удалённого рулона карточки в «Списке» уже нет, а отфильтровать их
  /// по-прежнему нужно.
  PaperFilterOptions _paperFilterOptions() {
    return PaperFilterOptions.from([
      for (final p in _items)
        (name: p.description, format: p.format, grammage: p.grammage),
      for (final r in [..._writeoffs, ..._arrivals, ..._inventories])
        (name: r.description, format: r.format, grammage: r.grammage),
    ]);
  }

  List<TmcModel> _applyPaperMultiFilters(List<TmcModel> src) {
    if (!_isPaper || !_paperFilter.isActive) return src;
    return src
        .where((e) => _paperFilter.matches(
            name: e.description, format: e.format, grammage: e.grammage))
        .toList();
  }

  List<_LogRow> _applyPaperMultiFiltersToLogs(List<_LogRow> src) {
    if (!_isPaper || !_paperFilter.isActive) return src;
    return src
        .where((e) => _paperFilter.matches(
            name: e.description, format: e.format, grammage: e.grammage))
        .toList();
  }

  void _openPaperFilters() {
    final options = _paperFilterOptions();
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
                    chips(options.names, _paperFilter.names, 'Названия'),
                    const SizedBox(height: 12),
                    chips(options.formats, _paperFilter.formats, 'Форматы'),
                    const SizedBox(height: 12),
                    chips(options.grammages, _paperFilter.grammages,
                        'Граммажи'),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton(
                          onPressed: () {
                            setSt(_paperFilter.clear);
                            // Сброс сразу виден в таблице, без «Применить».
                            setState(() {});
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
      // Чипы меняют фильтр сразу. Закрыли лист мимо «Применить» (тап по фону,
      // «назад») — таблица всё равно должна показать выбранное.
    ).whenComplete(() {
      if (mounted) setState(() {});
    });
  }

  late final TabController _tabs;
  // Ф3: собственного realtime-канала у экрана больше нет — единственный
  // источник обновлений WarehouseProvider (слушаем его как ChangeNotifier
  // и перерисовываемся из его памяти без сетевых запросов).
  WarehouseProvider? _provider;
  // Дебаунс отложенного повтора _loadAll (если загрузку запросили, пока
  // предыдущая ещё шла).
  Timer? _reloadDebounce;
  // Guard от наложения: если _loadAll уже идёт, помечаем, что нужен повтор,
  // и запускаем его один раз по завершении текущего.
  bool _loadInFlight = false;
  bool _reloadRequested = false;

  // Постоянные скролл-контроллеры для таблиц вкладок. Раньше _scrollableTable
  // создавал их прямо в build на каждую перестройку — новые контроллеры
  // каждый кадр заставляли Scrollbar переприсоединять обработку жестов, что
  // на Windows роняло жест скролла (direct_manipulation ZoomToRect). Каждой
  // вкладке — своя пара (нельзя шарить один контроллер между двумя
  // SingleChildScrollView: во время свайпа TabBarView держит две страницы
  // одновременно → иначе «attached to multiple scroll views»).
  final ScrollController _listVCtl = ScrollController();
  final ScrollController _listHCtl = ScrollController();
  final ScrollController _woVCtl = ScrollController();
  final ScrollController _woHCtl = ScrollController();
  final ScrollController _arrVCtl = ScrollController();
  final ScrollController _arrHCtl = ScrollController();
  final ScrollController _invVCtl = ScrollController();
  final ScrollController _invHCtl = ScrollController();
  // Основные позиции
  List<TmcModel> _items = [];

  // Логи
  List<_LogRow> _writeoffs = [];
  List<_LogRow> _inventories = [];
  List<_LogRow> _arrivals = [];

  String _sortField = 'name';
  bool _sortDesc = false;
  String _query = '';
  // Признаки «в таблице есть более старые записи, чем загружено» по видам
  // логов + флаг идущей догрузки («Показать ещё»).
  bool _woHasMore = false;
  bool _arrHasMore = false;
  bool _invHasMore = false;
  bool _loadingMoreLogs = false;

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

  static const Map<String, String> _deletedEntityTypes = {
    'paper': 'tmc_paper',
    'stationery': 'tmc_stationery',
    'paint': 'tmc_paint',
    'pens': 'tmc_pens',
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
        return const [
          'warehouse_pens',
          'pens',
        ];
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
      if (typeKey == 'paper') 'papers_inventories',
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
    if (typeKey == 'pens') {
      return 'id, description, unit, name, color';
    }
    return 'id, description, unit';
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
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
    _provider = context.read<WarehouseProvider>()
      ..addListener(_onProviderChanged);
    _loadAll();
  }

  /// Ф3: провайдер — единственный источник realtime-обновлений. Любое его
  /// изменение (точечный апдейт остатков, перечитанный вид лога, пересчёт
  /// резервов) применяется к экрану из памяти, без запросов и подписок.
  void _onProviderChanged() {
    if (!mounted || _loadInFlight) return;
    final provider = _provider;
    if (provider == null) return;
    _applySnapshot(
      items: provider.getTmcByType(widget.type),
      bundle: provider.logsBundle(_normalizeType(widget.type)),
    );
  }

  /// Отложенный повтор _loadAll (запрос пришёл во время идущей загрузки).
  void _scheduleReload() {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) _loadAll();
    });
  }

  /// Обёртка с guard: не запускаем параллельные тяжёлые перезагрузки. Если
  /// _loadAll вызвали во время уже идущей загрузки — ставим отложенный повтор
  /// и выполняем его один раз по завершении текущей.
  Future<void> _loadAll({bool force = false}) async {
    if (_loadInFlight) {
      _reloadRequested = true;
      return;
    }
    _loadInFlight = true;
    try {
      await _loadAllImpl(force: force);
    } finally {
      _loadInFlight = false;
      if (_reloadRequested && mounted) {
        _reloadRequested = false;
        _scheduleReload();
      } else {
        _reloadRequested = false;
      }
    }
  }

  void _applySnapshot({
    required List<TmcModel> items,
    WarehouseLogsBundle? bundle,
  }) {
    if (!mounted) return;
    final writeoffs =
        bundle == null ? _writeoffs : _mapBundleLogs(bundle.writeoffs);
    final inventories =
        bundle == null ? _inventories : _mapBundleLogs(bundle.inventories);
    final arrivals = bundle == null ? _arrivals : _mapBundleLogs(bundle.arrivals);

    if (!mounted) return;
    setState(() {
      _items = items;
      _writeoffs = writeoffs;
      _inventories = inventories;
      _arrivals = arrivals;
      if (bundle != null) {
        _woHasMore = bundle.writeoffsHasMore;
        _arrHasMore = bundle.arrivalsHasMore;
        _invHasMore = bundle.inventoriesHasMore;
      }
    });
    _notifyThresholds();
    _resort();
  }

  Future<void> _loadAllImpl({required bool force}) async {
    if (!mounted) return;
    final provider = Provider.of<WarehouseProvider>(context, listen: false);
    final typeKey = _normalizeType(widget.type);

    // 1) Мгновенно показываем то, что уже есть в памяти.
    final cachedItems = provider.getTmcByType(widget.type);
    final cachedBundle = provider.logsBundle(typeKey);
    _applySnapshot(items: cachedItems, bundle: cachedBundle);

    // 2) Остатки: провайдер загружает их сам при создании; повторный fetchTmc
    // здесь был дублирующим (Ф2). Гоняем его только по явному действию
    // (force) или если провайдер ещё ни разу не загрузился.
    if (force || !provider.hasLoadedTmc) {
      try {
        await provider.fetchTmc();
      } catch (_) {}
    }

    // 3) Логи типа: лениво из кэша провайдера; forceRefresh — только по
    // явному действию, а не при каждом открытии экрана (Ф2).
    final freshItems = provider.getTmcByType(widget.type);
    WarehouseLogsBundle? freshBundle;
    try {
      freshBundle = await provider.fetchLogsBundle(typeKey, forceRefresh: force);
    } catch (_) {
      freshBundle = provider.logsBundle(typeKey);
    }
    _applySnapshot(items: freshItems, bundle: freshBundle);
  }

  /// «Показать ещё»: догружает следующую порцию логов вида [action].
  Future<void> _loadMoreLogs(WarehouseLogAction action) async {
    if (_loadingMoreLogs) return;
    setState(() => _loadingMoreLogs = true);
    try {
      final provider = context.read<WarehouseProvider>();
      final bundle =
          await provider.loadMoreLogs(_normalizeType(widget.type), action);
      if (!mounted || bundle == null) return;
      setState(() {
        _writeoffs = _mapBundleLogs(bundle.writeoffs);
        _inventories = _mapBundleLogs(bundle.inventories);
        _arrivals = _mapBundleLogs(bundle.arrivals);
        _woHasMore = bundle.writeoffsHasMore;
        _arrHasMore = bundle.arrivalsHasMore;
        _invHasMore = bundle.inventoriesHasMore;
      });
      _resort();
    } catch (e) {
      debugPrint('⚠️ load more logs failed: $e');
    } finally {
      if (mounted) setState(() => _loadingMoreLogs = false);
    }
  }

  String _emptyLogText(String base) =>
      _paperFilter.isActive || _query.trim().isNotEmpty
          ? '$base по фильтру и поиску'
          : base;

  /// Подпись + кнопка догрузки под таблицей лога, когда история не вся.
  Widget _logsFooter(WarehouseLogAction action, int loadedCount) {
    return Padding(
      // Нижний отступ 88px выводит кнопку из-под плавающей кнопки «Добавить»
      // (FAB занимает правый нижний угол, ~72px с отступами): при прокрутке
      // до конца кнопка «Показать ещё» остаётся выше зоны FAB и кликабельна
      // на любых размерах экрана.
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 88),
      child: Row(
        children: [
          Expanded(
            child: Text(
              // С фильтром или поиском пустая таблица не значит «таких записей
              // нет»: ищем только в загруженной части журнала.
              _paperFilter.isActive || _query.trim().isNotEmpty
                  ? 'Поиск и фильтр — среди последних $loadedCount записей. '
                      'Более старые не загружены: нажмите «Показать ещё».'
                  : 'Показаны последние $loadedCount записей — история загружена не вся.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ),
          TextButton(
            onPressed: _loadingMoreLogs ? null : () => _loadMoreLogs(action),
            child: Text(_loadingMoreLogs
                ? 'Загрузка…'
                : 'Показать ещё ${WarehouseLogsRepository.kLogPageSize}'),
          ),
        ],
      ),
    );
  }

  List<_LogRow> _mapBundleLogs(List<WarehouseLogEntry> entries) {
    final provider = context.read<WarehouseProvider>();
    final String currentTypeKey = _normalizeType(widget.type);

    String resolveDescription(WarehouseLogEntry entry) {
      final String original = entry.description.trim();
      final bool hasMeaningfulDescription =
          original.isNotEmpty && original != '-' && original != '—';
      if (hasMeaningfulDescription) return original;

      final String itemId = (entry.itemId ?? '').trim();
      if (itemId.isEmpty) return entry.description;

      try {
        final tmc = provider.allTmc.firstWhere(
          (item) => item.id == itemId && _normalizeType(item.type) == currentTypeKey,
        );
        final String fallback = (tmc.description ?? '').trim();
        if (fallback.isNotEmpty) return fallback;
      } catch (_) {}

      return entry.description;
    }

    return entries
        .map((entry) {
          final isCanceled = _logIsCanceled(const {}, entry.note);
          return _LogRow(
            id: entry.id,
            description: resolveDescription(entry),
            quantity: entry.quantity.toDouble(),
            unit: entry.unit,
            dateIso: entry.timestampIso,
            note: entry.note,
            format: entry.format,
            grammage: entry.grammage,
            byName: _displayEmployeeName(entry.byName),
            itemId: entry.itemId,
            sourceTable: entry.sourceTable,
            action: entry.action,
            canUndo: (entry.itemId ?? '').isNotEmpty && !isCanceled,
            isCanceled: isCanceled,
          );
        })
        .toList();
  }

  bool _isReserveAwareType(String typeKey) => typeKey == 'paper' || typeKey == 'paint';

  Future<double> _reservedQtyForItem(TmcModel item, String typeKey) {
    if (typeKey == 'paper') {
      return context.read<WarehouseProvider>().paperReservedQty(item.id);
    }
    if (typeKey == 'paint') {
      return Future<double>.value(item.reservedQty);
    }
    return Future<double>.value(0);
  }

  String _reserveUnitLabel(TmcModel item, String typeKey) {
    if (typeKey == 'paper') return 'м';
    return item.unit.trim().isEmpty ? 'ед.' : item.unit.trim();
  }

  String _orderLabelFromReservation(Map<String, dynamic> row) {
    final order = row['orders'];
    if (order is Map) {
      final customer = (order['customer'] ?? '').toString().trim();
      if (customer.isNotEmpty) return customer;
    }

    final orderName = (row['order_name'] ?? '').toString().trim();
    final hasOrderName = orderName.isNotEmpty &&
        orderName.toLowerCase() != 'null' &&
        orderName.toLowerCase() != 'undefined' &&
        orderName.toLowerCase() != 'nan' &&
        orderName != '-';
    if (hasOrderName) return orderName;

    if (order is Map) {
      final code = (order['form_code'] ?? '').toString().trim();
      if (code.isNotEmpty) return code;
      final no = (order['new_form_no'] ?? '').toString().trim();
      if (no.isNotEmpty) return 'Форма №$no';
    }

    final orderId = (row['order_id'] ?? '').toString().trim();
    return orderId.isEmpty ? 'Заказ без названия' : 'Заказ $orderId';
  }

  Future<void> _showReserveDetails(TmcModel item) async {
    final typeKey = _normalizeType(widget.type);
    final provider = context.read<WarehouseProvider>();
    final details = typeKey == 'paint'
        ? await provider.getPaintReservationsByPaint(item.id)
        : await provider.paperReserveDetails(item.id);
    if (!mounted) return;
    final unit = _reserveUnitLabel(item, typeKey);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Резерв: ${item.description}'),
        content: SizedBox(
          width: 420,
          child: details.isEmpty
              ? Text(typeKey == 'paint'
                  ? 'По этой краске нет активного резерва.'
                  : 'По этой бумаге нет активного резерва.')
              : ListView(
                  shrinkWrap: true,
                  children: details.map((row) {
                    final rawQty = row['qty'] ?? row['active_reserved_qty'];
                    final qty = (row['qty'] as num?)?.toDouble() ??
                        (row['active_reserved_qty'] as num?)?.toDouble() ??
                        double.tryParse('$rawQty') ??
                        0;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(10),
                        color: Colors.grey.shade50,
                      ),
                      child: Text(
                        '${_orderLabelFromReservation(row)} • ${qty.toStringAsFixed(2)} $unit',
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                    );
                  }).toList(),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  @override
  void didUpdateWidget(covariant TypeTableTabsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.type != widget.type) {
      _loadAll();
    }
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    _provider?.removeListener(_onProviderChanged);
    _tabs.dispose();
    _listVCtl.dispose();
    _listHCtl.dispose();
    _woVCtl.dispose();
    _woHCtl.dispose();
    _arrVCtl.dispose();
    _arrHCtl.dispose();
    _invVCtl.dispose();
    _invHCtl.dispose();
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

  String _composeDescription(
      {required Map<String, dynamic> baseRow,
      required Map<String, dynamic> logRow,
      required String typeKey,
      String? itemId}) {
    bool isPlaceholder(String value) {
      final normalized = value.trim();
      return normalized.isEmpty || normalized == '-' || normalized == '—';
    }

    final baseDescr = (baseRow['description'] ?? '').toString().trim();
    if (baseDescr.isNotEmpty && !isPlaceholder(baseDescr)) return baseDescr;

    if (typeKey == 'pens') {
      final parts = <String>[];
      void addPart(dynamic value) {
        final s = (value ?? '').toString().trim();
        if (s.isEmpty || isPlaceholder(s)) return;
        parts.add(s);
      }

      addPart(baseRow['name']);
      addPart(baseRow['color']);
      if (parts.isEmpty) {
        addPart(logRow['name']);
        addPart(logRow['color']);
      }
      if (parts.isNotEmpty) {
        return parts.join(' • ');
      }
    }

    final fallback =
        _pickStr(logRow, ['description', 'name', 'item_name', 'title']);
    if (fallback != null && fallback.trim().isNotEmpty) {
      return fallback.trim();
    }

    if (itemId != null && itemId.isNotEmpty) {
      try {
        final provider = context.read<WarehouseProvider>();
        final tmc = provider.allTmc.firstWhere((e) => e.id == itemId);
        final desc = (tmc.description ?? '').trim();
        if (desc.isNotEmpty) {
          return desc;
        }
      } catch (_) {}
    }

    return '—';
  }

  Future<List<Map<String, dynamic>>> _selectAnyTable({
    required List<String> tables,
    required String selectFields,
    String? orderBy,
    bool ascending = true,
  }) async {
    final s = Supabase.instance.client;
    for (final t in tables) {
      final attemptedOrders = <String?>[
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

      final seen = <String?>{};
      for (final order in attemptedOrders.where((c) => seen.add(c))) {
        try {
          final query = s.from(t).select(selectFields);
          final data = order == null
              ? await query
              : await query.order(order, ascending: ascending);
          return (data as List).cast<Map<String, dynamic>>();
        } on PostgrestException catch (e) {
          final code = (e.code?.toString() ?? '').toLowerCase();
          final message = (e.message?.toString() ?? '').toLowerCase();
          final details = (e.details?.toString() ?? '').toLowerCase();
          final orderLower = order?.toLowerCase();
          final columnMissing = orderLower != null &&
              (code == '42703' ||
                  message.contains(orderLower) && message.contains('column') ||
                  details.contains(orderLower) && details.contains('column'));
          if (columnMissing) {
            continue; // попробуем следующую колонку сортировки
          }
        } catch (_) {
          // попробуем следующий order/table
        }
        break;
      }
    }
    return [];
  }

  /// Универсальный выбор по списку id (пытается по списку таблиц)

  static final RegExp _uuidLikePattern = RegExp(
    r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\b',
  );

  bool _isMeaningfulOrderLabel(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return false;
    final lower = normalized.toLowerCase();
    if (lower == 'null' || lower == 'undefined' || lower == 'nan' || lower == '-') {
      return false;
    }
    if (_uuidLikePattern.hasMatch(normalized)) return false;
    return true;
  }

  String _firstOrderLabel(Iterable<dynamic> values) {
    for (final value in values) {
      final text = (value ?? '').toString().trim();
      if (_isMeaningfulOrderLabel(text)) return text;
    }
    return '';
  }

  String? _extractOrderIdFromWriteoffNote(String? note) {
    final source = (note ?? '').trim();
    if (source.isEmpty) return null;
    final match = _uuidLikePattern.firstMatch(source);
    if (match == null) return null;
    return match.group(0);
  }

  Future<Map<String, String>> _loadOrderLabelsByIds(Set<String> orderIds) async {
    if (orderIds.isEmpty) return const <String, String>{};
    final labels = <String, String>{};
    try {
      final rows = await Supabase.instance.client
          .from('orders')
          // Только существующие колонки. У orders нет title/name/order_name/data:
          // прежний запрос всегда падал, и в журнале склада вместо заказа
          // оставался его uuid.
          .select('id, assignment_id, product_name, new_form_no, '
              'product_name_j:product->>name, product_title_j:product->>title')
          .inFilter('id', orderIds.toList(growable: false));
      if (rows is! List) return labels;
      for (final raw in rows.whereType<Map>()) {
        final row = Map<String, dynamic>.from(raw as Map);
        final orderId = (row['id'] ?? '').toString().trim();
        if (orderId.isEmpty) continue;

        final label = _firstOrderLabel([
          row['assignment_id'],
          row['product_name'],
          row['product_name_j'],
          row['product_title_j'],
        ]);

        final formNo = _firstOrderLabel([row['new_form_no']]);
        if (label.isNotEmpty) {
          labels[orderId] = label;
        } else if (formNo.isNotEmpty) {
          labels[orderId] = 'Форма №$formNo';
        }
      }
    } catch (_) {
      return labels;
    }
    return labels;
  }

  String _humanizeWriteoffNote(String? rawNote, Map<String, String> orderLabels) {
    final note = (rawNote ?? '').trim();
    if (note.isEmpty) return '';
    final match = _uuidLikePattern.firstMatch(note);
    if (match == null) return note;
    final orderId = match.group(0) ?? '';
    if (orderId.isEmpty) return note;
    final label = orderLabels[orderId];
    if (label == null || label.trim().isEmpty) return note;
    return note.replaceFirst(orderId, label.trim());
  }

  String _displayEmployeeName(String? value) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return '';
    final match = _uuidLikePattern.firstMatch(text);
    if (match != null && match.group(0) == text && text.length > 8) {
      return text.substring(0, 8);
    }
    return text;
  }

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

    final orderIdsInNotes = logs
        .map((e) => _extractOrderIdFromWriteoffNote(
            _pickStr(e, [_woMap[typeKey]?['note'], 'note', 'reason', 'comment'])))
        .whereType<String>()
        .toSet();
    final orderLabels = await _loadOrderLabelsByIds(orderIdsInNotes);

    return logs.map((e) {
      final id = (e['id'] ?? '').toString();
      final baseId = _pickId(e, fkCandidates);
      final baseRow = baseMap[baseId] ?? {};
      final descr = _composeDescription(
        baseRow: baseRow,
        logRow: e,
        typeKey: typeKey,
        itemId: baseId,
      );
      String unit = (baseRow['unit'] ?? '').toString();
      if (unit.trim().isEmpty) {
        unit = _pickStr(e, ['unit', 'units', 'unit_name']) ?? '';
      }
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
      final rawNote =
          _pickStr(e, [_woMap[typeKey]?['note'], 'note', 'reason', 'comment']);
      final note = _humanizeWriteoffNote(rawNote, orderLabels);
      final by = _pickStr(e, [
        'by_name',
        'byName',
        'by',
        'user_name',
        'employee_name',
        'employee',
        'operator',
        'who'
      ]);
      final isCanceled = _logIsCanceled(e, note);
      return _LogRow(
        id: id,
        description: descr,
        quantity: qty.toDouble(),
        unit: unit,
        dateIso: dateIso,
        note: note,
        format: fmt,
        grammage: gram,
        byName: _displayEmployeeName(by),
        itemId: baseId,
        action: WarehouseLogAction.writeoff,
        canUndo: (baseId ?? '').isNotEmpty && !isCanceled,
        isCanceled: isCanceled,
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
      final descr = _composeDescription(
        baseRow: baseRow,
        logRow: e,
        typeKey: typeKey,
        itemId: baseId,
      );
      String unit = (baseRow['unit'] ?? '').toString();
      if (unit.trim().isEmpty) {
        unit = _pickStr(e, ['unit', 'units', 'unit_name']) ?? '';
      }
      final fmt = baseRow['format']?.toString();
      final gram = baseRow['grammage']?.toString();
      final qty = _pickNumDynamic(e, [
            _invMap[typeKey]?['qty'],
            'counted_qty',
            'factual',
            'quantity',
            'qty'
          ]) ??
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
        'employee',
        'operator',
        'who'
      ]);
      final isCanceled = _logIsCanceled(e, note);
      return _LogRow(
        id: id,
        description: descr,
        quantity: qty.toDouble(),
        unit: unit,
        dateIso: dateIso,
        note: note,
        format: fmt,
        grammage: gram,
        byName: _displayEmployeeName(by),
        itemId: baseId,
        action: WarehouseLogAction.inventory,
        canUndo: (baseId ?? '').isNotEmpty && !isCanceled,
        isCanceled: isCanceled,
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
      final descr = _composeDescription(
        baseRow: baseRow,
        logRow: e,
        typeKey: typeKey,
        itemId: baseId,
      );
      String unit = (baseRow['unit'] ?? '').toString();
      if (unit.trim().isEmpty) {
        unit = _pickStr(e, ['unit', 'units', 'unit_name']) ?? '';
      }
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
        'employee',
        'operator',
        'who'
      ]);
      final isCanceled = _logIsCanceled(e, note);
      return _LogRow(
        id: id,
        description: descr,
        quantity: qty.toDouble(),
        unit: unit,
        dateIso: dateIso,
        note: note,
        format: fmt,
        grammage: gram,
        byName: _displayEmployeeName(by),
        itemId: baseId,
        action: WarehouseLogAction.arrival,
        canUndo: (baseId ?? '').isNotEmpty && !isCanceled,
        isCanceled: isCanceled,
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
      case 'name':
        itemComparator = (a, b) {
          final byDescription = a.description
              .toLowerCase()
              .compareTo(b.description.toLowerCase());
          if (byDescription != 0) return byDescription;
          final byFormat = (a.format ?? '')
              .toLowerCase()
              .compareTo((b.format ?? '').toLowerCase());
          if (byFormat != 0) return byFormat;
          final byGrammage = (a.grammage ?? '')
              .toLowerCase()
              .compareTo((b.grammage ?? '').toLowerCase());
          if (byGrammage != 0) return byGrammage;
          return a.id.compareTo(b.id);
        };
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
      case 'name':
        logComparator = (a, b) => cmpDate(a.dateIso, b.dateIso);
        break;
      case 'date':
      default:
        logComparator = (a, b) => cmpDate(a.dateIso, b.dateIso);
        break;
    }

    final bool itemsDesc = _sortDesc && _sortField != 'name';
    final bool logsDesc = _sortField == 'name' ? true : _sortDesc;

    setState(() {
      _items.sort(itemComparator);
      if (itemsDesc) {
        _items = _items.reversed.toList();
      }
      _writeoffs.sort(logComparator);
      _inventories.sort(logComparator);
      _arrivals.sort(logComparator);
      if (logsDesc) {
        _writeoffs = _writeoffs.reversed.toList();
        _inventories = _inventories.reversed.toList();
        _arrivals = _arrivals.reversed.toList();
      }
    });
  }

  void _openDeletedRecords() {
    final typeKey = _normalizeType(widget.type);
    final entityType = _deletedEntityTypes[typeKey];
    if (entityType == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DeletedRecordsScreen(
          entityType: entityType,
          title: 'Удалённые записи — ${widget.title}',
        ),
      ),
    );
  }

  /// Фильтр по тексту для позиций
  List<TmcModel> _applyFilterItems(List<TmcModel> src) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return src;
    bool matchesPaper(TmcModel e) {
      final format = (e.format ?? '').toLowerCase().trim();
      final grammage = (e.grammage ?? '').toLowerCase().trim();
      final searchableParts = [
        e.description,
        if (format.isNotEmpty) format,
        if (grammage.isNotEmpty) grammage,
      ]
          .join(' ')
          .toLowerCase();

      // Все слова из запроса должны присутствовать в одной строке
      final tokens = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
      return tokens.every((token) => searchableParts.contains(token));
    }

    return src.where((e) {
      final baseMatch =
          e.description.toLowerCase().contains(q) || (e.note ?? '').toLowerCase().contains(q);
      if (baseMatch) return true;

      // Расширенный поиск только для бумаги: по комбинациям «наименование + формат + граммаж»
      if (_normalizeType(widget.type) == 'paper') {
        return matchesPaper(e);
      }
      return false;
    }).toList();
  }

  /// Фильтр по тексту для логов
  List<_LogRow> _applyFilterLogs(List<_LogRow> src) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return src;
    if (_normalizeType(widget.type) == 'paper') {
      final tokens = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
      return src.where((e) {
        final parts = [
          e.description,
          e.format ?? '',
          e.grammage ?? '',
          e.note ?? '',
          e.unit,
          e.byName ?? '',
        ].join(' ').toLowerCase();
        return tokens.every(parts.contains);
      }).toList();
    }
    return src
        .where((e) =>
            e.description.toLowerCase().contains(q) ||
            (e.note ?? '').toLowerCase().contains(q))
        .toList();
  }

  bool _toBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final v = value.toLowerCase().trim();
      return v == 'true' || v == '1' || v == 'yes';
    }
    return false;
  }

  bool _logIsCanceled(Map<String, dynamic> row, String? note) {
    final marker = WarehouseProvider.canceledMarker.toLowerCase();
    final noteLower = (note ?? '').toLowerCase();
    return _toBool(row['is_canceled']) ||
        _toBool(row['is_cancelled']) ||
        _toBool(row['canceled']) ||
        _toBool(row['cancelled']) ||
        noteLower.contains(marker);
  }

  MaterialStateProperty<Color?> _logRowColor(bool isCanceled) {
    return MaterialStateProperty.resolveWith((states) {
      if (isCanceled) {
        return states.contains(MaterialState.hovered)
            ? Colors.grey.shade300
            : Colors.grey.shade200;
      }
      return warehouseRowHoverColor.resolve(states);
    });
  }

  Text _logCellText(String value, bool isCanceled) {
    return Text(
      value,
      style: isCanceled ? const TextStyle(color: Colors.grey) : null,
    );
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

  Widget _scrollableTable(
    Widget table, {
    required ScrollController vertical,
    required ScrollController horizontal,
    Widget? footer,
  }) {
    return Scrollbar(
      controller: vertical,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: vertical,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Scrollbar(
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
            if (footer != null) footer,
          ],
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
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Удалённые записи',
            onPressed: _openDeletedRecords,
          ),
          PopupMenuButton<String>(
            tooltip: 'Поле сортировки',
            onSelected: (v) {
              setState(() {
                _sortField = v;
                _sortDesc = v == 'name' ? false : true;
              });
              _resort();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'name', child: Text('По алфавиту (список)')),
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
              onPressed: () => _loadAll(force: true)),
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
                        tooltip: _paperFilter.isActive
                            ? 'Фильтр: выбрано ${_paperFilter.selectedCount}'
                            : 'Фильтр по названию, формату, граммажу',
                        icon: Badge(
                          isLabelVisible: _paperFilter.isActive,
                          label: Text('${_paperFilter.selectedCount}'),
                          child: Icon(
                            _paperFilter.isActive
                                ? Icons.filter_alt
                                : Icons.filter_list,
                            color: _paperFilter.isActive
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                        ),
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
    final typeKey = _normalizeType(widget.type);
    final base = typeKey == 'paper'
        ? _applyPaperMultiFilters(List<TmcModel>.from(_items))
        : List<TmcModel>.from(_items);
    final items = _applyFilterItems(base);
    final showReserveColumns = _isReserveAwareType(typeKey);
    final showFormat =
        items.any((i) => i.format != null && i.format!.trim().isNotEmpty);
    final showGrammage =
        items.any((i) => i.grammage != null && i.grammage!.trim().isNotEmpty);
    final showWeight = typeKey != 'paper' && items.any((i) => i.weight != null);
    final showNote =
        items.any((i) => i.note != null && i.note!.trim().isNotEmpty);
    final specs = _listColumnSpecs(
      typeKey: typeKey,
      showFormat: showFormat,
      showGrammage: showGrammage,
      showWeight: showWeight,
      showNote: showNote,
      showReserveColumns: showReserveColumns,
    );
    final double totalWidth =
        specs.fold(0.0, (sum, c) => sum + c.width) + 16;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Card(
        elevation: 2,
        child: items.isEmpty
            ? const Center(child: Text('Нет данных'))
            // Непрерывный список вместо PaginatedDataTable (страницы
            // неудобны для склада): виртуализация Ф1 сохранена —
            // ListView.builder строит только видимые строки, поэтому фото
            // по-прежнему грузятся лениво по мере скролла, а не все разом.
            : LayoutBuilder(builder: (context, constraints) {
                final double width = totalWidth < constraints.maxWidth
                    ? constraints.maxWidth
                    : totalWidth;
                return Scrollbar(
                  controller: _listHCtl,
                  thumbVisibility: true,
                  notificationPredicate: (notif) =>
                      notif.metrics.axis == Axis.horizontal,
                  child: SingleChildScrollView(
                    controller: _listHCtl,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: width,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _listHeader(specs),
                          const Divider(height: 1),
                          Expanded(
                            child: Scrollbar(
                              controller: _listVCtl,
                              thumbVisibility: true,
                              child: ListView.separated(
                                controller: _listVCtl,
                                itemCount: items.length,
                                separatorBuilder: (_, __) =>
                                    const Divider(height: 1),
                                itemBuilder: (context, i) =>
                                    _listRow(specs, items[i], i),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
      ),
    );
  }

  Widget _listHeader(List<_TmcColumnSpec> specs) {
    const style = TextStyle(fontWeight: FontWeight.w600, fontSize: 13);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
      child: Row(
        children: [
          for (final col in specs)
            col.flex
                ? Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Text(col.label, style: style),
                    ),
                  )
                : SizedBox(
                    width: col.width,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Text(col.label, style: style),
                    ),
                  ),
        ],
      ),
    );
  }

  Widget _listRow(List<_TmcColumnSpec> specs, TmcModel item, int index) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          for (final col in specs)
            col.flex
                ? Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: col.cell(item, index),
                    ),
                  )
                : SizedBox(
                    width: col.width,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: col.cell(item, index),
                      ),
                    ),
                  ),
        ],
      ),
    );
  }

  /// Колонки вкладки «Список»: заголовок и ячейка описаны одной записью,
  /// поэтому рассинхрон «колонки/ячейки» (позиционная сверка DataTable)
  /// невозможен. Порядок: № → Фото → Наименование → остальное.
  List<_TmcColumnSpec> _listColumnSpecs({
    required String typeKey,
    required bool showFormat,
    required bool showGrammage,
    required bool showWeight,
    required bool showNote,
    required bool showReserveColumns,
  }) {
    String fmtNum(num? v, {int frac = 2}) =>
        v == null ? '' : (v is int ? '$v' : (v as double).toStringAsFixed(frac));
    return [
      _TmcColumnSpec(
        label: '№',
        width: 48,
        cell: (item, i) => Text('${i + 1}'),
      ),
      if (widget.enablePhoto)
        _TmcColumnSpec(
          label: 'Фото',
          width: 118,
          cell: (item, i) => Row(mainAxisSize: MainAxisSize.min, children: [
            _photoPreview(item),
            IconButton(
                icon: const Icon(Icons.add_a_photo),
                tooltip: 'Сменить фото',
                onPressed: () => _changePhoto(item)),
          ]),
        ),
      _TmcColumnSpec(
        label: 'Наименование',
        width: 240,
        flex: true,
        cell: (item, i) => Text(item.description),
      ),
      // «Кол-во» — это доступное, а не складское.
      //
      // Складская цифра включает метры и граммы, обещанные конкретным заказам.
      // Сотрудник, который видит её, планирует по количеству, которого у него
      // нет, и списывает чужой резерв. Что именно занято — рядом, в колонке
      // «В резерве»: она кликабельна и показывает, какие заказы держат.
      _TmcColumnSpec(
        label: 'Кол-во',
        width: 90,
        cell: (item, i) => showReserveColumns
            ? FutureBuilder<double>(
                future: _reservedQtyForItem(item, typeKey),
                builder: (context, snapshot) {
                  final reserved = snapshot.data ?? item.reservedQty;
                  final available = item.quantity - reserved;
                  return Text(fmtNum(available < 0 ? 0 : available, frac: 2));
                },
              )
            : Text(fmtNum(item.quantity, frac: 2)),
      ),
      _TmcColumnSpec(
        label: 'Ед.',
        width: 64,
        cell: (item, i) => Text(item.unit),
      ),
      if (showFormat)
        _TmcColumnSpec(
          label: 'Формат',
          width: 90,
          cell: (item, i) => Text(item.format ?? ''),
        ),
      if (showGrammage)
        _TmcColumnSpec(
          label: 'Граммаж',
          width: 90,
          cell: (item, i) => Text(item.grammage ?? ''),
        ),
      if (showWeight)
        _TmcColumnSpec(
          label: 'Вес (кг)',
          width: 80,
          cell: (item, i) => Text(fmtNum(item.weight, frac: 2)),
        ),
      if (showNote)
        _TmcColumnSpec(
          label: 'Заметки',
          width: 160,
          cell: (item, i) => Text(item.note ?? ''),
        ),
      _TmcColumnSpec(
        label: 'Действия',
        width: 244,
        cell: (item, i) => Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
              icon: const Icon(Icons.edit, size: 20),
              tooltip: 'Редактировать',
              onPressed: () => _editItem(item)),
          IconButton(
              icon: const Icon(Icons.add, size: 20),
              tooltip: 'Пополнить',
              onPressed: () => _increase(item)),
          IconButton(
              icon: const Icon(Icons.remove_circle_outline, size: 20),
              tooltip: 'Списать',
              onPressed: () => _writeOff(item)),
          IconButton(
              icon: const Icon(Icons.inventory_2_outlined, size: 20),
              tooltip: 'Инвентаризация',
              onPressed: () => _inventory(item)),
          IconButton(
              icon: const Icon(Icons.delete, size: 20),
              tooltip: 'Удалить',
              onPressed: () => _deleteItem(item)),
        ]),
      ),
      // Отдельная колонка «Доступно» у красок убрана: ровно ту же цифру
      // теперь показывает «Кол-во», и две одинаковые рядом только путали.
      if (showReserveColumns)
        _TmcColumnSpec(
          label: 'В резерве',
          width: 130,
          cell: (item, i) => FutureBuilder<double>(
            future: _reservedQtyForItem(item, typeKey),
            builder: (context, snapshot) {
              final reserved = snapshot.data ?? item.reservedQty;
              final unit = _reserveUnitLabel(item, typeKey);
              final reserveLabel = '${reserved.toStringAsFixed(2)} $unit';
              return TextButton(
                style: ButtonStyle(
                  foregroundColor: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.disabled)
                        ? Colors.red.shade200
                        : Colors.red.shade700,
                  ),
                  overlayColor: WidgetStateProperty.all(
                    Colors.red.withValues(alpha: 0.12),
                  ),
                ),
                onPressed:
                    reserved > 0 ? () => _showReserveDetails(item) : null,
                child: Text(reserveLabel),
              );
            },
          ),
        ),
    ];
  }

  /// Превью фото строки: миниатюра `<имя>_thumb.jpg` из Storage через
  /// диск-кэш (cached_network_image). Если миниатюры ещё нет (бэкофилл не
  /// прошёл) — откат на полноразмерный оригинал, затем на заглушку.
  Widget _photoPreview(TmcModel item) {
    // 1) inline base64 (если вдруг пришёл со строкой)
    Uint8List? bytes;
    try {
      if (item.imageBase64 != null && item.imageBase64!.isNotEmpty) {
        bytes = base64Decode(item.imageBase64!);
      }
    } catch (_) {}
    if (bytes != null && bytes.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        // cacheWidth/Height: декодим превью в ~100px, а не в полном
        // разрешении — full-res декод топил конвейер растеризации.
        child: Image.memory(bytes,
            width: 50,
            height: 50,
            cacheWidth: 100,
            cacheHeight: 100,
            fit: BoxFit.cover),
      );
    }
    final imageUrl = item.imageUrl;
    final thumbUrl = item.thumbUrl;
    if (imageUrl == null || imageUrl.isEmpty || thumbUrl == null) {
      // Фото нет в списочном запросе (image_base64 исключён ради фикса
      // 57014). Полноразмерное фото подгружается лениво в диалоге
      // редактирования (add_entry_dialog), а не в списке.
      return const Icon(Icons.image_not_supported);
    }
    Widget cached(String url, {Widget Function(BuildContext)? onError}) =>
        CachedNetworkImage(
          imageUrl: url,
          width: 50,
          height: 50,
          fit: BoxFit.cover,
          memCacheWidth: 100,
          memCacheHeight: 100,
          errorWidget: (context, _, __) => onError == null
              ? const Icon(Icons.image_not_supported)
              : onError(context),
        );
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: cached(thumbUrl, onError: (_) => cached(imageUrl)),
    );
  }

  /// --- Вкладка «Списания» ---
  Widget _writeoffsTab() {
    final rows = _applyFilterLogs(
        _applyPaperMultiFiltersToLogs(List<_LogRow>.from(_writeoffs)));
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
      const DataColumn(label: Text('Действие')),
    ];

    return Padding(
      padding: const EdgeInsets.all(8),
      child: Card(
        elevation: 2,
        child: rows.isEmpty
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                      heightFactor: 4,
                      child: Text(_emptyLogText('Нет списаний'))),
                  if (_woHasMore)
                    _logsFooter(WarehouseLogAction.writeoff, _writeoffs.length),
                ],
              )
            : _scrollableTable(
                DataTable(
                  columnSpacing: 24,
                  columns: columns,
                  rows: List<DataRow>.generate(rows.length, (i) {
                    final r = rows[i];
                    final isCanceled = r.isCanceled;
                    final cells = <DataCell>[
                      DataCell(_logCellText('${i + 1}', isCanceled)),
                      DataCell(_logCellText(r.description, isCanceled)),
                      DataCell(_logCellText(
                          r.quantity.toStringAsFixed(2), isCanceled)),
                      DataCell(_logCellText(r.unit, isCanceled)),
                      if (showFmt)
                        DataCell(_logCellText(r.format ?? '', isCanceled)),
                      if (showGram)
                        DataCell(_logCellText(r.grammage ?? '', isCanceled)),
                      DataCell(_logCellText(_fmtDate(r.dateIso), isCanceled)),
                      DataCell(_logCellText(r.note ?? '', isCanceled)),
                      DataCell(_logCellText(r.byName ?? '', isCanceled)),
                      DataCell(r.canUndo
                          ? TextButton.icon(
                              onPressed: () => _undoLog(r),
                              icon: const Icon(Icons.undo),
                              label: const Text('Отмена'),
                            )
                          : const SizedBox.shrink()),
                    ];

                    while (cells.length < columns.length) {
                      cells.add(const DataCell(Text('')));
                    }

                    if (cells.length > columns.length) {
                      cells.removeRange(columns.length, cells.length);
                    }

                    return DataRow(
                      color: _logRowColor(isCanceled),
                      cells: cells,
                    );
                  }),
                ),
                vertical: _woVCtl,
                horizontal: _woHCtl,
                footer: _woHasMore
                    ? _logsFooter(WarehouseLogAction.writeoff, _writeoffs.length)
                    : null,
              ),
      ),
    );
  }

  /// --- Вкладка «Приходы» ---
  Widget _arrivalsTab() {
    final rows = _applyFilterLogs(
        _applyPaperMultiFiltersToLogs(List<_LogRow>.from(_arrivals)));
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
      const DataColumn(label: Text('Действие')),
    ];

    return Padding(
      padding: const EdgeInsets.all(8),
      child: Card(
        elevation: 2,
        child: rows.isEmpty
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                      heightFactor: 4,
                      child: Text(_emptyLogText('Нет приходов'))),
                  if (_arrHasMore)
                    _logsFooter(WarehouseLogAction.arrival, _arrivals.length),
                ],
              )
            : _scrollableTable(
                DataTable(
                  columnSpacing: 24,
                  columns: columns,
                  rows: List<DataRow>.generate(rows.length, (i) {
                    final r = rows[i];
                    final isCanceled = r.isCanceled;
                    final cells = <DataCell>[
                      DataCell(_logCellText('${i + 1}', isCanceled)),
                      DataCell(_logCellText(r.description, isCanceled)),
                      DataCell(_logCellText(
                          r.quantity.toStringAsFixed(2), isCanceled)),
                      DataCell(_logCellText(r.unit, isCanceled)),
                      if (showFmt)
                        DataCell(_logCellText(r.format ?? '', isCanceled)),
                      if (showGram)
                        DataCell(_logCellText(r.grammage ?? '', isCanceled)),
                      DataCell(_logCellText(_fmtDate(r.dateIso), isCanceled)),
                      DataCell(_logCellText(r.note ?? '', isCanceled)),
                      DataCell(_logCellText(r.byName ?? '', isCanceled)),
                      DataCell(r.canUndo
                          ? TextButton.icon(
                              onPressed: () => _undoLog(r),
                              icon: const Icon(Icons.undo),
                              label: const Text('Отмена'),
                            )
                          : const SizedBox.shrink()),
                    ];

                    while (cells.length < columns.length) {
                      cells.add(const DataCell(Text('')));
                    }

                    if (cells.length > columns.length) {
                      cells.removeRange(columns.length, cells.length);
                    }

                    return DataRow(
                      color: _logRowColor(isCanceled),
                      cells: cells,
                    );
                  }),
                ),
                vertical: _arrVCtl,
                horizontal: _arrHCtl,
                footer: _arrHasMore
                    ? _logsFooter(WarehouseLogAction.arrival, _arrivals.length)
                    : null,
              ),
      ),
    );
  }

  /// --- Вкладка «Инвентаризация» ---
  Widget _inventoryTab() {
    final rows = _applyFilterLogs(
        _applyPaperMultiFiltersToLogs(List<_LogRow>.from(_inventories)));
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
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                      heightFactor: 4,
                      child: Text(_emptyLogText('Нет инвентаризаций'))),
                  if (_invHasMore)
                    _logsFooter(
                        WarehouseLogAction.inventory, _inventories.length),
                ],
              )
            : _scrollableTable(
                DataTable(
                  columnSpacing: 24,
                  columns: columns,
                  rows: List<DataRow>.generate(rows.length, (i) {
                    final r = rows[i];
                    final isCanceled = r.isCanceled;
                    final cells = <DataCell>[
                      DataCell(_logCellText('${i + 1}', isCanceled)),
                      DataCell(_logCellText(r.description, isCanceled)),
                      DataCell(_logCellText(
                          r.quantity.toStringAsFixed(2), isCanceled)),
                      DataCell(_logCellText(r.unit, isCanceled)),
                      if (showFmt)
                        DataCell(_logCellText(r.format ?? '', isCanceled)),
                      if (showGram)
                        DataCell(_logCellText(r.grammage ?? '', isCanceled)),
                      DataCell(_logCellText(_fmtDate(r.dateIso), isCanceled)),
                      DataCell(_logCellText(r.note ?? '', isCanceled)),
                      DataCell(_logCellText(r.byName ?? '', isCanceled)),
                    ];

                    while (cells.length < columns.length) {
                      cells.add(const DataCell(Text('')));
                    }

                    if (cells.length > columns.length) {
                      cells.removeRange(columns.length, cells.length);
                    }

                    return DataRow(
                      color: _logRowColor(isCanceled),
                      cells: cells,
                    );
                  }),
                ),
                vertical: _invVCtl,
                horizontal: _invHCtl,
                footer: _invHasMore
                    ? _logsFooter(
                        WarehouseLogAction.inventory, _inventories.length)
                    : null,
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
    final unitSuffix = item.unit.trim().isEmpty ? '' : ' (${item.unit})';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Пополнить: ${item.description}'),
        content: TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: 'Сколько добавить$unitSuffix'),
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

  String _paperDetails(TmcModel item) {
    final parts = <String>[];
    final format = (item.format ?? '').trim();
    if (format.isNotEmpty) parts.add(format);
    final grammage = (item.grammage ?? '').trim();
    if (grammage.isNotEmpty) parts.add('$grammage ');
    return parts.join(' • ');
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
    String? diameterColor;
    final nameLow = item.description.toLowerCase();
    if (nameLow.contains('бел')) {
      diameterColor = 'white';
    } else if (nameLow.contains('коричнев')) {
      diameterColor = 'brown';
    }

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
          title: Text(
              'Пополнить бумагу: ${item.description}${_paperDetails(item).isNotEmpty ? ' (${_paperDetails(item)})' : ''}'),
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
                      decoration: const InputDecoration(labelText: 'Грамаж ()'),
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
                      decoration: const InputDecoration(labelText: 'Грамаж ()'),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: diameterColor,
                      items: const [
                        DropdownMenuItem(
                            value: 'white', child: Text('Белая бумага')),
                        DropdownMenuItem(
                            value: 'brown', child: Text('Коричневая бумага')),
                      ],
                      onChanged: (v) => setS(() => diameterColor = v),
                      decoration:
                          const InputDecoration(labelText: 'Тип бумаги'),
                      validator: (v) {
                        if (method == 'diameter' && (v == null || v.isEmpty)) {
                          return 'Выберите тип бумаги';
                        }
                        return null;
                      },
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
      if (diameterColor == null || diameterColor!.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Выберите тип бумаги')));
        }
        return;
      }
      final white = diameterColor == 'white';
      addMeters = _computeFromDiameter(d, format!, grammage!, white) ?? 0;
    }
    if (addMeters <= 0) return;
    final provider = Provider.of<WarehouseProvider>(context, listen: false);
    await provider.addPaperArrival(paperId: item.id, qty: addMeters);
    await _loadAll();
  }

  /// Неприкасаемый запас краски в единицах карточки склада.
  ///
  /// Краски заводятся в граммах ('гр'), но у старых записей встречается 'кг',
  /// и вычитать 5000 из килограммов означало бы запретить списание вообще.
  double _untouchablePaintInItemUnit(TmcModel item) {
    final unit = item.unit.toLowerCase();
    if (unit.contains('кг') || unit.contains('kg')) {
      return kUntouchablePaintGrams / 1000;
    }
    return kUntouchablePaintGrams;
  }

  Future<void> _writeOff(TmcModel item) async {
    final qtyC = TextEditingController();
    final commentC = TextEditingController();
    final unitSuffix = item.unit.trim().isEmpty ? '' : ' (${item.unit})';
    final typeKeyForLimit = _normalizeType(widget.type);
    final isPaper = typeKeyForLimit == 'paper';
    final paperDetails = isPaper ? _paperDetails(item) : '';
    final titleSuffix = paperDetails.isEmpty ? '' : ' ($paperDetails)';

    // Резерв — обещание конкретным заказам, и списать его нельзя: заказ,
    // который уже показан менеджеру как обеспеченный, иначе остаётся без
    // материала на середине маршрута. Поэтому потолок ручного списания —
    // доступное, а не складское.
    final bool reserveAware = _isReserveAwareType(typeKeyForLimit);
    final double reservedQty =
        reserveAware ? await _reservedQtyForItem(item, typeKeyForLimit) : 0;

    // Неприкасаемый запас краски: 5 кг, которые склад держит всегда. Ручное
    // списание их НЕ запирает — запас закрыт только для брони под заказ.
    // Кладовщик распоряжается физической банкой: её отдают в другой цех,
    // проливают, списывают по негодности, и запрет тут не сохранял краску, а
    // расходился с тем, что уже случилось на полке.
    // Из потолка запас поэтому не вычитается — он только показывается, чтобы
    // было видно, с какого числа расходуется неснижаемый остаток.
    final bool isPaintLimit = typeKeyForLimit == 'paint';
    final double untouchableQty =
        isPaintLimit ? _untouchablePaintInItemUnit(item) : 0;

    final double rawAvailable = item.quantity - reservedQty;
    final double availableQty = rawAvailable < 0 ? 0 : rawAvailable;
    // Сколько можно взять, не трогая неснижаемый остаток.
    final double rawFreeAboveReserve = availableQty - untouchableQty;
    final double freeAboveReserve =
        rawFreeAboveReserve < 0 ? 0 : rawFreeAboveReserve;
    final String limitUnit = _reserveUnitLabel(item, typeKeyForLimit);
    if (!mounted) return;

    final result = await showDialog<double?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Списать: ${item.description}$titleSuffix'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: qtyC,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Количество$unitSuffix',
                helperMaxLines: 2,
                helperText: reserveAware
                    ? 'Доступно: ${availableQty.toStringAsFixed(2)} $limitUnit'
                        '${reservedQty > 0 ? ' (в резерве заказов: '
                            '${reservedQty.toStringAsFixed(2)} $limitUnit)' : ''}'
                        '${untouchableQty > 0 ? ' • без запаса: '
                            '${freeAboveReserve.toStringAsFixed(2)} $limitUnit, '
                            'дальше идёт неснижаемый остаток '
                            '${untouchableQty.toStringAsFixed(2)} $limitUnit' : ''}'
                    : null,
              ),
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
    final __t = _normalizeType(widget.type);
    // Бумага и краска: потолок — доступное. Погрешность нужна, потому что
    // метраж хранится double и приходит из разных полей формы.
    if (reserveAware && result > availableQty + 1e-6) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              reservedQty > 0
                  ? 'Нельзя списать больше доступного: '
                      '${availableQty.toStringAsFixed(2)} $limitUnit. '
                      'Ещё ${reservedQty.toStringAsFixed(2)} $limitUnit '
                      'забронировано заказами.'
                  : 'Нельзя списать больше, чем на складе: '
                      '${availableQty.toStringAsFixed(2)} $limitUnit.',
            ),
          ),
        );
      }
      return;
    }
    // Не позволяем списать больше, чем есть (для канцтоваров/ручек)
    if ((__t == 'stationery' || __t == 'pens') && result > item.quantity) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Нельзя списать больше, чем на складе')),
        );
      }
      return;
    }

    final typeKey = _normalizeType(widget.type);
    final unitLabel = isPaper ? 'м' : item.unit;
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
        // Про просевший запас говорим сразу: списание разрешено, но остаток
        // ниже неснижаемого — это уже долг перед следующим заказом, и узнать
        // о нём из карточки склада негде.
        final double left = item.quantity - result;
        final bool reserveBroken = untouchableQty > 0 && left < untouchableQty;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Списано ${result.toStringAsFixed(2)} ${item.unit}'
              '${reserveBroken ? '. Неснижаемый остаток просел: осталось '
                  '${(left < 0 ? 0 : left).toStringAsFixed(2)} ${item.unit} '
                  'из ${untouchableQty.toStringAsFixed(2)} — пополните склад' : ''}',
            ),
            duration: Duration(seconds: reserveBroken ? 6 : 4),
          ),
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
    final weightC = TextEditingController();
    final diameterC = TextEditingController();
    final noteC = TextEditingController();
    final isPaper = _normalizeType(widget.type) == 'paper';
    final paperDetails = isPaper ? _paperDetails(item) : '';
    final titleSuffix = paperDetails.isEmpty ? '' : ' ($paperDetails)';
    String method = 'meters';
    double? format = double.tryParse((item.format ?? '').replaceAll(',', '.'));
    double? grammage =
        double.tryParse((item.grammage ?? '').replaceAll(',', '.'));
    String? diameterColor;
    final nameLow = item.description.toLowerCase();
    if (nameLow.contains('бел')) {
      diameterColor = 'white';
    } else if (nameLow.contains('коричнев')) {
      diameterColor = 'brown';
    }
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
          title: Text('Инвентаризация: ${item.description}$titleSuffix'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isPaper) ...[
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
                    const SizedBox(height: 8),
                  ],
                  if (!isPaper || method == 'meters')
                    TextFormField(
                      controller: qtyC,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                          labelText: 'Фактическое количество'),
                      validator: (v) {
                        final d =
                            double.tryParse((v ?? '').replaceAll(',', '.'));
                        return (d == null || d < 0)
                            ? 'Укажите количество'
                            : null;
                      },
                    ),
                  if (isPaper && method == 'weight') ...[
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
                    const SizedBox(height: 8),
                    TextFormField(
                      initialValue: (item.format ?? ''),
                      onChanged: (v) =>
                          format = double.tryParse(v.replaceAll(',', '.')),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration:
                          const InputDecoration(labelText: 'Формат (см)'),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      initialValue: (item.grammage ?? ''),
                      onChanged: (v) =>
                          grammage = double.tryParse(v.replaceAll(',', '.')),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Грамаж ()'),
                    ),
                  ],
                  if (isPaper && method == 'diameter') ...[
                    TextFormField(
                      controller: diameterC,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Диаметр (см)'),
                      validator: (v) {
                        final d =
                            double.tryParse((v ?? '').replaceAll(',', '.'));
                        return (d == null || d <= 0) ? 'Укажите диаметр' : null;
                      },
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      initialValue: (item.format ?? ''),
                      onChanged: (v) =>
                          format = double.tryParse(v.replaceAll(',', '.')),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration:
                          const InputDecoration(labelText: 'Формат (см)'),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      initialValue: (item.grammage ?? ''),
                      onChanged: (v) =>
                          grammage = double.tryParse(v.replaceAll(',', '.')),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Грамаж ()'),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: diameterColor,
                      items: const [
                        DropdownMenuItem(
                            value: 'white', child: Text('Белая бумага')),
                        DropdownMenuItem(
                            value: 'brown', child: Text('Коричневая бумага')),
                      ],
                      onChanged: (v) => setS(() => diameterColor = v),
                      decoration:
                          const InputDecoration(labelText: 'Тип бумаги'),
                      validator: (v) {
                        if (method == 'diameter' && (v == null || v.isEmpty)) {
                          return 'Выберите тип бумаги';
                        }
                        return null;
                      },
                    ),
                  ],
                  const SizedBox(height: 8),
                  TextField(
                    controller: noteC,
                    decoration: const InputDecoration(
                        labelText: 'Заметка (необязательно)'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Отмена')),
            FilledButton(
                onPressed: () {
                  if (!isPaper || formKey.currentState!.validate()) {
                    Navigator.pop(context, true);
                  }
                },
                child: const Text('Сохранить')),
          ],
        ),
      ),
    );

    if (ok != true) return;
    double? factual = double.tryParse(qtyC.text.replaceAll(',', '.'));
    if (isPaper) {
      if (method == 'weight') {
        if (format == null || format == 0 || grammage == null || grammage == 0) {
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('Укажите формат и грамаж')));
          }
          return;
        }
        final w = double.tryParse(weightC.text.replaceAll(',', '.')) ?? 0;
        factual = _computeFromWeight(w, format!, grammage!);
      } else if (method == 'diameter') {
        if (format == null || format == 0 || grammage == null || grammage == 0) {
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('Укажите формат и грамаж')));
          }
          return;
        }
        final d = double.tryParse(diameterC.text.replaceAll(',', '.')) ?? 0;
        if (diameterColor == null || diameterColor!.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('Выберите тип бумаги')));
          }
          return;
        }
        final white = diameterColor == 'white';
        factual = _computeFromDiameter(d, format!, grammage!, white);
      }
    }

    if (factual == null || factual < 0) return;

    final typeKey = _normalizeType(widget.type);
    final unitLabel = isPaper ? 'м' : item.unit;
    try {
      if (typeKey == 'stationery' || typeKey == 'pens') {
        final provider = Provider.of<WarehouseProvider>(context, listen: false);
        await provider.inventorySet(
          itemId: item.id,
          newQty: factual,
          note: noteC.text.trim().isEmpty ? null : noteC.text.trim(),
        );
      } else if (isJournaledStockType(typeKey)) {
        // Бумага и краска: одна запись журнала с остатком до пересчёта.
        // Раньше здесь остаток переписывался update-ом, а строка
        // инвентаризации вставлялась отдельно и без прежнего остатка —
        // отменить такую инвентаризацию было нечем.
        final provider = Provider.of<WarehouseProvider>(context, listen: false);
        await provider.recordStockCount(
          itemId: item.id,
          type: typeKey,
          quantity: factual,
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
          'factual',
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
                  'Инвентаризация сохранена (${factual.toStringAsFixed(2)} $unitLabel)')),
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
    final reasonC = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Удалить запись?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Будет удалена «${item.description}».'),
            const SizedBox(height: 12),
            TextField(
              controller: reasonC,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Причина удаления (необязательно)',
              ),
            ),
          ],
        ),
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
      final typeKey = _normalizeType(widget.type);
      final entityType = _deletedEntityTypes[typeKey] ?? 'tmc_generic';
      final messenger = ScaffoldMessenger.of(context);

      // Сначала удаление, журнал — после успеха.
      //
      // Раньше запись «удалено» писалась ПЕРВОЙ и при отказе базы не
      // откатывалась: три неудачные попытки удалить занятую бронью краску
      // оставили в «Удалённых записях» три записи о карточке, которая
      // осталась на складе. Журнал врал.
      try {
        await Provider.of<WarehouseProvider>(context, listen: false)
            .deleteTmc(item.id, type: widget.type);
      } on PaintInUseException catch (e) {
        // Отказ законный: краску держит заказ. Раньше он уходил в лог
        // необработанным исключением, а на экране не менялось ничего.
        messenger.showSnackBar(SnackBar(content: Text(e.message)));
        return;
      } catch (e) {
        // Отказ по внешнему ключу переводим на человеческий: сырой
        // PostgrestException не говорит кладовщику ни причины, ни действия.
        final blocked = warehouseDeleteBlockedMessage(e.toString());
        messenger.showSnackBar(
          SnackBar(content: Text(blocked ?? 'Не удалось удалить: $e')),
        );
        return;
      }

      await DeletedRecordsRepository.archive(
        entityType: entityType,
        entityId: item.id,
        payload: item.toMap(),
        reason: reasonC.text.trim().isEmpty ? null : reasonC.text.trim(),
        extra: {'type_key': typeKey},
      );
      await _loadAll();
    }
  }

  /// Уведомления о низком остатке (пока без логики порогов – заглушка, чтобы не падала сборка).
  void _notifyThresholds() {
    // TODO: сюда можно добавить проверку порогов и показ SnackBar/диалога.
    // Метод оставлен пустым намеренно, чтобы убрать ошибку "не определён".
  }

  void _showSnack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Colors.red.shade700 : null,
      ),
    );
  }

  void _setUndoEnabled(String logId, bool enabled) {
    if (!mounted) return;
    setState(() {
      _writeoffs = _writeoffs
          .map((e) => e.id == logId ? e.copyWith(canUndo: enabled) : e)
          .toList();
      _arrivals = _arrivals
          .map((e) => e.id == logId ? e.copyWith(canUndo: enabled) : e)
          .toList();
      _inventories = _inventories
          .map((e) => e.id == logId ? e.copyWith(canUndo: enabled) : e)
          .toList();
    });
  }

  Future<void> _undoLog(_LogRow row) async {
    if ((row.itemId ?? '').isEmpty) {
      _showSnack('Невозможно определить позицию для отмены', error: true);
      return;
    }

    _setUndoEnabled(row.id, false);
    final provider = context.read<WarehouseProvider>();

    try {
      switch (row.action) {
        case WarehouseLogAction.writeoff:
          await provider.cancelWriteoff(
            logId: row.id,
            itemId: row.itemId!,
            qty: row.quantity,
            typeHint: widget.type,
            sourceTable: row.sourceTable,
          );
          _showSnack('Списание отменено');
          break;
        case WarehouseLogAction.arrival:
          await provider.cancelArrival(
            logId: row.id,
            itemId: row.itemId!,
            qty: row.quantity,
            typeHint: widget.type,
            sourceTable: row.sourceTable,
          );
          _showSnack('Приход отменён');
          break;
        case WarehouseLogAction.inventory:
          await provider.cancelInventory(
            logId: row.id,
            itemId: row.itemId!,
            qty: row.quantity,
            typeHint: widget.type,
            sourceTable: row.sourceTable,
          );
          _showSnack('Инвентаризация отменена');
          break;
        default:
          _showSnack('Тип действия не поддерживается', error: true);
      }
      await _loadAll();
    } catch (e) {
      _setUndoEnabled(row.id, true);
      _showSnack(e.toString().replaceFirst('Exception: ', ''), error: true);
    }
  }
}

class _LogRow {
  final String id;
  final String description;
  final double quantity;
  final String unit;
  final String dateIso;

  final String? itemId;
  final String? sourceTable;
  final WarehouseLogAction? action;
  final bool canUndo;
  final bool isCanceled;

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
    this.itemId,
    this.sourceTable,
    this.action,
    this.canUndo = false,
    this.isCanceled = false,
    this.note,
    this.format,
    this.grammage,
    this.byName,
  });

  _LogRow copyWith({bool? canUndo, bool? isCanceled}) {
    return _LogRow(
      id: id,
      description: description,
      quantity: quantity,
      unit: unit,
      dateIso: dateIso,
      itemId: itemId,
      sourceTable: sourceTable,
      action: action,
      canUndo: canUndo ?? this.canUndo,
      isCanceled: isCanceled ?? this.isCanceled,
      note: note,
      format: format,
      grammage: grammage,
      byName: byName,
    );
  }
}

/// Описание колонки вкладки «Список»: заголовок, фиксированная ширина и
/// билдер ячейки в одной записи. Колонка с [flex] растягивается на остаток
/// ширины (Наименование).
class _TmcColumnSpec {
  const _TmcColumnSpec({
    required this.label,
    required this.width,
    required this.cell,
    this.flex = false,
  });

  final String label;
  final double width;
  final bool flex;
  final Widget Function(TmcModel item, int index) cell;
}