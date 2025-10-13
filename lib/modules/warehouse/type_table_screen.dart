import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'warehouse_provider.dart';
import 'add_entry_dialog.dart';
import 'tmc_model.dart';

/// Экран для отображения остатков определённого типа ТМЦ.
class TypeTableScreen extends StatefulWidget {
  final String type;
  final String title;

  const TypeTableScreen({super.key, required this.type, required this.title});

  @override
  State<TypeTableScreen> createState() => _TypeTableScreenState();
}

class _TypeTableScreenState extends State<TypeTableScreen> {
  // Храним список ТМЦ выбранного типа, чтобы иметь доступ к идентификатору
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
      _items = provider.getTmcByType(widget.type);
    });
  }

  @override
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
                    // Wrap the DataTable in a horizontal scroll view to allow wide tables to scroll
                    child: _scrollableTable(
                      DataTable(
                        columnSpacing: 24,
                        columns: [
                          const DataColumn(label: Text('№')),
                          const DataColumn(label: Text('Наименование')),
                          const DataColumn(label: Text('Количество')),
                          const DataColumn(label: Text('Ед.')),
                          if (_items.any((i) =>
                              i.format != null && i.format!.trim().isNotEmpty))
                            const DataColumn(label: Text('Формат')),
                          if (_items.any((i) =>
                              i.grammage != null &&
                              i.grammage!.trim().isNotEmpty))
                            const DataColumn(label: Text('Граммаж')),
                          if (_items.any((i) => i.weight != null))
                    const DataColumn(label: Text('Вес (г)')),
                          if (_items.any((i) =>
                              i.note != null && i.note!.trim().isNotEmpty))
                            const DataColumn(label: Text('Заметки')),
                          const DataColumn(label: Text('Действия')),
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
                              if (_items.any((i) =>
                                  i.format != null &&
                                  i.format!.trim().isNotEmpty))
                                DataCell(Text(item.format ?? '')),
                              if (_items.any((i) =>
                                  i.grammage != null &&
                                  i.grammage!.trim().isNotEmpty))
                                DataCell(Text(item.grammage ?? '')),
                              if (_items.any((i) => i.weight != null))
                                DataCell(Text(item.weight?.toString() ?? '')),
                              if (_items.any((i) =>
                                  i.note != null && i.note!.trim().isNotEmpty))
                                DataCell(Text(item.note ?? '')),
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
                                    icon: const Icon(
                                        Icons.remove_circle_outline,
                                        size: 20),
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

  /// Открывает диалог редактирования для выбранной записи.
  void _editItem(TmcModel item) {
    showDialog(
      context: context,
      builder: (_) => AddEntryDialog(existing: item),
    ).then((_) => _loadData());
  }

  /// Выполняет списание указанного количества и записывает отдельную запись
  /// типа 'Списание'. Количество уменьшается на складе.
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

  /// Удаляет запись после подтверждения пользователя.
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
