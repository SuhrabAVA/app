import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'personnel_provider.dart';

/// Экран для отображения и управления списком должностей.
class PositionsScreen extends StatelessWidget {
  const PositionsScreen({super.key});

  void _openAddDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => const _AddPositionDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<PersonnelProvider>(context);
    final positions = provider.positions;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Должности'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _openAddDialog(context),
          ),
        ],
      ),
      body: positions.isEmpty
          ? const Center(child: Text('Список должностей пуст'))
          : ListView.separated(
              itemCount: positions.length,
              separatorBuilder: (_, __) => const Divider(height: 0),
              itemBuilder: (context, index) {
                final pos = positions[index];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.deepPurple.shade100,
                    child: const Icon(Icons.work_outline, size: 18, color: Colors.deepPurple),
                  ),
                    title: Text(
                      pos.name,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                );
              },
            ),
    );
  }
}

/// Диалог для добавления новой должности.
class _AddPositionDialog extends StatefulWidget {
  const _AddPositionDialog();

  @override
  State<_AddPositionDialog> createState() => _AddPositionDialogState();
}

class _AddPositionDialogState extends State<_AddPositionDialog> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _nameController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit(BuildContext context) {
    if (!_formKey.currentState!.validate()) return;
    final name = _nameController.text.trim();
    final provider = Provider.of<PersonnelProvider>(context, listen: false);
    provider.addPosition(name);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Добавить должность'),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _nameController,
          decoration: const InputDecoration(
            labelText: 'Название должности',
            border: OutlineInputBorder(),
          ),
          validator: (value) {
            if (value == null || value.trim().isEmpty) {
              return 'Введите название';
            }
            return null;
          },
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