import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../warehouse/warehouse_provider.dart';
import '../warehouse/tmc_model.dart';
import '../warehouse/add_entry_dialog.dart';

/// Экран для отображения списаний.
/// На данный момент списания сохраняются в список ТМЦ как отдельный тип 'Списание'.
/// Таблица выводит нумерацию, название, количество и единицу измерения.
class WriteOffTable extends StatefulWidget {
  const WriteOffTable({super.key});

  @override
  State<WriteOffTable> createState() => _WriteOffTableState();
}

class _WriteOffTableState extends State<WriteOffTable> {
  List<TmcModel> _items = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final provider = Provider.of<WarehouseProvider>(context, listen: false);
    await provider.fetchTmc();
    setState(() {
      _items = provider.getTmcByType('Списание');
    });
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
      body: _items.isEmpty
          ? const Center(child: Text('Нет данных'))
          : Padding(
              padding: const EdgeInsets.all(8.0),
              child: Card(
                elevation: 2,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(8.0),
                  child: SizedBox(
                    width: double.infinity,
                    child: DataTable(
                      columnSpacing: 24,
                      columns: const [
                        DataColumn(label: Text('№')),
                        DataColumn(label: Text('Наименование')),
                        DataColumn(label: Text('Количество')),
                        DataColumn(label: Text('Ед.')),
                      ],
                      rows: List<DataRow>.generate(
                        _items.length,
                        (index) {
                          final item = _items[index];
                          return DataRow(cells: [
                            DataCell(Text('${index + 1}')),
                            DataCell(Text(item.description)),
                            DataCell(Text(item.quantity.toString())),
                            DataCell(Text(item.unit)),
                          ]);
                        },
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