import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';

import '../products/products_provider.dart';
import 'type_table_tabs_screen.dart';

class CategoriesHubScreen extends StatefulWidget {
  const CategoriesHubScreen({super.key});

  @override
  State<CategoriesHubScreen> createState() => _CategoriesHubScreenState();
}

class _CategoriesHubScreenState extends State<CategoriesHubScreen> {
  final _sb = Supabase.instance.client;
  List<String> _types = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await _sb.from('tmc').select('type');
      final set = <String>{};
      for (final r in rows as List) {
        final t = (r['type'] ?? '').toString().trim();
        if (t.isEmpty) continue;
        if (t == 'Списание' || t == 'Инвентаризация') continue;
        set.add(t);
      }
      final list = set.toList()..sort((a,b)=>a.compareTo(b));
      setState(() {
        _types = list;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  bool _isPaint(String type) {
    final t = type.toLowerCase();
    return t.contains('краск'); // "краска", "краски"
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Категории'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(8.0),
              child: GridView.count(
                crossAxisCount: 3,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                childAspectRatio: 1,
                children: [
                  // Собираем уникальные категории: объединяем типы TMC и виды
                  // продуктов из модуля продукции. Таким образом на складе
                  // отображаются как стандартные категории (Бумага, Канцелярия, Краска),
                  // так и изделия, добавленные в разделе продукции.
                  ...(() {
                    final products = context.watch<ProductsProvider>().products;
                    final set = <String>{..._types, ...products};
                    final list = set.toList()..sort((a, b) => a.compareTo(b));
                    return list.map((t) {
                      return _card(context, t, TypeTableTabsScreen(
                        type: t,
                        title: t,
                        enablePhoto: _isPaint(t),
                      ));
                    });
                  })(),
                ],
              ),
            ),
    );
  }

  Widget _card(BuildContext context, String title, Widget page) {
    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => page)),
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
