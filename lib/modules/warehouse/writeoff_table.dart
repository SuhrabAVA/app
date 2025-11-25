import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../warehouse/warehouse_provider.dart';
import '../warehouse/add_entry_dialog.dart';
import 'warehouse_logs_repository.dart';
import 'warehouse_table_styles.dart';

/// Экран для отображения списаний.
/// На данный момент списания сохраняются в список ТМЦ как отдельный тип 'Списание'.
/// Таблица выводит нумерацию, название, количество и единицу измерения.
class WriteOffTable extends StatefulWidget {
  const WriteOffTable({super.key});

  @override
  State<WriteOffTable> createState() => _WriteOffTableState();
}

class _WriteOffTableState extends State<WriteOffTable> {
  List<_WriteoffRow> _items = [];
  bool _loading = true;
  WarehouseProvider? _provider;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _provider = Provider.of<WarehouseProvider>(context, listen: false)
        ..addListener(_handleProviderUpdate);
      _loadData();
    });
  }

  @override
  void dispose() {
    _provider?.removeListener(_handleProviderUpdate);
    super.dispose();
  }

  void _handleProviderUpdate() {
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);
    try {
      final bundles = await WarehouseLogsRepository.fetchAllBundles();
      final rows = <_WriteoffRow>[];
      for (final bundle in bundles.values) {
        for (final entry in bundle.writeoffs) {
          rows.add(_WriteoffRow(
            description: entry.description,
            quantity: entry.quantity,
            unit: entry.unit,
            typeLabel: WarehouseLogsRepository.typeLabel(bundle.typeKey),
            timestamp: entry.timestamp,
          ));
        }
      }
      rows.sort((a, b) => (b.timestamp ?? DateTime(0))
          .compareTo(a.timestamp ?? DateTime(0)));
      if (mounted) {
        setState(() {
          _items = rows;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Списание'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _openAddDialog,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Card(
          elevation: 2,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _items.isEmpty
                  ? const Center(child: Text('Нет данных'))
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(8.0),
                      child: SizedBox(
                        width: double.infinity,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            columnSpacing: 24,
                            columns: const [
                              DataColumn(label: Text('№')),
                              DataColumn(label: Text('Наименование')),
                              DataColumn(label: Text('Количество')),
                              DataColumn(label: Text('Ед.')),
                              DataColumn(label: Text('Тип')),
                            ],
                            rows: List<DataRow>.generate(
                              _items.length,
                              (index) {
                                final item = _items[index];
                                return DataRow(
                                  color: warehouseRowHoverColor,
                                  cells: [
                                    DataCell(Text('${index + 1}')),
                                    DataCell(Text(item.description)),
                                    DataCell(Text(item.quantity.toString())),
                                    DataCell(Text(item.unit)),
                                    DataCell(Text(item.typeLabel)),
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
        ),
      ),
    );
  }

  void _openAddDialog() {
    // Открываем диалог добавления записи, ограниченный таблицей "Списание"
    showDialog(
      context: context,
      builder: (_) => const AddEntryDialog(initialTable: 'Списание'),
    ).then((_) {
      _loadData();
    });
  }
}

class _WriteoffRow {
  _WriteoffRow({
    required this.description,
    required this.quantity,
    required this.unit,
    required this.typeLabel,
    this.timestamp,
  });

  final String description;
  final double quantity;
  final String unit;
  final String typeLabel;
  final DateTime? timestamp;
}