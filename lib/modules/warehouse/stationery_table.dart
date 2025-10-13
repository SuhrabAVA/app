import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../warehouse/warehouse_provider.dart';
import '../warehouse/tmc_model.dart';
import '../warehouse/add_entry_dialog.dart';
import 'tmc_history_screen.dart';
import 'deleted_records_modal.dart';

/// Экран для отображения канцелярских товаров.
/// Использует [DataTable] для отображения прихода с нумерацией строк,
/// наименованием, количеством и единицей измерения.
class StationeryTable extends StatefulWidget {
  const StationeryTable({super.key});

  @override
  State<StationeryTable> createState() => _StationeryTableState();
}

class _StationeryTableState extends State<StationeryTable> {
  bool _loading = false;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // ВАЖНО: для модуля "Ручки" сразу выставляем table_key='ручки' и жёстко грузим данные
    final p = Provider.of<WarehouseProvider>(context, listen: false);
    p.setStationeryKey('канцелярия');
    _loading = true;
    p.fetchTmc().whenComplete(() {
      if (mounted) setState(() => _loading = false);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WarehouseProvider>();

    // Берём список напрямую из провайдера (это важно для авто-обновления).
    final all = provider.getTmcByType('Канцелярия');

    // Поиск по описанию/количеству/ед.
    final q = _searchController.text.trim().toLowerCase();
    final items = q.isEmpty
        ? all
        : all.where((item) {
            return item.description.toLowerCase().contains(q) ||
                item.quantity.toString().toLowerCase().contains(q) ||
                item.unit.toLowerCase().contains(q);
          }).toList();

    // Уберём вложенные тернарники — так надёжнее и понятнее.
    Widget bodyChild;
    if (_loading && items.isEmpty) {
      bodyChild = const Center(child: CircularProgressIndicator());
    } else if (items.isEmpty) {
      bodyChild = const Center(child: Text('Нет данных'));
    } else {
      bodyChild = Padding(
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
                  // Горизонтальный скролл для узких экранов.
                  SingleChildScrollView(
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
                        items.length,
                        (rowIndex) {
                          final item = items[rowIndex];
                          return DataRow(
                            cells: [
                              DataCell(Text('${rowIndex + 1}')),
                              DataCell(Text(item.description)),
                              DataCell(Text(item.quantity.toString())),
                              DataCell(
                                  Text(item.unit.isEmpty ? 'шт' : item.unit)),
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
                                    icon: const Icon(Icons.delete, size: 20),
                                    tooltip: 'Удалить',
                                    onPressed: () => _deleteItem(item),
                                  ),
                                ],
                              )),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Канцелярия'),
        actions: [
          TextButton(
            onPressed: _openDeletedRecords,
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            child: const Text('Удаленные записи'),
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'История',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const TmcHistoryScreen(type: 'Канцелярия'),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Добавить',
            onPressed: _openAddDialog,
          ),
        ],
      ),
      body: bodyChild,
    );
  }

  void _openAddDialog() {
    // Открываем диалог добавления записи сразу для «Канцелярия»
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AddEntryDialog(initialTable: 'Канцелярия'),
    ).then((_) {
      // На случай, если realtime ещё не пришёл — дёрнем ручную синхронизацию.
      Provider.of<WarehouseProvider>(context, listen: false).fetchTmc();
    });
  }

  Future<void> _openDeletedRecords() async {
    final provider = context.read<WarehouseProvider>();
    final entityType = provider.deletionEntityTypeFor('Канцелярия');
    await showDeletedRecordsModal(
      context: context,
      title: 'Удаленные записи — Канцелярия',
      loader: () => provider.fetchDeletedRecords(entityType: entityType),
    );
  }

  /// Редактирует существующий элемент канцелярии.
  void _editItem(TmcModel item) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AddEntryDialog(existing: item),
    ).then((_) {
      Provider.of<WarehouseProvider>(context, listen: false).fetchTmc();
    });
  }

  /// Выполняет списание указанного количества и записывает отдельную запись о списании.
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
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Количество для списания',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: commentController,
              decoration: const InputDecoration(
                labelText: 'Комментарий (необязательно)',
                border: OutlineInputBorder(),
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
              // поддержка ввода с запятой
              final qty =
                  double.tryParse(qtyController.text.replaceAll(',', '.'));
              Navigator.of(ctx).pop(qty);
            },
            child: const Text('Списать'),
          ),
        ],
      ),
    );

    if (result == null || result <= 0) return;

    final provider = Provider.of<WarehouseProvider>(context, listen: false);
    final newQty = item.quantity - result;
    if (newQty < 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Нельзя списать больше, чем есть на складе')),
      );
      return;
    }

    try {
      await provider.writeOff(
        type: 'stationery',
        itemId: item.id,
        qty: result,
        note: commentController.text.trim().isEmpty
            ? null
            : commentController.text.trim(),
      );
      // Обновим, если realtime ещё не прилетел
      await provider.fetchTmc();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Списание сохранено')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка списания: $e')),
      );
    }
  }

  /// Удаляет выбранную запись из канцелярии после подтверждения.
  Future<void> _deleteItem(TmcModel item) async {
    final reasonC = TextEditingController();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить запись?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Вы уверены, что хотите удалить ${item.description}?'),
            const SizedBox(height: 12),
            TextField(
              controller: reasonC,
              decoration: const InputDecoration(
                labelText: 'Причина удаления (необязательно)',
              ),
            ),
          ],
        ),
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

    if (confirm != true) return;

    final provider = Provider.of<WarehouseProvider>(context, listen: false);
    final reason = reasonC.text.trim();
    await provider.deleteTmc(
      item.id,
      type: 'stationery',
      reason: reason.isEmpty ? null : reason,
    );
    await provider.fetchTmc();
  }
}
