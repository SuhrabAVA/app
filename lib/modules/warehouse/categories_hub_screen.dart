import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  final _sb = Supabase.instance.client;
  late Future<List<String>> _typesFuture;

  @override
  void initState() {
    super.initState();
    _typesFuture = _loadCustomTypes();
  }

  /// Загружает список пользовательских типов из таблицы warehouse_types.
  Future<List<String>> _loadCustomTypes() async {
    final rows = await _sb.from('warehouse_types').select('name').order('name');
    return (rows as List).map((e) => (e['name'] as String)).toList();
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
      await _sb.from('warehouse_types').upsert({'name': name});
      setState(() {
        _typesFuture = _loadCustomTypes();
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Таблица «$name» создана')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
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
              _card('Бумага', onTap: () => _openType('Бумага')),
              _card('Канцелярия', onTap: () => _openType('Канцелярия')),
              _card('Краска', onTap: () => _openType('Краска')),
              for (final t in types) _card(t, onTap: () => _openType(t)),
            ],
          );
        },
      ),
    );
  }

  /// Карточка для категории.
  Widget _card(String title, {VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
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
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.3),
          ),
        ),
      ),
    );
  }
}