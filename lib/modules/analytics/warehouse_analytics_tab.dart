import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../utils/kostanay_time.dart';
import '../warehouse/warehouse_table_styles.dart';
import '../warehouse/warehouse_logs_repository.dart';

class WarehouseAnalyticsTab extends StatefulWidget {
  const WarehouseAnalyticsTab({super.key});

  @override
  State<WarehouseAnalyticsTab> createState() => _WarehouseAnalyticsTabState();
}

class _WarehouseAnalyticsTabState extends State<WarehouseAnalyticsTab> {
  final TextEditingController _searchController = TextEditingController();

  Map<String, WarehouseLogsBundle> _bundles = <String, WarehouseLogsBundle>{};
  bool _loading = true;
  String? _error;
  String _selectedType = 'all';
  DateTimeRange? _range;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _loadData();
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Map<String, WarehouseLogsBundle> data =
          await WarehouseLogsRepository.fetchAllBundles();
      if (!mounted) return;
      setState(() {
        _bundles = data;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Не удалось загрузить данные склада';
        _loading = false;
      });
    }
  }

  List<String> _activeTypeKeys() {
    if (_selectedType == 'all') {
      return _bundles.keys.toList();
    }
    return <String>[_selectedType];
  }

  List<WarehouseLogEntry> _entriesForAction(WarehouseLogAction action) {
    final List<WarehouseLogEntry> entries = <WarehouseLogEntry>[];
    for (final String key in _activeTypeKeys()) {
      final WarehouseLogsBundle? bundle = _bundles[key];
      if (bundle == null) continue;
      switch (action) {
        case WarehouseLogAction.arrival:
          entries.addAll(bundle.arrivals);
          break;
        case WarehouseLogAction.writeoff:
          entries.addAll(bundle.writeoffs);
          break;
        case WarehouseLogAction.inventory:
          entries.addAll(bundle.inventories);
          break;
      }
    }
    return _applyFilters(entries);
  }

  List<WarehouseLogEntry> _applyFilters(List<WarehouseLogEntry> source) {
    final String query = _searchController.text.trim().toLowerCase();
    final DateTimeRange? range = _range;
    final List<WarehouseLogEntry> result = <WarehouseLogEntry>[];

    for (final WarehouseLogEntry entry in source) {
      if (range != null) {
        final DateTime? ts = entry.timestamp;
        if (ts != null) {
          final DateTime dayStart = DateTime(range.start.year, range.start.month, range.start.day);
          final DateTime dayEnd =
              DateTime(range.end.year, range.end.month, range.end.day).add(const Duration(days: 1));
          if (ts.isBefore(dayStart) || !ts.isBefore(dayEnd)) {
            continue;
          }
        } else {
          continue;
        }
      }

      if (query.isNotEmpty) {
        final String haystack = <String?>[
          entry.description,
          entry.note,
          entry.byName,
          entry.unit,
          entry.format,
          entry.grammage,
          WarehouseLogsRepository.typeLabel(entry.typeKey),
        ].whereType<String>().map((String e) => e.toLowerCase()).join(' ');
        if (!haystack.contains(query)) {
          continue;
        }
      }
      result.add(entry);
    }

    result.sort((WarehouseLogEntry a, WarehouseLogEntry b) {
      final DateTime? ta = a.timestamp;
      final DateTime? tb = b.timestamp;
      if (ta != null && tb != null) return tb.compareTo(ta);
      if (ta != null) return -1;
      if (tb != null) return 1;
      return b.timestampIso.compareTo(a.timestampIso);
    });

    return result;
  }

  Future<void> _pickRange() async {
    final DateTime now = DateTime.now();
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
      initialDateRange: _range,
    );
    if (picked != null && mounted) {
      setState(() => _range = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _loadData,
              child: const Text('Повторить'),
            ),
          ],
        ),
      );
    }

    final List<WarehouseLogEntry> arrivals =
        _entriesForAction(WarehouseLogAction.arrival);
    final List<WarehouseLogEntry> writeoffs =
        _entriesForAction(WarehouseLogAction.writeoff);
    final List<WarehouseLogEntry> inventories =
        _entriesForAction(WarehouseLogAction.inventory);
    final List<_WarehouseSummaryRow> summary =
        _buildSummary(arrivals, writeoffs);

    return Column(
      children: [
        _buildFilters(),
        _buildSummaryCard(summary),
        Expanded(
          child: DefaultTabController(
            length: 3,
            child: Column(
              children: [
                const TabBar(
                  tabs: [
                    Tab(text: 'Приходы'),
                    Tab(text: 'Списания'),
                    Tab(text: 'Инвентаризация'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _buildLogTable(arrivals, WarehouseLogAction.arrival),
                      _buildLogTable(writeoffs, WarehouseLogAction.writeoff),
                      _buildLogTable(inventories, WarehouseLogAction.inventory),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFilters() {
    final List<DropdownMenuItem<String>> typeItems = <DropdownMenuItem<String>>[
      const DropdownMenuItem<String>(value: 'all', child: Text('Все таблицы')),
      ...WarehouseLogsRepository.supportedTypes.map(
        (String key) => DropdownMenuItem<String>(
          value: key,
          child: Text(WarehouseLogsRepository.typeLabel(key)),
        ),
      ),
    ];

    final String rangeText;
    if (_range == null) {
      rangeText = 'Период';
    } else {
      final DateFormat fmt = DateFormat('dd.MM.yyyy');
      rangeText = '${fmt.format(_range!.start)} - ${fmt.format(_range!.end)}';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          DropdownButton<String>(
            value: _selectedType,
            items: typeItems,
            onChanged: (String? value) {
              if (value == null) return;
              setState(() => _selectedType = value);
            },
          ),
          SizedBox(
            width: 260,
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                labelText: 'Поиск по товару',
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _searchController.clear();
                        },
                        icon: const Icon(Icons.clear),
                      ),
              ),
            ),
          ),
          TextButton.icon(
            onPressed: _pickRange,
            icon: const Icon(Icons.date_range),
            label: Text(rangeText),
          ),
          if (_range != null)
            TextButton(
              onPressed: () => setState(() => _range = null),
              child: const Text('Сбросить период'),
            ),
          IconButton(
            onPressed: _loadData,
            tooltip: 'Обновить данные',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(List<_WarehouseSummaryRow> rows) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: rows.isEmpty
            ? const Text('Нет данных для расчётов по выбранным фильтрам')
            : SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columnSpacing: 24,
                  columns: [
                    const DataColumn(label: Text('№')),
                    if (_selectedType == 'all')
                      const DataColumn(label: Text('Таблица')),
                    const DataColumn(label: Text('Наименование')),
                    const DataColumn(label: Text('Ед.')),
                    const DataColumn(label: Text('Приход')),
                    const DataColumn(label: Text('Списание')),
                    const DataColumn(label: Text('Баланс')),
                  ],
                  rows: List<DataRow>.generate(rows.length, (int index) {
                    final _WarehouseSummaryRow row = rows[index];
                    return DataRow(
                      color: warehouseRowHoverColor,
                      cells: [
                        DataCell(Text('${index + 1}')),
                        if (_selectedType == 'all')
                          DataCell(
                              Text(WarehouseLogsRepository.typeLabel(row.typeKey))),
                        DataCell(Text(row.description)),
                        DataCell(Text(row.unit)),
                        DataCell(Text(_fmtNum(row.arrivalTotal))),
                        DataCell(Text(_fmtNum(row.writeoffTotal))),
                        DataCell(Text(_fmtNum(row.balance))),
                      ],
                    );
                  }),
                ),
              ),
      ),
    );
  }

  Widget _buildLogTable(
    List<WarehouseLogEntry> entries,
    WarehouseLogAction action,
  ) {
    final bool showType = _selectedType == 'all';
    final bool showFormat =
        entries.any((WarehouseLogEntry e) => (e.format ?? '').trim().isNotEmpty);
    final bool showGram =
        entries.any((WarehouseLogEntry e) => (e.grammage ?? '').trim().isNotEmpty);
    final bool showNote =
        entries.any((WarehouseLogEntry e) => (e.note ?? '').trim().isNotEmpty);

    final String emptyText;
    switch (action) {
      case WarehouseLogAction.arrival:
        emptyText = 'Нет приходов';
        break;
      case WarehouseLogAction.writeoff:
        emptyText = 'Нет списаний';
        break;
      case WarehouseLogAction.inventory:
        emptyText = 'Нет инвентаризаций';
        break;
    }

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Card(
        elevation: 2,
        child: entries.isEmpty
            ? Center(heightFactor: 4, child: Text(emptyText))
            : SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SingleChildScrollView(
                  scrollDirection: Axis.vertical,
                  child: DataTable(
                    columnSpacing: 24,
                    columns: [
                      const DataColumn(label: Text('№')),
                      if (showType)
                        const DataColumn(label: Text('Таблица')),
                      const DataColumn(label: Text('Наименование')),
                      const DataColumn(label: Text('Кол-во')),
                      const DataColumn(label: Text('Ед.')),
                      if (showFormat)
                        const DataColumn(label: Text('Формат')),
                      if (showGram)
                        const DataColumn(label: Text('Граммаж')),
                      const DataColumn(label: Text('Дата')),
                      if (showNote)
                        const DataColumn(label: Text('Комментарий')),
                      const DataColumn(label: Text('Сотрудник')),
                    ],
                      rows: List<DataRow>.generate(entries.length, (int index) {
                        final WarehouseLogEntry entry = entries[index];
                        final List<DataCell> cells = <DataCell>[
                          DataCell(Text('${index + 1}')),
                          if (showType)
                            DataCell(
                              Text(WarehouseLogsRepository.typeLabel(entry.typeKey)),
                            ),
                          DataCell(Text(entry.description)),
                          DataCell(Text(_fmtNum(entry.quantity))),
                          DataCell(Text(entry.unit)),
                          if (showFormat)
                            DataCell(Text(entry.format ?? '')),
                          if (showGram)
                            DataCell(Text(entry.grammage ?? '')),
                          DataCell(
                            Text(
                              formatKostanayTimestamp(entry.timestampIso),
                            ),
                          ),
                          if (showNote)
                            DataCell(Text(entry.note ?? '')),
                          DataCell(Text(entry.byName ?? '')),
                        ];
                        return DataRow(
                          color: warehouseRowHoverColor,
                          cells: cells,
                        );
                      }),
                    ),
                  ),
                ),
      ),
    );
  }

  List<_WarehouseSummaryRow> _buildSummary(
    List<WarehouseLogEntry> arrivals,
    List<WarehouseLogEntry> writeoffs,
  ) {
    final Map<String, _WarehouseSummaryRow> map = <String, _WarehouseSummaryRow>{};

    void accumulate(WarehouseLogEntry entry, {required bool isArrival}) {
      final String key = '${entry.typeKey}|${entry.itemId ?? entry.description}';
      final _WarehouseSummaryRow row = map.putIfAbsent(
        key,
        () => _WarehouseSummaryRow(
          typeKey: entry.typeKey,
          description: entry.description,
          unit: entry.unit,
        ),
      );
      if (isArrival) {
        row.arrivalTotal += entry.quantity;
      } else {
        row.writeoffTotal += entry.quantity;
      }
    }

    for (final WarehouseLogEntry entry in arrivals) {
      accumulate(entry, isArrival: true);
    }
    for (final WarehouseLogEntry entry in writeoffs) {
      accumulate(entry, isArrival: false);
    }

    final List<_WarehouseSummaryRow> rows = map.values.toList();
    rows.sort((a, b) => b.totalMovement.compareTo(a.totalMovement));
    return rows;
  }

  String _fmtNum(double value) {
    if (value == value.roundToDouble()) {
      return value.toStringAsFixed(0);
    }
    return value.toStringAsFixed(2);
  }
}

class _WarehouseSummaryRow {
  _WarehouseSummaryRow({
    required this.typeKey,
    required this.description,
    required this.unit,
  });

  final String typeKey;
  final String description;
  final String unit;
  double arrivalTotal = 0;
  double writeoffTotal = 0;

  double get balance => arrivalTotal - writeoffTotal;
  double get totalMovement => arrivalTotal + writeoffTotal;
}
