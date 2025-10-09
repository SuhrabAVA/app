import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'warehouse_provider.dart';
import 'tmc_model.dart';
import 'add_entry_dialog.dart';

/// Экран, отображающий сводную таблицу всех текущих запасов на складе.
///
/// Позволяет искать по названию/описанию, фильтровать по единице измерения
/// и добавлять новые записи. Также предоставляет действия для редактирования
/// и удаления существующих строк.
class StocksScreen extends StatefulWidget {
  const StocksScreen({super.key});

  @override
  State<StocksScreen> createState() => _StocksScreenState();
}

class _StocksScreenState extends State<StocksScreen> {
  String _searchQuery = '';
  String? _selectedUnit;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<WarehouseProvider>(context, listen: false).fetchTmc();
    });
  }

  void _openAddDialog({TmcModel? existing}) {
    showDialog(
      context: context,
      builder: (_) => AddEntryDialog(
        initialTable: null,
        existing: existing,
      ),
    ).then((_) {
      Provider.of<WarehouseProvider>(context, listen: false).fetchTmc();
    });
  }

  /// Выполняет списание указанного количества для записи из любой таблицы.
  /// Запрашивает количество и комментарий, затем уменьшает количество в складе
  /// и создаёт отдельную запись типа 'Списание'.
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
    }
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
        title: const Text('Запасы'),
      ),
      body: Consumer<WarehouseProvider>(
        builder: (context, provider, _) {
          // Исключаем записи типа 'Списание' из отображения в запасах
          final allStocks =
              provider.allTmc.where((e) => e.type != 'Списание').toList();
          // Собираем уникальные единицы измерения
          final units = <String>{};
          for (final item in allStocks) {
            units.add(item.unit);
          }
          // Фильтруем по поиску и единице измерения
          final filtered = allStocks.where((e) {
            final matchesSearch = _searchQuery.isEmpty ||
                e.description
                    .toLowerCase()
                    .contains(_searchQuery.toLowerCase()) ||
                e.type.toLowerCase().contains(_searchQuery.toLowerCase());
            final matchesUnit =
                _selectedUnit == null || e.unit == _selectedUnit;
            return matchesSearch && matchesUnit;
          }).toList();
          return Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Поисковая строка
                    Expanded(
                      child: TextField(
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.search),
                          hintText: 'Поиск запасов...',
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (val) => setState(() => _searchQuery = val),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Фильтр по единицам измерения
                    DropdownButton<String>(
                      value: _selectedUnit,
                      hint: const Text('Все единицы'),
                      items: [
                        const DropdownMenuItem<String>(
                            value: null, child: Text('Все единицы')),
                        ...units.map((u) =>
                            DropdownMenuItem<String>(value: u, child: Text(u))),
                      ],
                      onChanged: (val) => setState(() => _selectedUnit = val),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: () => _openAddDialog(),
                      icon: const Icon(Icons.add),
                      label: const Text('Добавить запись'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Card(
                    elevation: 2,
                    child: filtered.isEmpty
                        ? const Center(child: Text('Нет данных'))
                        : _scrollableTable(
                            DataTable(
                              columnSpacing: 16,
                              columns: const [
                                DataColumn(label: Text('ID')),
                                DataColumn(label: Text('Наименование')),
                                DataColumn(label: Text('Характеристики')),
                                DataColumn(label: Text('Ед. измерения')),
                                DataColumn(label: Text('Количество')),
                                DataColumn(label: Text('Действия')),
                              ],
                              rows: List<DataRow>.generate(
                                filtered.length,
                                (index) {
                                  final item = filtered[index];
                                  final characteristics = item.supplier ?? '';
                                  return DataRow(cells: [
                                    DataCell(Text('${index + 1}')),
                                    DataCell(Text(item.description)),
                                    DataCell(Text(characteristics.isEmpty
                                        ? '-'
                                        : characteristics)),
                                    DataCell(Text(item.unit)),
                                    DataCell(Text(item.quantity.toString())),
                                    DataCell(Row(
                                      children: [
                                        IconButton(
                                          icon:
                                              const Icon(Icons.edit, size: 20),
                                          onPressed: () =>
                                              _openAddDialog(existing: item),
                                        ),
                                        IconButton(
                                          icon: const Icon(
                                              Icons.remove_circle_outline,
                                              size: 20),
                                          tooltip: 'Списать',
                                          onPressed: () => _writeOffItem(item),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete,
                                              size: 20),
                                          onPressed: () async {
                                            final confirm =
                                                await showDialog<bool>(
                                              context: context,
                                              builder: (ctx) => AlertDialog(
                                                title: const Text(
                                                    'Удалить запись?'),
                                                content: Text(
                                                    'Вы уверены, что хотите удалить ${item.description}?'),
                                                actions: [
                                                  TextButton(
                                                    onPressed: () =>
                                                        Navigator.of(ctx)
                                                            .pop(false),
                                                    child: const Text('Отмена'),
                                                  ),
                                                  TextButton(
                                                    onPressed: () =>
                                                        Navigator.of(ctx)
                                                            .pop(true),
                                                    child:
                                                        const Text('Удалить'),
                                                  ),
                                                ],
                                              ),
                                            );
                                            if (confirm == true) {
                                              await Provider.of<
                                                          WarehouseProvider>(
                                                      context,
                                                      listen: false)
                                                  .deleteTmc(item.id);
                                            }
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
              ],
            ),
          );
        },
      ),
    );
  }
}
