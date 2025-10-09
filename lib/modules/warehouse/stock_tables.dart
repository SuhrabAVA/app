import 'package:flutter/material.dart';

import '../warehouse/type_table_screen.dart';

/// Экран для отображения списка таблиц по остаткам.
///
/// Каждая карточка представляет отдельную категорию складского остатка и
/// ведёт к экрану [TypeTableScreen], который отображает данные из Supabase.
class StockTables extends StatelessWidget {
  const StockTables({super.key});

  /// Публичный список типов изделий из модуля склада
  static List<String> get categoryTypes =>
      _categories.map((e) => e['type']!).toList(growable: false);

  static const List<Map<String, String>> _categories = [
    {
      'type': 'Пакеты с П дном',
      'title': 'Пакеты с П дном',
    },
    {
      'type': 'Листы',
      'title': 'Листы',
    },
    {
      'type': 'Пакеты с V дном',
      'title': 'Пакеты с V дном',
    },
    {
      'type': 'Готовая продукция',
      'title': 'Готовая продукция',
    },
    {
      'type': 'Готовые тиражи',
      'title': 'Готовые тиражи',
    },
    {
      'type': 'Ручки',
      'title': 'Ручки',
    },
    {
      'type': 'Тарелки',
      'title': 'Тарелки',
    },
  ];

  void _openCategory(BuildContext context, String type, String title) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TypeTableScreen(
          type: type,
          title: title,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Остатки')),
      body: Padding(
        padding: const EdgeInsets.all(8.0),
        child: GridView.count(
          // Увеличиваем количество столбцов и уменьшаем отступы,
          // чтобы карточки были компактнее
          crossAxisCount: 3,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          childAspectRatio: 1,
          children: _categories.map((cat) {
            return GestureDetector(
              onTap: () => _openCategory(
                context,
                cat['type']!,
                cat['title']!,
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.lightBlue.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.blueGrey.shade100),
                ),
                padding: const EdgeInsets.all(4),
                child: Center(
                  child: Text(
                    cat['title']!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
