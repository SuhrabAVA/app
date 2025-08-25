import 'package:flutter/material.dart';

import 'type_table_tabs_screen.dart';
import 'suppliers_screen.dart';
import 'categories_hub_screen.dart';
import 'warehouse_provider.dart';
import 'tmc_model.dart';
import 'package:provider/provider.dart';

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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Панель предупреждений о низком остатке
            Consumer<WarehouseProvider>(
              builder: (context, provider, _) {
                final List<TmcModel> low = provider.allTmc.where((t) {
                  // выводим только бумагу и краску
                  if (t.type == 'Бумага') {
                    return t.quantity <= 10000;
                  } else if (t.type == 'Краска') {
                    return t.quantity <= 10;
                  } else {
                    return false;
                  }
                }).toList();
                if (low.isEmpty) return const SizedBox.shrink();
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.yellow.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.yellow.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Низкий остаток:', style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: low.map((t) {
                          Color bg;
                          if (t.type == 'Бумага') {
                            bg = t.quantity <= 5000 ? Colors.red.shade200 : Colors.yellow.shade200;
                          } else {
                            bg = t.quantity <= 5 ? Colors.red.shade200 : Colors.yellow.shade200;
                          }
                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: bg,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text('${t.description}: ${t.quantity}${t.unit ?? ''}', style: const TextStyle(fontSize: 12)),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                );
              },
            ),
            Expanded(
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