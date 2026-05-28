import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../warehouse_provider.dart';
import '../tmc_model.dart';
import 'warehouse_table_styles.dart';

/// Экран модуля «Ручки».
class PensPage extends StatefulWidget {
  const PensPage({super.key});

  @override
  State<PensPage> createState() => _PensPageState();
}

class _PensPageState extends State<PensPage>
    with AutomaticKeepAliveClientMixin {
  bool _loading = false;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Жёстко инициируем первичную загрузку, не ждём реального события
    final wh = context.read<WarehouseProvider>();
    wh.setStationeryKey('ручки');
    _loading = true;
    wh.fetchTmc().whenComplete(() {
      if (mounted) setState(() => _loading = false);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    // ВАЖНО: слушаем провайдера, чтобы ребилдиться на notifyListeners()
    final wh = context.watch<WarehouseProvider>();
    // Провайдер нормализует «Ручки/ручки/канцелярия» -> stationery
    List<TmcModel> items = wh.getTmcByType('Ручки');

    final q = _search.text.trim().toLowerCase();
    if (q.isNotEmpty) {
      items = items.where((e) {
        final s = [
          e.description,
          e.unit,
          e.note ?? '',
          e.supplier ?? '',
        ].join(' ').toLowerCase();
        return s.contains(q);
      }).toList(growable: false);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ручки'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: 'Поиск…',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Expanded(
            child: (items.isEmpty && _loading)
                ? const Center(child: CircularProgressIndicator())
                : (items.isEmpty
                    ? const Center(child: Text('Нет данных'))
                    : _PensTable(items: items)),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          // здесь открой свой диалог добавления
          // после закрытия диалога список обновится автоматически через Realtime/notifyListeners
        },
        icon: const Icon(Icons.add),
        label: const Text('Добавить'),
      ),
    );
  }

  // чтобы не перезагружать список при переключении табов (если есть TabBar выше)
  @override
  bool get wantKeepAlive => true;
}

class _PensTable extends StatelessWidget {
  const _PensTable({required this.items});

  final List<TmcModel> items;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: DataTable(
        columnSpacing: 24,
        headingRowHeight: 44,
        dataRowMinHeight: 44,
        dataRowMaxHeight: 60,
        columns: const [
          DataColumn(label: Text('№')),
          DataColumn(label: Text('Наименование')),
          DataColumn(label: Text('Кол-во')),
          DataColumn(label: Text('Ед.')),
          DataColumn(label: Text('Заметки')),
        ],
        rows: [
          for (int i = 0; i < items.length; i++) _row(i + 1, items[i]),
        ],
      ),
    );
  }

  DataRow _row(int index, TmcModel e) {
    String qty;
    try {
      qty = e.quantity.toStringAsFixed(2);
    } catch (_) {
      qty = '${e.quantity}';
    }

    return DataRow(color: warehouseRowHoverColor, cells: [
      DataCell(Text('$index')),
      DataCell(Text(e.description)),
      DataCell(Text(qty)),
      DataCell(Text(e.unit.isEmpty ? 'шт' : e.unit)),
      DataCell(Text(e.note ?? '')),
    ]);
  }
}
