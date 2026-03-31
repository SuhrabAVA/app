import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/auth_helper.dart';
import '../../utils/kostanay_time.dart';
import 'deleted_records_repository.dart';
import 'deleted_records_screen.dart';

class CategoriesHubScreen extends StatefulWidget {
  const CategoriesHubScreen({super.key});
  @override
  State<CategoriesHubScreen> createState() => _CategoriesHubScreenState();
}

class _CategoriesHubScreenState extends State<CategoriesHubScreen> {
  final _sb = Supabase.instance.client;
  bool _loading = true;
  List<Map<String, dynamic>> _items = []; // {id, code, title, has_subtables}

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _ensureAuthed() async {
    final auth = _sb.auth;
    if (auth.currentUser == null) {
      await auth.signInAnonymously();
    }
  }

  String _slug(String s) {
    final base = s.trim().toLowerCase();
    final cleaned = base
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s\-_]', unicode: true), '')
        .replaceAll(RegExp(r'\s+'), '_');
    return cleaned.isEmpty
        ? 'cat_${DateTime.now().millisecondsSinceEpoch}'
        : cleaned;
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    await _ensureAuthed();

    final rows = await _sb.from('warehouse_categories').select();
    _items = ((rows as List?) ?? [])
        .cast<Map<String, dynamic>>()
        .map((r) => {
              'id': r['id'],
              'code': r['code'],
              'title': (r['title'] ?? r['code'] ?? '').toString(),
              'has_subtables': (r['has_subtables'] ?? false) as bool,
            })
        .toList()
      ..sort((a, b) => a['title'].toString().compareTo(b['title'].toString()));

