import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../warehouse/warehouse_provider.dart';
import '../warehouse/tmc_model.dart';
import '../warehouse/add_entry_dialog.dart';
import 'dart:convert';

/// Экран для отображения записей типа "Краска".
///
/// Таблица выводит изображение, наименование, вес, единицу измерения
/// и предоставляет действия для редактирования, списания и удаления записей.
class PaintTable extends StatefulWidget {
  const PaintTable({super.key});

  @override
  State<PaintTable> createState() => _PaintTableState();
}

class _PaintTableState extends State<PaintTable> {
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
      _items = provider.getTmcByType('Краска');
    });
  }

  void _openAddDialog() {
    showDialog(
      context: context,
      builder: (_) => const AddEntryDialog(initialTable: 'Краска'),
    ).then((_) => _loadData());
  }

  void _editItem(TmcModel item) {
    showDialog(
      context: context,
      builder: (_) => AddEntryDialog(existing: item),
    ).then((_) => _loadData());
  }

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

  Future<void> _writeOffItem(TmcModel item) async {
    final qtyController = TextEditingController();
    final commentController = TextEditingController();
    final result = await showDialog<double?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Списать ${item.description}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: qtyController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Количество (кг) для списания',
              ),
            ),
            TextField(
              controller: commentController,
              decoration: const InputDecoration(
                labelText: 'Комментарий (необязательно)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () {
              final qty = double.tryParse(qtyController.text);
              Navigator.of(ctx).pop(qty);
            },
            child: const Text('Списать'),
          ),
        ],
      ),
    );
    if (result != null && result > 0) {
      final provider = Provider.of<WarehouseProvider>(context, listen: false);
      final newQty = item.quantity - result;
      if (newQty < 0) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Нельзя списать больше, чем есть на складе'),
        ));
        return;
      }
      await provider.updateTmcQuantity(id: item.id, newQuantity: newQty);
      await provider.addTmc(
        supplier: item.supplier,
        type: 'Списание',
        description: item.description,
        quantity: result,
        unit: item.unit,
        note: commentController.text.trim().isEmpty
            ? null
            : commentController.text.trim(),
        imageUrl: item.imageUrl,
      );
      await _loadData();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Краски'),
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
                      // Увеличиваем высоту строк, чтобы изображения были лучше видны
                      dataRowHeight: 80,
                      headingRowHeight: 56,
                      columns: const [
                        DataColumn(label: Text('№')),
                        DataColumn(label: Text('Фото')),
                        DataColumn(label: Text('Название')),
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
                            DataCell(
                              () {
                                // Сначала пытаемся отобразить изображение из base64,
                                // затем пробуем загрузить по URL, иначе показываем иконку
                                if (item.imageBase64 != null) {
                                  try {
                                    final bytes = base64Decode(item.imageBase64!);
                                    return SizedBox(
                                      width: 60,
                                      height: 60,
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: Image.memory(bytes, fit: BoxFit.cover),
                                      ),
                                    );
                                  } catch (_) {}
                                }
                                if (item.imageUrl != null) {
                                  return SizedBox(
                                    width: 60,
                                    height: 60,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(4),
                                      child: Image.network(item.imageUrl!, fit: BoxFit.cover),
                                    ),
                                  );
                                }
                                return const Icon(Icons.image_not_supported);
                              }(),
                            ),
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
                                  icon: const Icon(Icons.remove_circle_outline, size: 20),
                                  tooltip: 'Списать',
                                  onPressed: () => _writeOffItem(item),
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
    );
  }
}