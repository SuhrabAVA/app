import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:provider/provider.dart';

import '../../services/doc_db.dart';
import 'warehouse_provider.dart';

import 'type_table_tabs_screen.dart';

/// Хаб категорий склада.
/// Здесь отображаются как стандартные категории (Бумага, Канцелярия, Краска),
/// так и пользовательские типы, созданные администратором.
/// Пользователь может добавлять новые «таблицы» (типы) — достаточно указать название.
class CategoriesHubScreen extends StatefulWidget {
  const CategoriesHubScreen({super.key});

  @override
  State<CategoriesHubScreen> createState() => _CategoriesHubScreenState();
}

class _CategoriesHubScreenState extends State<CategoriesHubScreen> {
  final DocDB _db = DocDB();
  late Future<List<String>> _typesFuture;

  @override
  void initState() {
    super.initState();
    _typesFuture = _loadCustomTypes();
  }

  /// Удаляет пользовательский тип (таблицу) из коллекции `warehouse_types` и
  /// удаляет все связанные записи TMC через [[WarehouseProvider.deleteType]].
  Future<void> _deleteType(String type) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить таблицу?'),
        content: Text(
            'Все записи типа: "$type" будут удалены безвозвратно. Вы уверены?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      // Находим документы с данным названием и удаляем их
      final rows = await _db.whereEq('warehouse_types', 'name', type);
      for (final row in rows) {
        final rid = row['id'] as String?;
        if (rid != null) await _db.deleteById(rid);
      }
      // Удаляем все записи склада данного типа через provider
      if (mounted) {
        final provider = context.read<WarehouseProvider>();
        await provider.deleteType(type);
      }
      if (mounted) {
        setState(() {
          _typesFuture = _loadCustomTypes();
        });
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Таблица "$type" удалена')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }

  /// Загружает список пользовательских типов из коллекции `warehouse_types` в documents.
  Future<List<String>> _loadCustomTypes() async {
    final rows = await _db.list('warehouse_types');
    final names = <String>[];
    for (final row in rows) {
      final data = row['data'] as Map<String, dynamic>?;
      final name = data?['name'];
      if (name is String) {
        names.add(name);
      }
    }
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names;
  }

  /// Показывает диалог создания нового типа и сохраняет его.
  Future<void> _createTypeDialog() async {
    final c = TextEditingController();
    final res = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Новая таблица (тип)'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Название таблицы',
            hintText: 'Например: Упаковка, Вкладыши, Тесьма...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Создать')),
        ],
      ),
    );
    final name = (res ?? '').trim();
    if (name.isEmpty) return;
    try {
      final id = const Uuid().v4();
      await _db.insert('warehouse_types', {
        'id': id,
        'name': name,
      }, explicitId: id);
      if (!mounted) return;
      setState(() {
        _typesFuture = _loadCustomTypes();
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Таблица «$name» создана')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }

  /// Открывает экран списка для выбранного типа TMC.
  void _openType(String type) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => TypeTableTabsScreen(type: type, title: type)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Категории'),
        actions: [
          IconButton(
            onPressed: _createTypeDialog,
            tooltip: 'Добавить таблицу',
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: FutureBuilder<List<String>>(
        future: _typesFuture,
        builder: (context, snap) {
          final types = snap.data ?? const <String>[];
          return GridView.count(
            crossAxisCount: 3,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            padding: const EdgeInsets.all(12),
            children: [
              // Три стандартные категории отображаются всегда и не могут быть удалены
              _card('Бумага', onTap: () => _openType('Бумага'), deletable: false),
              _card('Канцелярия', onTap: () => _openType('Канцелярия'), deletable: false),
              _card('Краска', onTap: () => _openType('Краска'), deletable: false),
              // Пользовательские категории можно удалить длинным нажатием
              for (final t in types) _card(t, onTap: () => _openType(t), deletable: true),
            ],
          );
        },
      ),
    );
  }

  /// Карточка для категории.
  /// [deletable] определяет, можно ли удалить таблицу длинным нажатием.
  Widget _card(String title,
      {VoidCallback? onTap, bool deletable = false}) {
    return InkWell(
      onTap: onTap,
      onLongPress: deletable
          ? () {
              // Если разрешено удалять, вызываем диалог подтверждения
              _deleteType(title);
            }
          : null,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.blueGrey.shade100),
        ),
        padding: const EdgeInsets.all(12),
        child: Center(
          child: Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                height: 1.3),
          ),
        ),
      ),
    );
  }
}