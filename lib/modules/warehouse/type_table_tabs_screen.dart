import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';

import 'warehouse_provider.dart';
import 'tmc_model.dart';
import 'add_entry_dialog.dart';

class TypeTableTabsScreen extends StatefulWidget {
  final String type;
  final String title;
  final bool enablePhoto;

  const TypeTableTabsScreen({
    super.key,
    required this.type,
    required this.title,
    this.enablePhoto = false,
  });

  @override
  State<TypeTableTabsScreen> createState() => _TypeTableTabsScreenState();
}

class _TypeTableTabsScreenState extends State<TypeTableTabsScreen> with TickerProviderStateMixin {
  late final TabController _tabs;
  List<TmcModel> _items = [];
  List<TmcModel> _writeoffs = [];
  List<TmcModel> _inventories = [];
  String _sortField = 'date'; // date | quantity
  bool _sortDesc = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _loadAll();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    final provider = Provider.of<WarehouseProvider>(context, listen: false);
    await provider.fetchTmc();
    final items = provider.getTmcByType(widget.type);
    // Логи: используем общий tmc с типами 'Списание' и 'Инвентаризация'
    final allWriteoffs = provider.getTmcByType('Списание');
    final allInventories = provider.getTmcByType('Инвентаризация');
    // Фильтруем по совпадению описания (или примечания) с исходной позицией
    final names = items.map((e) => e.description).toSet();
    setState(() {
      _items = items;
      _writeoffs = allWriteoffs.where((e) => names.contains(e.description)).toList();
      _inventories = allInventories.where((e) => names.contains(e.description)).toList();
    });
  }

  void _resort() {
    int cmpNum(double a, double b) => a.compareTo(b);
    int cmpStr(String a, String b) => a.compareTo(b);
    int cmpDate(String a, String b) => DateTime.parse(a).compareTo(DateTime.parse(b));

    int Function(TmcModel, TmcModel) comparator;
    switch (_sortField) {
      case 'quantity': comparator = (a, b) => cmpNum(a.quantity, b.quantity); break;
      case 'date':
      default: comparator = (a, b) => cmpDate(a.date, b.date); break;
    }
    setState(() {
      _items.sort(comparator);
      _writeoffs.sort(comparator);
      _inventories.sort(comparator);
      if (_sortDesc) {
        _items = _items.reversed.toList();
        _writeoffs = _writeoffs.reversed.toList();
        _inventories = _inventories.reversed.toList();
      }
    });
  }

  List<TmcModel> _applyFilter(List<TmcModel> src) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return src;
    final numVal = double.tryParse(q.replaceAll(',', '.'));
    return src.where((e) {
      final byName = e.description.toLowerCase().contains(q);
      final byQty = numVal != null && e.quantity >= numVal;
      return byName || byQty;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Список'),
            Tab(text: 'Списания'),
            Tab(text: 'Инвентаризация'),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(_sortDesc ? Icons.south : Icons.north),
            tooltip: _sortDesc ? 'По убыванию' : 'По возрастанию',
            onPressed: () { setState(() => _sortDesc = !_sortDesc); _resort(); },
          ),
          PopupMenuButton<String>(
            tooltip: 'Поле сортировки',
            onSelected: (v) { setState(() => _sortField = v); _resort(); },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'date', child: Text('По дате/времени')),
              PopupMenuItem(value: 'quantity', child: Text('По количеству')),
            ],
            icon: const Icon(Icons.sort),
          ),
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () async {
              final text = await showDialog<String?>(
                context: context,
                builder: (_) {
                  final c = TextEditingController(text: _query);
                  return AlertDialog(
                    title: const Text('Поиск'),
                    content: TextField(controller: c, decoration: const InputDecoration(hintText: 'Имя или количество')), 
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Отмена')),
                      FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Искать')),
                    ],
                  );
                },
              );
              if (text != null) setState(() => _query = text);
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadAll,
            tooltip: 'Обновить',
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _listTab(),
          _writeoffsTab(),
          _inventoryTab(),
        ],
      ),
      floatingActionButton: _tabs.index == 0
          ? FloatingActionButton.extended(
              onPressed: _openAddDialog,
              icon: const Icon(Icons.add),
              label: Text('Добавить в "${widget.title}"'),
            )
          : null,
    );
  }

  Widget _listTab() {
    final items = _applyFilter(List<TmcModel>.from(_items));
    if (items.isEmpty) return const Center(child: Text('Нет данных'));
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Card(
        elevation: 2,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(8),
          child: DataTable(
            columnSpacing: 24,
            columns: [
              const DataColumn(label: Text('№')),
              const DataColumn(label: Text('Наименование')),
              const DataColumn(label: Text('Кол-во')),
              const DataColumn(label: Text('Ед.')),
              if (widget.enablePhoto) const DataColumn(label: Text('Фото')),
              const DataColumn(label: Text('Действия')),
            ],
            rows: List<DataRow>.generate(
              items.length,
              (i) {
                final item = items[i];
                return DataRow(cells: [
                  DataCell(Text('${i + 1}')),
                  DataCell(Text(item.description)),
                  DataCell(Text(item.quantity.toString())),
                  DataCell(Text(item.unit)),
                  if (widget.enablePhoto)
                    DataCell(IconButton(
                      icon: const Icon(Icons.add_a_photo),
                      tooltip: 'Сменить фото',
                      onPressed: () => _changePhoto(item),
                    )),
                  DataCell(Row(children: [
                    IconButton(
                      icon: const Icon(Icons.edit, size: 20),
                      tooltip: 'Редактировать',
                      onPressed: () => _editItem(item),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add, size: 20),
                      tooltip: 'Пополнить',
                      onPressed: () => _increase(item),
                    ),
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline, size: 20),
                      tooltip: 'Списать',
                      onPressed: () => _writeOff(item),
                    ),
                    IconButton(
                      icon: const Icon(Icons.inventory_2_outlined, size: 20),
                      tooltip: 'Инвентаризация',
                      onPressed: () => _inventory(item),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete, size: 20),
                      tooltip: 'Удалить',
                      onPressed: () => _deleteItem(item),
                    ),
                  ])),
                ]);
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _writeoffsTab() {
    final rows = _applyFilter(List<TmcModel>.from(_writeoffs));
    if (rows.isEmpty) return const Center(child: Text('Нет списаний'));
    return _logTable(rows, title: 'Списано');
  }

  Widget _inventoryTab() {
    final rows = _applyFilter(List<TmcModel>.from(_inventories));
    if (rows.isEmpty) return const Center(child: Text('Нет инвентаризаций'));
    return _logTable(rows, title: 'Факт. кол-во');
  }

  Widget _logTable(List<TmcModel> rows, {required String title}) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Card(
        elevation: 2,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(8),
          child: DataTable(
            columnSpacing: 24,
            columns: const [
              DataColumn(label: Text('№')),
              DataColumn(label: Text('Наименование')),
              DataColumn(label: Text('Кол-во')),
              DataColumn(label: Text('Ед.')),
              DataColumn(label: Text('Дата')),
              DataColumn(label: Text('Комментарий')),
            ],
            rows: List<DataRow>.generate(
              rows.length,
              (i) {
                final r = rows[i];
                return DataRow(cells: [
                  DataCell(Text('${i + 1}')),
                  DataCell(Text(r.description)),
                  DataCell(Text(r.quantity.toString())),
                  DataCell(Text(r.unit)),
                  DataCell(Text(_fmtDate(r.date))),
                  DataCell(Text(r.note ?? '')),
                ]);
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openAddDialog() async {
    await showDialog(
      context: context,
      builder: (_) => AddEntryDialog(initialTable: widget.type),
    );
    await _loadAll();
  }

  Future<void> _editItem(TmcModel item) async {
    await showDialog(context: context, builder: (_) => AddEntryDialog(existing: item));
    await _loadAll();
  }

  Future<void> _deleteItem(TmcModel item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить запись?'),
        content: Text('Вы уверены, что хотите удалить ${item.description}?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok == true) {
      final provider = Provider.of<WarehouseProvider>(context, listen: false);
      await provider.deleteTmc(item.id);
      await _loadAll();
    }
  }

  Future<void> _increase(TmcModel item) async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Пополнить: ${item.description}'),
        content: TextField(controller: c, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Сколько добавить')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Добавить')),
        ],
      ),
    );
    if (ok == true) {
      final v = double.tryParse(c.text.replaceAll(',', '.')) ?? 0;
      if (v <= 0) return;
      final provider = Provider.of<WarehouseProvider>(context, listen: false);
      await provider.updateTmcQuantity(id: item.id, newQuantity: item.quantity + v);
      await _loadAll();
    }
  }

  Future<void> _writeOff(TmcModel item) async {
    final qtyC = TextEditingController();
    final commentC = TextEditingController();
    final result = await showDialog<double?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Списать: ${item.description}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: qtyC, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Количество')),
          const SizedBox(height: 8),
          TextField(controller: commentC, decoration: const InputDecoration(labelText: 'Комментарий (необязательно)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('Отмена')),
          TextButton(onPressed: () { final v = double.tryParse(qtyC.text); Navigator.of(ctx).pop(v); }, child: const Text('Списать')),
        ],
      ),
    );
    if (result != null && result > 0) {
      final provider = Provider.of<WarehouseProvider>(context, listen: false);
      final newQty = item.quantity - result;
      if (newQty < 0) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Нельзя списать больше, чем есть')));
        return;
      }
      await provider.updateTmcQuantity(id: item.id, newQuantity: newQty);
      await provider.addTmc(
        supplier: item.supplier,
        type: 'Списание',
        description: item.description,
        quantity: result,
        unit: item.unit,
        note: commentC.text.trim().isEmpty ? null : commentC.text.trim(),
        imageUrl: item.imageUrl,
      );
      await _loadAll();
    }
  }

  Future<void> _inventory(TmcModel item) async {
    final qtyC = TextEditingController(text: item.quantity.toString());
    final noteC = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Инвентаризация: ${item.description}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: qtyC, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Фактическое количество')),
          const SizedBox(height: 8),
          TextField(controller: noteC, decoration: const InputDecoration(labelText: 'Заметка (необязательно)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Сохранить')),
        ],
      ),
    );
    if (ok == true) {
      final newQty = double.tryParse(qtyC.text.replaceAll(',', '.'));
      if (newQty == null || newQty < 0) return;
      final provider = Provider.of<WarehouseProvider>(context, listen: false);
      final delta = newQty - item.quantity;
      await provider.updateTmcQuantity(id: item.id, newQuantity: newQty);
      await provider.addTmc(
        supplier: item.supplier,
        type: 'Инвентаризация',
        description: item.description,
        quantity: newQty,
        unit: item.unit,
        note: noteC.text.trim().isEmpty ? 'delta: ${delta.toStringAsFixed(2)}' : '${noteC.text.trim()} • delta: ${delta.toStringAsFixed(2)}',
        imageUrl: item.imageUrl,
      );
      await _loadAll();
    }
  }

  Future<void> _changePhoto(TmcModel item) async {
    final picker = ImagePicker();
    final src = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(leading: const Icon(Icons.photo), title: const Text('Галерея'), onTap: () => Navigator.pop(context, ImageSource.gallery)),
            ListTile(leading: const Icon(Icons.photo_camera), title: const Text('Камера'), onTap: () => Navigator.pop(context, ImageSource.camera)),
          ],
        ),
      ),
    );
    if (src == null) return;
    final xf = await picker.pickImage(source: src, imageQuality: 80, maxWidth: 2000);
    if (xf == null) return;
    final bytes = await xf.readAsBytes();
    final provider = Provider.of<WarehouseProvider>(context, listen: false);
    await provider.updateTmc(id: item.id, imageBytes: bytes);
    await _loadAll();
  }
}

String _fmtDate(String iso) {
  try {
    final dt = DateTime.tryParse(iso) ?? DateTime.now();
    return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')} '
           '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  } catch (_) {
    return iso;
  }
}
