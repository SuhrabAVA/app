import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'products_provider.dart';

/// Экран управления списком продукции.
class ProductsScreen extends StatelessWidget {
  const ProductsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Продукция')),
      body: Consumer<ProductsProvider>(
        builder: (context, provider, _) {
          final items = provider.products;
          if (items.isEmpty) {
            return const Center(child: Text('Список пуст'));
          }
          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, index) {
              final name = items[index];
              return ListTile(
                title: Text(name),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit),
                      tooltip: 'Редактировать',
                      onPressed: () => _showEditDialog(context, provider, index, name),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete),
                      tooltip: 'Удалить',
                      onPressed: () => provider.removeProduct(index),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddDialog(context),
        child: const Icon(Icons.add),
      ),
    );
  }

  void _showAddDialog(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Добавить продукцию'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Наименование'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                Provider.of<ProductsProvider>(context, listen: false)
                    .addProduct(name);
              }
              Navigator.pop(context);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }

  void _showEditDialog(BuildContext context, ProductsProvider provider, int index, String current) {
    final controller = TextEditingController(text: current);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Редактирование'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Наименование'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                provider.updateProduct(index, name);
              }
              Navigator.pop(context);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }
}
