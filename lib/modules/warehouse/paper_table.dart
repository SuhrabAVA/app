import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../warehouse/warehouse_provider.dart';
import '../warehouse/tmc_model.dart';
import '../warehouse/add_entry_dialog.dart';

/// Экран для отображения таблицы прихода бумаги.
/// Данные загружаются из [WarehouseProvider] и выводятся в виде [DataTable]
/// с нумерацией строк, наименованием, количеством и единицей измерения.
class PaperTable extends StatefulWidget {
  const PaperTable({super.key});

  @override
  State<PaperTable> createState() => _PaperTableState();
}

class _PaperTableState extends State<PaperTable> {
  List<TmcModel> _papers = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final provider = Provider.of<WarehouseProvider>(context, listen: false);
    await provider.fetchTmc();
    setState(() {
      _papers = provider.getTmcByType('Бумага');
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Бумага'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _openAddDialog,
          ),
        ],
      ),
      body: _papers.isEmpty
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
                        _papers.length,
                        (index) {
                          final item = _papers[index];
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
    // Открываем диалог добавления записи, ограниченный таблицей "Бумага"
    showDialog(
      context: context,
      builder: (_) => const AddEntryDialog(initialTable: 'Бумага'),
    ).then((_) {
      // После закрытия диалога обновляем данные
      _loadData();
    });
  }
}
