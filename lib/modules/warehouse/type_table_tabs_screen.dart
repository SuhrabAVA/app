import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'warehouse_provider.dart';
import 'tmc_model.dart';
import 'add_entry_dialog.dart';

/// Универсальный экран для просмотра записей склада заданного типа.
/// Отображает все позиции, позволяет искать, добавлять, редактировать и удалять записи.
/// В подзаголовке каждой строки выводятся время создания/изменения и пороги.
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

class _TypeTableTabsScreenState extends State<TypeTableTabsScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<WarehouseProvider>(context);
    final items = provider.getTmcByType(widget.type).where((e) {
      if (_query.isEmpty) return true;
      final q = _query.toLowerCase();
      return e.description.toLowerCase().contains(q) || (e.note ?? '').toLowerCase().contains(q);
    }).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          
IconButton(
  onPressed: () async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить таблицу?'),
        content: Text('Все записи типа: ' + widget.type + ' будут удалены.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok == true) {
      await Provider.of<WarehouseProvider>(context, listen: false).deleteType(widget.type);
      if (mounted) Navigator.of(context).pop(); // вернуться назад после удаления
    }
  },
  icon: const Icon(Icons.delete_outline),
  tooltip: 'Удалить таблицу',
),
IconButton(
            onPressed: () => _openAddDialog(),
            icon: const Icon(Icons.add),
            tooltip: 'Добавить запись',
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Поиск...',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (ctx, i) {
                final t = items[i];
                final meta = _metaRow(t);
                return ListTile(
                  title: Text(t.description),
                  subtitle: meta.isEmpty ? null : Text(meta),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${t.quantity} ${t.unit}'),
                      const SizedBox(width: 12),
                      IconButton(
                        icon: const Icon(Icons.edit),
                        onPressed: () => _openEditDialog(t),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _delete(t),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openAddDialog(),
        child: const Icon(Icons.add),
      ),
    );
  }

  /// Строит строку с мета-данными: создано/изменено и пороги.
  String _metaRow(TmcModel t) {
    final ct = t.createdAt;
    final ut = t.updatedAt;
    final low = t.lowThreshold;
    final crit = t.criticalThreshold;
    final parts = <String>[];
    if (ct != null && ct.isNotEmpty) parts.add('Создано: $ct');
    if (ut != null && ut.isNotEmpty) parts.add('Изменено: $ut');
    if (low != null) parts.add('Жёлтый ≤ $low');
    if (crit != null) parts.add('Красный ≤ $crit');
    return parts.join(' • ');
  }

  Future<void> _openAddDialog() async {
    await showDialog(
      context: context,
      builder: (_) => AddEntryDialog(initialTable: widget.type),
    );
  }

  Future<void> _openEditDialog(TmcModel item) async {
    await showDialog(
      context: context,
      builder: (_) => AddEntryDialog(initialTable: widget.type, existing: item),
    );
  }

  Future<void> _delete(TmcModel item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить запись?'),
        content: Text(item.description),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok == true) {
      await Provider.of<WarehouseProvider>(context, listen: false).deleteTmc(item.id);
    }
  }
}