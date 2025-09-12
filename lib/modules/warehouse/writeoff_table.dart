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
                    // Wrap the DataTable in a horizontal scroll view so that
                    // wide tables are scrollable on smaller screens.
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        columnSpacing: 24,
                        columns: const [
                          DataColumn(label: Text('№')),
                          DataColumn(label: Text('Наименование')),
                          DataColumn(label: Text('Количество')),
                          DataColumn(label: Text('Ед.')),
                          DataColumn(label: Text('Действия')),
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
                              DataCell(Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.edit, size: 20),
                                    tooltip: 'Редактировать',
                                    onPressed: () => _editItem(item),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete, size: 20),
                                    tooltip: 'Удалить',
                                    onPressed: () => _deleteItem(item),
                                  ),
                                ],
                              )),
                            ]);
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

  /// Редактирует существующую запись списания.
  void _editItem(TmcModel item) {
    showDialog(
      context: context,
      builder: (_) => AddEntryDialog(existing: item),
    ).then((_) => _loadData());
  }

  /// Удаляет запись списания после подтверждения.
  Future<void> _deleteItem(TmcModel item) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить запись?'),
        content: Text('Вы уверены, что хотите удалить ${item.description}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      final provider = Provider.of<WarehouseProvider>(context, listen: false);
      await provider.deleteTmc(item.id);
      await _loadData();
    }
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