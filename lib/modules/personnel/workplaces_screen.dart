import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'personnel_provider.dart';

/// Экран для отображения и управления списком рабочих мест.
class WorkplacesScreen extends StatelessWidget {
  const WorkplacesScreen({super.key});

  void _openAddDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => const _AddWorkplaceDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<PersonnelProvider>(context);
    final workplaces = provider.workplaces;
    final positionsById = {for (var p in provider.positions) p.id: p.name};
    return Scaffold(
      appBar: AppBar(
        title: const Text('Рабочие места'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _openAddDialog(context),
          ),
        ],
      ),
      body: workplaces.isEmpty
          ? const Center(child: Text('Список рабочих мест пуст'))
          : ListView.separated(
              itemCount: workplaces.length,
              separatorBuilder: (_, __) => const SizedBox(height: 4),
              itemBuilder: (context, index) {
                final wp = workplaces[index];
                final posNames = wp.positionIds
                    .map((id) => positionsById[id] ?? '')
                    .where((s) => s.isNotEmpty)
                    .join(', ');
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  elevation: 1,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: Colors.grey.shade300),
                  ),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Colors.teal.shade100,
                      child: const Icon(Icons.build_outlined, size: 18, color: Colors.teal),
                    ),
                    title: Text(
                      wp.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      posNames.isEmpty ? 'Нет должностей' : posNames,
                      style: const TextStyle(color: Colors.black54),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// Диалог для добавления рабочего места.
class _AddWorkplaceDialog extends StatefulWidget {
  const _AddWorkplaceDialog();

  @override
  State<_AddWorkplaceDialog> createState() => _AddWorkplaceDialogState();
}

class _AddWorkplaceDialogState extends State<_AddWorkplaceDialog> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _nameController = TextEditingController();
  final Set<String> _selectedPositions = {};

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _togglePosition(String id, bool selected) {
    setState(() {
      if (selected) {
        _selectedPositions.add(id);
      } else {
        _selectedPositions.remove(id);
      }
    });
  }

  void _submit(BuildContext context) {
    if (!_formKey.currentState!.validate()) return;
    final provider = Provider.of<PersonnelProvider>(context, listen: false);
    provider.addWorkplace(
      name: _nameController.text.trim(),
      positionIds: _selectedPositions.toList(),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<PersonnelProvider>(context);
    final positions = provider.positions;
    return AlertDialog(
      title: const Text('Добавить рабочее место'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Название',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Введите название';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Должности',
                  style: TextStyle(fontWeight: FontWeight.w600, color: Colors.grey[700]),
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: positions.map((pos) {
                  final selected = _selectedPositions.contains(pos.id);
                  return FilterChip(
                    label: Text(pos.name),
                    selected: selected,
                    onSelected: (val) => _togglePosition(pos.id, val),
                    selectedColor: Theme.of(context).colorScheme.primary.withOpacity(0.2),
                  );
                }).toList(),
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
          onPressed: () => _submit(context),
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}