    if (mounted) setState(() => _loading = false);
  }

  Future<void> _addCategoryDialog() async {
    final name = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Новая категория'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration:
                    const InputDecoration(labelText: 'Название категории'),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Отмена')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Добавить')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final title = name.text.trim();
    if (title.isEmpty) return;

    await _sb.from('warehouse_categories').insert({
      'code': _slug(title),
      'title': title,
      'has_subtables': false,
    });
    await _load();
  }

  Future<void> _renameCategory(Map<String, dynamic> it) async {
    final ctrl = TextEditingController(text: it['title'] ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Переименовать категорию'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: 'Новое название'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Сохранить')),
        ],
      ),
    );
    if (ok != true) return;
    final title = ctrl.text.trim();
    if (title.isEmpty) return;

    await _sb.from('warehouse_categories').update({'title': title}).match({
      'id': it['id'],
    });
    await _load();
  }

  Future<void> _deleteCategory(Map<String, dynamic> it) async {
    final reasonC = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Удалить категорию?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Все позиции внутри будут удалены (ON DELETE CASCADE).'),
            const SizedBox(height: 12),
            TextField(
              controller: reasonC,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Причина удаления (необязательно)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true) return;

    await DeletedRecordsRepository.archive(
      entityType: 'category',
      entityId: it['id']?.toString(),
      payload: {
        'id': it['id'],
        'code': it['code'],
        'title': it['title'],
        'has_subtables': it['has_subtables'],
      },
      reason: reasonC.text.trim().isEmpty ? null : reasonC.text.trim(),
    );

    await _sb.from('warehouse_categories').delete().match({
      'id': it['id'],
    });
    await _load();
  }

  void _openDeletedCategories() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const DeletedRecordsScreen(
          entityType: 'category',
          title: 'Удалённые категории',
        ),
      ),
    );
  }

  void _open(Map<String, dynamic> it) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GenericCategoryItemsScreen(
          categoryId: it['id'] as String,
          categoryTitle: (it['title'] ?? '').toString(),
          hasSubtables: (it['has_subtables'] ?? false) as bool,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Категории'),
        actions: [
          IconButton(
              tooltip: 'Удалённые записи',
              onPressed: _openDeletedCategories,
              icon: const Icon(Icons.delete_sweep_outlined)),
          IconButton(
              onPressed: _addCategoryDialog, icon: const Icon(Icons.add)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final it = _items[i];
                final title = (it['title'] ?? '').toString();
                return ListTile(
                  title: Text(title),
                  onTap: () => _open(it),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'rename') _renameCategory(it);
                      if (v == 'delete') _deleteCategory(it);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                          value: 'rename', child: Text('Переименовать')),
                      PopupMenuItem(value: 'delete', child: Text('Удалить')),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

/* ============================================================
   Общий экран позиций категории с тремя вкладками:
   Список / Списания / Инвентаризация
   Таблицы:
   - warehouse_category_items
   - warehouse_category_writeoffs
   - warehouse_category_inventories
   ============================================================ */
class GenericCategoryItemsScreen extends StatefulWidget {
  final String categoryId;
  final String categoryTitle;
  final bool hasSubtables;
  const GenericCategoryItemsScreen({
    super.key,
    required this.categoryId,
    required this.categoryTitle,
    required this.hasSubtables,
  });

  @override
  State<GenericCategoryItemsScreen> createState() =>
      _GenericCategoryItemsScreenState();
}

class _GenericCategoryItemsScreenState extends State<GenericCategoryItemsScreen>
    with SingleTickerProviderStateMixin {
  final _sb = Supabase.instance.client;

  late final TabController _tabs;

  bool _loading = true;

  // items
  List<Map<String, dynamic>> _items =
      []; // id, description, quantity, table_key, size, comment
  // logs
  List<Map<String, dynamic>> _writeoffs =
      []; // id, item_id, qty, reason, created_at
  List<Map<String, dynamic>> _inventories =
      []; // id, item_id, counted_qty, note, created_at

  // subtables
  String? _tableKey;
  List<String> _tableKeys = [];

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

  // ======== loading ========
  Future<void> _loadAll() async {
    setState(() => _loading = true);
    try {
      final itemsRes = await _sb.from('warehouse_category_items').select();
      final allItems = ((itemsRes as List?) ?? []).cast<Map<String, dynamic>>();

      // uniq table_key
      if (widget.hasSubtables) {
        final s = <String>{};
        for (final r in allItems) {
          if (r['category_id']?.toString() == widget.categoryId) {
            final k = (r['table_key'] ?? '').toString();
            if (k.isNotEmpty) s.add(k);
          }
        }
        _tableKeys = s.toList()..sort();
        _tableKey ??= _tableKeys.isNotEmpty ? _tableKeys.first : 'общая';
      }

      // items for this category (+table_key if needed)
      _items = allItems
          .where((r) {
            final sameCat = r['category_id']?.toString() == widget.categoryId;
            if (!sameCat) return false;
            if (widget.hasSubtables) {
              return (r['table_key'] ?? '').toString() == (_tableKey ?? '');
            }
            return true;
          })
          .map((r) => {
                'id': r['id'],
                'description': r['description'],
                'quantity': r['quantity'],
                'table_key': r['table_key'],
                'size': r['size'],
                'comment': r['comment'],
              })
          .toList()
        ..sort((a, b) => (a['description'] ?? '')
            .toString()
            .compareTo((b['description'] ?? '').toString()));

      // load logs
      final wrRes = await _sb.from('warehouse_category_writeoffs').select();
      final invRes = await _sb.from('warehouse_category_inventories').select();
      final itemIds = _items.map((e) => e['id'].toString()).toSet();

      final itemMeta = {
        for (final it in _items) it['id'].toString(): it,
      };

      _writeoffs = ((wrRes as List?) ?? [])
          .cast<Map<String, dynamic>>()
          .where((r) => itemIds.contains(r['item_id']?.toString()))
          .map((r) => {
                'id': r['id'],
                'item_id': r['item_id'],
                'qty': r['qty'],
                'reason': r['reason'],
                'by_name': r['by_name'] ?? r['employee_name'] ?? r['employee'],
                'created_at': r['created_at'],
                'size': r['size'] ?? itemMeta[r['item_id']?.toString()]?['size'],
                'comment': r['comment'] ??
                    r['reason'] ??
                    itemMeta[r['item_id']?.toString()]?['comment'],
              })
          .toList()
        ..sort((a, b) => (b['created_at'] ?? '')
            .toString()
            .compareTo((a['created_at'] ?? '').toString()));

      _inventories = ((invRes as List?) ?? [])
          .cast<Map<String, dynamic>>()
          .where((r) => itemIds.contains(r['item_id']?.toString()))
          .map((r) => {
                'id': r['id'],
                'item_id': r['item_id'],
                'counted_qty': r['counted_qty'],
                'note': r['note'],
                'by_name': r['by_name'] ?? r['employee_name'] ?? r['employee'],
                'created_at': r['created_at'],
                'size': r['size'] ?? itemMeta[r['item_id']?.toString()]?['size'],
                'comment': r['comment'] ??
                    r['note'] ??
                    itemMeta[r['item_id']?.toString()]?['comment'],
              })
          .toList()
        ..sort((a, b) => (b['created_at'] ?? '')
            .toString()
            .compareTo((a['created_at'] ?? '').toString()));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ======== helpers ========
  Map<String, String> get _itemNameById {
    final m = <String, String>{};
    for (final it in _items) {
      m[it['id'].toString()] = (it['description'] ?? '').toString();
    }
    return m;
  }

  String _resolveOperatorName() {
    final raw = (AuthHelper.currentUserName ?? '').trim();
    if (raw.isNotEmpty) return raw;
    return AuthHelper.isTechLeader ? 'Технический лидер' : '—';
  }

  // ======== CRUD: items ========
  Future<void> _addOrEditItem({Map<String, dynamic>? existing}) async {
    final name =
        TextEditingController(text: existing?['description']?.toString() ?? '');
    final qty =
        TextEditingController(text: (existing?['quantity'] ?? 0).toString());
    final size =
        TextEditingController(text: existing?['size']?.toString() ?? '');
    final comment =
        TextEditingController(text: existing?['comment']?.toString() ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title:
            Text(existing == null ? 'Новая позиция' : 'Редактировать позицию'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Название')),
            TextField(
                controller: qty,
                decoration: const InputDecoration(labelText: 'Количество'),
                keyboardType: TextInputType.number),
            TextField(
              controller: size,
              decoration: const InputDecoration(labelText: 'Размер'),
            ),
            TextField(
              controller: comment,
              decoration: const InputDecoration(labelText: 'Комментарий'),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Сохранить')),
        ],
      ),
    );
    if (ok != true) return;

    final sizeText = size.text.trim();
    final commentText = comment.text.trim();

    final payload = {
      'category_id': widget.categoryId,
      'table_key': widget.hasSubtables ? _tableKey : null,
      'description': name.text.trim(),
      'quantity': double.tryParse(qty.text.trim()) ?? 0,
      'size': sizeText.isEmpty ? null : sizeText,
      'comment': commentText.isEmpty ? null : commentText,
    };

    if (existing == null) {
      await _sb.from('warehouse_category_items').insert(payload);
    } else {
      await _sb
          .from('warehouse_category_items')
          .update(payload)
          .match({'id': existing['id']});
    }
    await _loadAll();
  }

  Future<void> _deleteItem(Map<String, dynamic> row) async {
    final id = row['id']?.toString();
    if (id == null) return;
    final reasonC = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Удалить позицию?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Действие нельзя отменить.'),
            const SizedBox(height: 12),
            TextField(
              controller: reasonC,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Причина удаления (необязательно)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true) return;

    final extra = <String, String>{'category_id': widget.categoryId};
    final tableKey = row['table_key']?.toString();
    if (widget.hasSubtables && tableKey != null && tableKey.isNotEmpty) {
      extra['table_key'] = tableKey;
    }

    await DeletedRecordsRepository.archive(
      entityType: 'category_item',
      entityId: id,
      payload: {
        'id': row['id'],
        'description': row['description'],
        'quantity': row['quantity'],
        'table_key': row['table_key'],
        'category_id': widget.categoryId,
      },
      reason: reasonC.text.trim().isEmpty ? null : reasonC.text.trim(),
      extra: extra,
    );

    await _sb.from('warehouse_category_items').delete().match({'id': id});
    await _loadAll();
  }

  void _openDeletedItems() {
    final filters = <String, String>{'category_id': widget.categoryId};
    if (widget.hasSubtables && (_tableKey ?? '').isNotEmpty) {
      filters['table_key'] = _tableKey ?? '';
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DeletedRecordsScreen(
          entityType: 'category_item',
          title: 'Удалённые записи — ${widget.categoryTitle}',
          extraFilters: filters,
        ),
      ),
    );
  }

  // ======== writeoffs (по конкретной позиции) ========
  Future<void> _writeoffItem(String itemId) async {
    final item = _items.firstWhere((e) => e['id'].toString() == itemId,
        orElse: () => {});
    if (item.isEmpty) return;

    final qty = TextEditingController(text: '1');
    final reason = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Списать: ${(item['description'] ?? '').toString()}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: qty,
                decoration: const InputDecoration(labelText: 'Количество'),
                keyboardType: TextInputType.number),
            TextField(
                controller: reason,
                decoration: const InputDecoration(labelText: 'Причина')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Списать')),
        ],
      ),
    );
    if (ok != true) return;

    final q = (double.tryParse(qty.text.trim()) ?? 0).abs();

    final byName = _resolveOperatorName();

    await _sb.from('warehouse_category_writeoffs').insert({
      'item_id': itemId,
      'qty': q,
      'reason': reason.text.trim(),
      'by_name': byName,
      'size': (item['size'] ?? '').toString().trim().isEmpty
          ? null
          : (item['size'] ?? '').toString().trim(),
      'comment': reason.text.trim().isEmpty ? null : reason.text.trim(),
    });

    final newQty = (((item['quantity'] as num?) ?? 0).toDouble() - q);
    await _sb
        .from('warehouse_category_items')
        .update({'quantity': newQty}).match({'id': itemId});

    await _loadAll();
  }

  // ======== inventories (по конкретной позиции) ========
  Future<void> _inventoryItem(String itemId) async {
    final item = _items.firstWhere((e) => e['id'].toString() == itemId,
        orElse: () => {});
    if (item.isEmpty) return;

    final counted =
        TextEditingController(text: ((item['quantity'] ?? 0).toString()));
    final note = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title:
            Text('Инвентаризация: ${(item['description'] ?? '').toString()}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: counted,
                decoration:
                    const InputDecoration(labelText: 'Фактическое количество'),
                keyboardType: TextInputType.number),
            TextField(
                controller: note,
                decoration: const InputDecoration(labelText: 'Примечание')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Сохранить')),
        ],
      ),
    );
    if (ok != true) return;

    final q = (double.tryParse(counted.text.trim()) ?? 0);

    final byName = _resolveOperatorName();

    await _sb.from('warehouse_category_inventories').insert({
      'item_id': itemId,
      'counted_qty': q,
      'note': note.text.trim(),
      'by_name': byName,
      'size': (item['size'] ?? '').toString().trim().isEmpty
          ? null
          : (item['size'] ?? '').toString().trim(),
      'comment': note.text.trim().isEmpty ? null : note.text.trim(),
    });

    await _sb
        .from('warehouse_category_items')
        .update({'quantity': q}).match({'id': itemId});

    await _loadAll();
  }

  // ======== UI helpers ========
  ListTile _itemTile(Map<String, dynamic> r) {
    final id = r['id'].toString();
    final name = (r['description'] ?? '').toString();
    final qty = (r['quantity'] ?? 0).toString();
    final size = (r['size'] ?? '').toString();
    final comment = (r['comment'] ?? '').toString();

    final subtitleParts = <String>['Количество: $qty'];
    if (size.isNotEmpty) subtitleParts.add('Размер: $size');
    if (comment.isNotEmpty) subtitleParts.add(comment);

    return ListTile(
      title: Text(name),
      subtitle: Text(subtitleParts.join('\n')),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Списать',
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: () => _writeoffItem(id),
          ),
          IconButton(
            tooltip: 'Инвентаризация',
            icon: const Icon(Icons.inventory_2_outlined),
            onPressed: () => _inventoryItem(id),
          ),
          IconButton(
            tooltip: 'Редактировать',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => _addOrEditItem(existing: r),
          ),
          IconButton(
            tooltip: 'Удалить',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _deleteItem(r),
          ),
        ],
      ),
      onTap: () => _addOrEditItem(existing: r),
    );
  }

  @override
  Widget build(BuildContext context) {
    final nameById = _itemNameById;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.categoryTitle),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Список'),
            Tab(text: 'Списания'),
            Tab(text: 'Инвентаризация'),
          ],
        ),
        actions: [
          if (widget.hasSubtables) ...[
            DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _tableKey,
                items: (_tableKeys.isEmpty
                        ? <String>[_tableKey ?? 'общая']
                        : _tableKeys)
                    .map((k) => DropdownMenuItem(value: k, child: Text(k)))
                    .toList(),
                onChanged: (v) async {
                  _tableKey = v;
                  await _loadAll();
                  if (mounted) setState(() {});
                },
              ),
            ),
          ],
          IconButton(
            tooltip: 'Удалённые записи',
            onPressed: _openDeletedItems,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
          IconButton(
            tooltip: _tabs.index == 0
                ? 'Добавить позицию'
                : _tabs.index == 1
                    ? 'Новое списание'
                    : 'Новая инвентаризация',
            onPressed: () {
              if (_tabs.index == 0) _addOrEditItem();
              if (_tabs.index == 1) {
                if (_items.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Нет позиций для списания')));
                } else {
                  _writeoffItem(_items.first['id'].toString());
                }
              }
              if (_tabs.index == 2) {
                if (_items.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Нет позиций для инвентаризации')));
                } else {
                  _inventoryItem(_items.first['id'].toString());
                }
              }
            },
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabs,
              children: [
                // ======== Список ========
                ListView.separated(
                  padding: const EdgeInsets.all(8),
                  itemCount: _items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) => _itemTile(_items[i]),
                ),
                // ======== Списания ========
                ListView.separated(
                  padding: const EdgeInsets.all(8),
                  itemCount: _writeoffs.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final r = _writeoffs[i];
                    final title = nameById[r['item_id'].toString()] ?? '—';
                    final qty = (r['qty'] ?? 0).toString();
                    final dtIso = (r['created_at'] ?? '').toString();
                    final dt = formatKostanayTimestamp(dtIso);
                    final size = (r['size'] ?? '').toString();
                    final comment = (r['comment'] ?? '').toString();
                    final by = (r['by_name'] ?? '').toString();
                    final subtitleParts = <String>[];
                    if (dt.trim().isNotEmpty) subtitleParts.add(dt);
                    if (size.isNotEmpty) subtitleParts.add('Размер: $size');
                    if (comment.isNotEmpty) subtitleParts.add('Комментарий: $comment');
                    if (by.isNotEmpty) subtitleParts.add(by);
                    return ListTile(
                      title: Text('$title • −$qty'),
                      subtitle: Text(subtitleParts.join('  •  ')),
                    );
                  },
                ),
                // ======== Инвентаризация ========
                ListView.separated(
                  padding: const EdgeInsets.all(8),
                  itemCount: _inventories.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final r = _inventories[i];
                    final title = nameById[r['item_id'].toString()] ?? '—';
                    final qty = (r['counted_qty'] ?? 0).toString();
                    final dtIso = (r['created_at'] ?? '').toString();
                    final dt = formatKostanayTimestamp(dtIso);
                    final size = (r['size'] ?? '').toString();
                    final comment = (r['comment'] ?? '').toString();
                    final by = (r['by_name'] ?? '').toString();
                    final subtitleParts = <String>[];
                    if (dt.trim().isNotEmpty) subtitleParts.add(dt);
                    if (size.isNotEmpty) subtitleParts.add('Размер: $size');
                    if (comment.isNotEmpty) subtitleParts.add('Комментарий: $comment');
                    if (by.isNotEmpty) subtitleParts.add(by);
                    return ListTile(
                      title: Text('$title • $qty'),
                      subtitle: Text(subtitleParts.join('  •  ')),
                    );
                  },
                ),
              ],
            ),
    );
  }
}
