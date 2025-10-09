import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'tmc_model.dart';
import 'warehouse_provider.dart';

class PaperTable extends StatefulWidget {
  const PaperTable({super.key});

  @override
  State<PaperTable> createState() => _PaperTableState();
}

class _PaperTableState extends State<PaperTable> {
  final TextEditingController _searchController = TextEditingController();

  // ====== SOURCE ======
  List<TmcModel> _papers = [];
  bool _isLoading = false;

  // ====== FILTER STATE ======
  final Set<String> _fltNames = {};
  final Set<String> _fltFormats = {};
  final Set<String> _fltGrammages = {};
  List<String> _allNames = [];
  List<String> _allFormats = [];
  List<String> _allGrammages = [];

  void _rebuildFilterDictionaries() {
    final names = <String>{};
    final formats = <String>{};
    final grammages = <String>{};
    for (final p in _papers) {
      names.add(p.description);
      final f = (p.format ?? '').trim();
      final g = (p.grammage ?? '').trim();
      if (f.isNotEmpty) formats.add(f);
      if (g.isNotEmpty) grammages.add(g);
    }
    _allNames = names.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    _allFormats = formats.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    _allGrammages = grammages.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  List<TmcModel> _applyMultiFilters(List<TmcModel> src) {
    return src.where((e) {
      final okN = _fltNames.isEmpty || _fltNames.contains(e.description);
      final okF = _fltFormats.isEmpty ||
          ((e.format ?? '').isNotEmpty && _fltFormats.contains(e.format));
      final okG = _fltGrammages.isEmpty ||
          ((e.grammage ?? '').isNotEmpty && _fltGrammages.contains(e.grammage));
      return okN && okF && okG;
    }).toList();
  }

  void _openFilters() {
    _rebuildFilterDictionaries();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 16,
          ),
          child: StatefulBuilder(
            builder: (ctx, setSt) {
              Widget chips(List<String> all, Set<String> sel, String title) =>
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        for (final v in all)
                          FilterChip(
                            label: Text(v),
                            selected: sel.contains(v),
                            onSelected: (on) => setSt(() {
                              if (on)
                                sel.add(v);
                              else
                                sel.remove(v);
                            }),
                          ),
                      ]),
                    ],
                  );
              return SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    chips(_allNames, _fltNames, 'Названия'),
                    const SizedBox(height: 12),
                    chips(_allFormats, _fltFormats, 'Форматы'),
                    const SizedBox(height: 12),
                    chips(_allGrammages, _fltGrammages, 'Грамажи'),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton(
                          onPressed: () {
                            setSt(() {
                              _fltNames.clear();
                              _fltFormats.clear();
                              _fltGrammages.clear();
                            });
                          },
                          child: const Text('Сбросить'),
                        ),
                        ElevatedButton(
                          onPressed: () {
                            setState(() {});
                            Navigator.pop(ctx);
                          },
                          child: const Text('Применить'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _loadData();
    _searchController.addListener(() => setState(() {}));
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final provider = context.read<WarehouseProvider>();
    // Тянем только бумагу и сортируем по названию (A→Я) по умолчанию
    _papers = provider.getTmcByType('Бумага')
      ..sort((a, b) =>
          a.description.toLowerCase().compareTo(b.description.toLowerCase()));
    _rebuildFilterDictionaries();
    setState(() => _isLoading = false);
  }

  // ==== ACTIONS (имена совпадают с вашим кодом) ====
  void _editItem(TmcModel item) =>
      context.read<WarehouseProvider>().editItem(context, item);
  void _writeOffItem(TmcModel item) =>
      context.read<WarehouseProvider>().writeOffItem(context, item);
  void _addArrival(TmcModel item) =>
      context.read<WarehouseProvider>().addArrival(context, item);
  void _openInventoryFor(TmcModel item) =>
      context.read<WarehouseProvider>().openInventoryFor(context, item);
  void _deleteItem(TmcModel item) =>
      context.read<WarehouseProvider>().deleteItem(context, item);

  List<DataRow> _buildGroupedRows() {
    // Текстовый поиск
    final q = _searchController.text.toLowerCase();

    // 1) мульти-фильтр
    List<TmcModel> list = _applyMultiFilters(_papers);

    // 2) текстовый поиск
    list = list.where((item) {
      if (q.isEmpty) return true;
      return item.description.toLowerCase().contains(q) ||
          (item.format ?? '').toLowerCase().contains(q) ||
          (item.grammage ?? '').toLowerCase().contains(q) ||
          (item.note ?? '').toLowerCase().contains(q) ||
          item.quantity.toString().toLowerCase().contains(q);
    }).toList();

    // 3) сортировка групп по алфавиту и внутри группы по формату, затем по грамажу
    list.sort((a, b) {
      final byName =
          a.description.toLowerCase().compareTo(b.description.toLowerCase());
      if (byName != 0) return byName;
      final fa = (a.format ?? '').toLowerCase();
      final fb = (b.format ?? '').toLowerCase();
      final byFmt = fa.compareTo(fb);
      if (byFmt != 0) return byFmt;
      final ga = (a.grammage ?? '').toLowerCase();
      final gb = (b.grammage ?? '').toLowerCase();
      return ga.compareTo(gb);
    });

    final rows = <DataRow>[];
    String? currentName;
    int counter = 0;

    for (final item in list) {
      // Заголовок группы
      if (currentName != item.description) {
        currentName = item.description;
        rows.add(
          DataRow(
            cells: const [
              DataCell(Text('')),
              DataCell(Text('')), // заполним ниже
              DataCell(Text('')),
              DataCell(Text('')),
              DataCell(Text('')),
              DataCell(Text('')),
              DataCell(Text('')),
              DataCell(Text('')),
            ],
          ),
        );
        // заменить второй столбец на заголовок (жирный)
        rows[rows.length - 1] = DataRow(
          cells: [
            const DataCell(Text('')),
            DataCell(Text(currentName!,
                style: const TextStyle(fontWeight: FontWeight.w600))),
            const DataCell(Text('')),
            const DataCell(Text('')),
            const DataCell(Text('')),
            const DataCell(Text('')),
            const DataCell(Text('')),
            const DataCell(Text('')),
          ],
        );
      }

      counter++;
      rows.add(
        DataRow(
          cells: [
            DataCell(Text('$counter')), // №
            DataCell(Text(item.description)), // Наименование
            DataCell(Text(item.quantity.toStringAsFixed(2))), // Кол-во
            DataCell(Text(item.unit)), // Ед.
            DataCell(Text(item.format ?? '')), // Формат
            DataCell(Text(item.grammage ?? '')), // Грамаж
            DataCell(Text(item.note ?? '')), // Заметки
            DataCell(Row(
              // Действия
              children: [
                IconButton(
                  icon: const Icon(Icons.edit, size: 20),
                  tooltip: 'Редактировать',
                  onPressed: () => _editItem(item),
                ),
                IconButton(
                  icon: const Icon(Icons.add, size: 20),
                  tooltip: 'Приход',
                  onPressed: () => _addArrival(item),
                ),
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline, size: 20),
                  tooltip: 'Списание',
                  onPressed: () => _writeOffItem(item),
                ),
                IconButton(
                  icon: const Icon(Icons.inventory_2_outlined, size: 20),
                  tooltip: 'Инвентаризация',
                  onPressed: () => _openInventoryFor(item),
                ),
                IconButton(
                  icon: const Icon(Icons.delete, size: 20),
                  tooltip: 'Удалить',
                  onPressed: () => _deleteItem(item),
                ),
              ],
            )),
          ],
        ),
      );
    }

    return rows;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // SEARCH + FILTER BUTTON
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Поиск...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                icon: const Icon(Icons.filter_list),
                tooltip: 'Фильтр',
                onPressed: _openFilters,
              ),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12.0)),
              isDense: true,
            ),
          ),
        ),

        Expanded(
          child: Container(
            margin: const EdgeInsets.all(16.0),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(16),
            ),
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columns: const [
                        DataColumn(label: Text('№')),
                        DataColumn(label: Text('Наименование')),
                        DataColumn(label: Text('Кол-во')),
                        DataColumn(label: Text('Ед.')),
                        DataColumn(label: Text('Формат')),
                        DataColumn(label: Text('Грамаж')),
                        DataColumn(label: Text('Заметки')),
                        DataColumn(label: Text('Действия')),
                      ],
                      rows: _buildGroupedRows(),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}
