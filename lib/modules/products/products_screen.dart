import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'products_provider.dart';

/// Экран управления списком продукции.
class ProductsScreen extends StatelessWidget {
  const ProductsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Продукция'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Изделия'),
              Tab(text: 'Параметры'),
              Tab(text: 'Ручки'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _ProductsTab(),
            _ParametersTab(),
            _HandlesTab(),
          ],
        ),
      ),
    );
  }
}

class _ProductsTab extends StatelessWidget {
  const _ProductsTab();

  @override
  Widget build(BuildContext context) {
    return Consumer<ProductsProvider>(
      builder: (context, provider, _) {
        final items = provider.products;
        return _ParametersTab()._buildList(
          context,
          items,
          provider.addProduct,
          provider.updateProduct,
          provider.removeProduct,
        );
      },
    );
  }
}

class _ParametersTab extends StatelessWidget {
  const _ParametersTab();

  @override
  Widget build(BuildContext context) {
    return Consumer<ProductsProvider>(
      builder: (context, provider, _) {
        final params = provider.parameters;
        return _buildList(context, params, provider.addParameter, provider.updateParameter, provider.removeParameter);
      },
    );
  }

  Widget _buildList(
    BuildContext context,
    List<String> items,
    void Function(String) onAdd,
    void Function(int, String) onUpdate,
    void Function(int) onRemove,
  ) {
    return Scaffold(
      body: items.isEmpty
          ? const Center(child: Text('Список пуст'))
          : ListView.builder(
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
                        onPressed: () => _showEditDialog(context, onUpdate, name, index),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: () => onRemove(index),
                      ),
                    ],
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddDialog(context, onAdd),
        child: const Icon(Icons.add),
      ),
    );
  }

  void _showAddDialog(BuildContext context, void Function(String) onAdd) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Добавить'),
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
                onAdd(name);
              }
              Navigator.pop(context);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }

  void _showEditDialog(BuildContext context, void Function(int, String) onSave, String current, int index) {
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
                onSave(index, name);
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

class _HandlesTab extends StatelessWidget {
  const _HandlesTab();

  @override
  Widget build(BuildContext context) {
    return Consumer<ProductsProvider>(
      builder: (context, provider, _) {
        final handles = provider.handles;
        return _ParametersTab()._buildList(
          context,
          handles,
          provider.addHandle,
          provider.updateHandle,
          provider.removeHandle,
        );
      },
    );
  }
}

