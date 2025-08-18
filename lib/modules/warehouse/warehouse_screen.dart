import 'package:flutter/material.dart';

import 'type_table_tabs_screen.dart';
import 'suppliers_screen.dart';
import 'categories_hub_screen.dart';

class WarehouseDashboard extends StatelessWidget {
  const WarehouseDashboard({super.key});

  void _open(BuildContext context, Widget screen) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Склад')),
      body: Padding(
        padding: const EdgeInsets.all(8.0),
        child: GridView.count(
          crossAxisCount: 3,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          childAspectRatio: 1,
          children: [
            _card(context, '📄\nБумага', const TypeTableTabsScreen(type: 'Бумага', title: 'Бумага')),
            _card(context, '✏️\nКанцелярия', const TypeTableTabsScreen(type: 'Канцелярия', title: 'Канцелярия')),
            _card(context, '🎨\nКраски', const TypeTableTabsScreen(type: 'Краска', title: 'Краски', enablePhoto: true)),
            _card(context, '📦\nКатегории', const CategoriesHubScreen()),
            _card(context, '🏷️\nПоставщики', const SuppliersScreen()),
          ],
        ),
      ),
    );
  }

  Widget _card(BuildContext context, String title, Widget page) {
    return GestureDetector(
      onTap: () => _open(context, page),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.lightBlue.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.blueGrey.shade100),
        ),
        padding: const EdgeInsets.all(4),
        child: Center(
          child: Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, height: 1.3),
          ),
        ),
      ),
    );
  }
}