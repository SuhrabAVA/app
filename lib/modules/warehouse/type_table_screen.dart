import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'warehouse_provider.dart';
import 'add_entry_dialog.dart';

/// Экран для отображения остатков определённого типа ТМЦ.
class TypeTableScreen extends StatefulWidget {
  final String type;
  final String title;

  const TypeTableScreen({super.key, required this.type, required this.title});

  @override
  State<TypeTableScreen> createState() => _TypeTableScreenState();
}

class _TypeTableScreenState extends State<TypeTableScreen> {
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
  final provider = Provider.of<WarehouseProvider>(context, listen: false);
  await provider.fetchTmc();
  setState(() {
    _items = provider.getTmcByType(widget.type).map((e) => {
      'description': e.description,
      'quantity': e.quantity,
      'unit': e.unit,
    }).toList();
  });
}

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
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
                            DataCell(Text(item['description'] ?? '')),
                            DataCell(Text(item['quantity'].toString())),
                            DataCell(Text(item['unit'] ?? '')),
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
    // Открываем диалог добавления записи, ограниченный текущей таблицей
    showDialog(
      context: context,
      builder: (_) => AddEntryDialog(initialTable: widget.type),
    ).then((_) {
      _loadData();
    });
  }
}