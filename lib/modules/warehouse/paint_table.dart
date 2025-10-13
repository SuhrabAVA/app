import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../warehouse/warehouse_provider.dart';
import '../warehouse/tmc_model.dart';
import '../warehouse/add_entry_dialog.dart';
import 'tmc_history_screen.dart';
import '../../utils/media_viewer.dart';
import 'dart:convert';
import 'dart:typed_data';

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
  // Контроллер для поиска
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

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
              decoration: InputDecoration(
                labelText: 'Количество (${item.unit}) для списания',
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
          // Кнопка истории изменений
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'История',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => TmcHistoryScreen(type: 'Краска'),
                ),
              );
            },
          ),
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Поле поиска
                        TextField(
                          controller: _searchController,
                          decoration: InputDecoration(
                            hintText: 'Поиск…',
                            prefixIcon: const Icon(Icons.search),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 12),
                        // Wrap the DataTable in a horizontal scroll view so that
                        // wide tables are scrollable on small screens.
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            columnSpacing: 24,
                            // Increase row heights so images are clearly visible
                            dataRowHeight: 140,
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
                              _items
                                  .where((item) {
                                    final query =
                                        _searchController.text.toLowerCase();
                                    if (query.isEmpty) return true;
                                    return item.description
                                            .toLowerCase()
                                            .contains(query) ||
                                        item.unit
                                            .toLowerCase()
                                            .contains(query) ||
                                        item.quantity
                                            .toString()
                                            .toLowerCase()
                                            .contains(query);
                                  })
                                  .toList()
                                  .length,
                              (rowIndex) {
                                final filtered = _items.where((item) {
                                  final query =
                                      _searchController.text.toLowerCase();
                                  if (query.isEmpty) return true;
                                  return item.description
                                          .toLowerCase()
                                          .contains(query) ||
                                      item.unit.toLowerCase().contains(query) ||
                                      item.quantity
                                          .toString()
                                          .toLowerCase()
                                          .contains(query);
                                }).toList();
                                final item = filtered[rowIndex];
                                return DataRow(cells: [
                                  DataCell(Text('${rowIndex + 1}')),
                                  Builder(builder: (context) {
                                    Uint8List? decodedBytes;
                                    if (item.imageBase64 != null) {
                                      try {
                                        decodedBytes =
                                            base64Decode(item.imageBase64!);
                                      } catch (_) {
                                        decodedBytes = null;
                                      }
                                    }
                                    final Uint8List? previewBytes =
                                        decodedBytes;
                                    final String imageUrl = item.imageUrl ?? '';
                                    final bool hasBytes =
                                        previewBytes != null &&
                                            previewBytes.isNotEmpty;
                                    final bool hasUrl = imageUrl.isNotEmpty;

                                    final Widget preview;
                                    if (hasBytes) {
                                      preview = ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: Image.memory(
                                          previewBytes!,
                                          width: 110,
                                          height: 110,
                                          fit: BoxFit.cover,
                                        ),
                                      );
                                    } else if (hasUrl) {
                                      preview = ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: Image.network(
                                          imageUrl,
                                          width: 110,
                                          height: 110,
                                          fit: BoxFit.cover,
                                        ),
                                      );
                                    } else {
                                      preview =
                                          const Icon(Icons.image_not_supported);
                                    }

                                    return DataCell(
                                      preview,
                                      onTap: (!hasBytes && !hasUrl)
                                          ? null
                                          : () {
                                              if (hasBytes) {
                                                showImagePreview(
                                                  context,
                                                  bytes: previewBytes,
                                                  title: item.description,
                                                );
                                              } else if (hasUrl) {
                                                showImagePreview(
                                                  context,
                                                  imageUrl: imageUrl,
                                                  title: item.description,
                                                );
                                              }
                                            },
                                    );
                                  }),
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
                                        icon: const Icon(
                                            Icons.remove_circle_outline,
                                            size: 20),
                                        tooltip: 'Списать',
                                        onPressed: () => _writeOffItem(item),
                                      ),
                                      IconButton(
                                        icon:
                                            const Icon(Icons.delete, size: 20),
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
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
