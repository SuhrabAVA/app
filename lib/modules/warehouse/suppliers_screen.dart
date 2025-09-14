import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'supplier_provider.dart';
import 'supplier_model.dart';

/// Экран для отображения списка поставщиков и управления ими.
///
/// Показывает таблицу поставщиков с возможностью поиска, фильтрации
/// и добавления/редактирования/удаления записей. Данные управляются
/// через [SupplierProvider].
class SuppliersScreen extends StatefulWidget {
  const SuppliersScreen({super.key});

  @override
  State<SuppliersScreen> createState() => _SuppliersScreenState();
}

class _SuppliersScreenState extends State<SuppliersScreen> {
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<SupplierProvider>(context, listen: false).fetchSuppliers();
    });
  }

  void _openAddDialog([SupplierModel? existing]) {
    showDialog(
      context: context,
      builder: (_) => _SupplierDialog(existing: existing),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Поставщики'),
      ),
      body: Consumer<SupplierProvider>(
        builder: (context, provider, _) {
          final suppliers = provider.suppliers
              .where((s) => s.name.toLowerCase().contains(_searchQuery.toLowerCase()))
              .toList();
          return Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: TextField(
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.search),
                          hintText: 'Поиск поставщиков...',
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (val) => setState(() => _searchQuery = val),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: () => _openAddDialog(),
                      icon: const Icon(Icons.add),
                      label: const Text('Добавить поставщика'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Card(
                    elevation: 2,
                    child: suppliers.isEmpty
                        ? const Center(child: Text('Нет данных'))
                        : SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: DataTable(
                              columnSpacing: 24,
                              columns: const [
                                DataColumn(label: Text('ID')),
                                DataColumn(label: Text('Название')),
                                DataColumn(label: Text('БИН')),
                                DataColumn(label: Text('Контакт')),
                                DataColumn(label: Text('Телефон')),
                                DataColumn(label: Text('Действия')),
                              ],
                              rows: List<DataRow>.generate(
                                suppliers.length,
                                (index) {
                                  final s = suppliers[index];
                                  return DataRow(cells: [
                                    DataCell(Text('${index + 1}')),
                                    DataCell(Text(s.name)),
                                    DataCell(Text(s.bin)),
                                    DataCell(Text(s.contact)),
                                    DataCell(Text(s.phone)),
                                    DataCell(Row(
                                      children: [
                                        IconButton(
                                          icon: const Icon(Icons.edit, size: 20),
                                          onPressed: () => _openAddDialog(s),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete, size: 20),
                                          onPressed: () async {
                                            final confirm = await showDialog<bool>(
                                              context: context,
                                              builder: (ctx) => AlertDialog(
                                                title: const Text('Удалить поставщика?'),
                                                content: Text('Вы уверены, что хотите удалить ${s.name}?'),
                                                actions: [
                                                  TextButton(
                                                    onPressed: () => Navigator.of(ctx).pop(false),
                                                    child: const Text('Отмена'),
                                                  ),
                                                  TextButton(
                                                    onPressed: () => Navigator.of(ctx).pop(true),
                                                    child: const Text('Удалить'),
                                                  ),
                                                ],
                                              ),
                                            );
                                            if (confirm == true) {
                                              await Provider.of<SupplierProvider>(context, listen: false)
                                                  .deleteSupplier(s.id);
                                            }
                                          },
                                        ),
                                      ],
                                    )),
                                  ]);
                                },
                              ),
                            ),
                          ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Диалог для добавления или редактирования поставщика.
class _SupplierDialog extends StatefulWidget {
  final SupplierModel? existing;
  const _SupplierDialog({this.existing});

  @override
  State<_SupplierDialog> createState() => _SupplierDialogState();
}

class _SupplierDialogState extends State<_SupplierDialog> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _binController;
  late TextEditingController _contactController;
  late TextEditingController _phoneController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.existing?.name ?? '');
    _binController = TextEditingController(text: widget.existing?.bin ?? '');
    _contactController = TextEditingController(text: widget.existing?.contact ?? '');
    _phoneController = TextEditingController(text: widget.existing?.phone ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _binController.dispose();
    _contactController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final provider = Provider.of<SupplierProvider>(context, listen: false);
    final name = _nameController.text.trim();
    final bin = _binController.text.trim();
    final contact = _contactController.text.trim();
    final phone = _phoneController.text.trim();
    if (widget.existing == null) {
      await provider.addSupplier(name: name, bin: bin, contact: contact, phone: phone);
    } else {
      await provider.updateSupplier(
        id: widget.existing!.id,
        name: name,
        bin: bin,
        contact: contact,
        phone: phone,
      );
    }
    // Close dialog
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Добавить поставщика' : 'Редактировать поставщика'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Название'),
                validator: (value) => value == null || value.isEmpty ? 'Введите название' : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _binController,
                decoration: const InputDecoration(labelText: 'БИН'),
                validator: (value) => value == null || value.isEmpty ? 'Введите БИН' : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _contactController,
                decoration: const InputDecoration(labelText: 'Контактное лицо'),
                validator: (value) => value == null || value.isEmpty ? 'Введите контактное лицо' : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _phoneController,
                decoration: const InputDecoration(labelText: 'Телефон'),
                validator: (value) => value == null || value.isEmpty ? 'Введите телефон' : null,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        ElevatedButton(
          onPressed: _save,
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}