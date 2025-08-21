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
                        DataColumn(label: Text('Формат')),
                        DataColumn(label: Text('Грамаж')),
                        DataColumn(label: Text('Вес')),
                        DataColumn(label: Text('Количество')),
                        DataColumn(label: Text('Ед.')),
                        DataColumn(label: Text('Действия')),
                      ],
                      rows: List<DataRow>.generate(
                        _papers.length,
                        (index) {
                          final item = _papers[index];
                          return DataRow(cells: [
                            DataCell(Text('${index + 1}')),
                            DataCell(Text(item.description)),
                            DataCell(Text(item.format ?? '')),
                            DataCell(Text(item.grammage ?? '')),
                            DataCell(Text(item.weight?.toString() ?? '')),
                            DataCell(Text(item.quantity.toString())),
                            DataCell(Text(item.unit)),
                            DataCell(Row(
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit, size: 20),
                                  tooltip: 'Редактировать',
                                  onPressed: () {
                                    _editItem(item);
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.remove_circle_outline, size: 20),
                                  tooltip: 'Списать',
                                  onPressed: () {
                                    _writeOffItem(item);
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete, size: 20),
                                  tooltip: 'Удалить',
                                  onPressed: () {
                                    _deleteItem(item);
                                  },
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

  /// Открывает диалог редактирования существующей записи.
  void _editItem(TmcModel item) {
    showDialog(
      context: context,
      builder: (_) => AddEntryDialog(existing: item),
    ).then((_) {
      _loadData();
    });
  }

  /// Запрашивает количество для списания и выполняет списание.
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
                labelText: 'Количество для списания',
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
        // Предотвращаем списание больше остатка
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Нельзя списать больше, чем есть на складе'),
        ));
        return;
      }
      // Обновляем количество у исходного ТМЦ
      await provider.updateTmcQuantity(id: item.id, newQuantity: newQty);
      // Записываем отдельную запись о списании (не влияет на запасы)
      await provider.addTmc(
        supplier: item.supplier,
        type: 'Списание',
        description: item.description,
        quantity: result,
        unit: item.unit,
        note: commentController.text.trim().isEmpty
            ? null
            : commentController.text.trim(),
      );
      // Обновляем локальные данные
      await _loadData();
    }
  }

  /// Удаляет выбранную запись после подтверждения пользователя.
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
}
