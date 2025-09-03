import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'personnel_provider.dart';

/// Экран для отображения и управления списком терминалов.
class TerminalsScreen extends StatelessWidget {
  const TerminalsScreen({super.key});

  void _openAddDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => const _AddTerminalDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<PersonnelProvider>(context);
    final terminals = provider.terminals;
    final workplacesById = {for (var w in provider.workplaces) w.id: w.name};
    return Scaffold(
      appBar: AppBar(
        title: const Text('Терминалы'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _openAddDialog(context),
          ),
        ],
      ),
      body: terminals.isEmpty
          ? const Center(child: Text('Список терминалов пуст'))
          : ListView.separated(
              itemCount: terminals.length,
              separatorBuilder: (_, __) => const SizedBox(height: 4),
              itemBuilder: (context, index) {
                final term = terminals[index];
                final workplaceNames = term.workplaceIds
                    .map((id) => workplacesById[id] ?? '')
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
                      backgroundColor: Colors.orange.shade100,
                      child: const Icon(Icons.dns_outlined, size: 18, color: Colors.orange),
                    ),
                    title: Text(
                      term.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      workplaceNames.isEmpty ? 'Нет рабочих мест' : workplaceNames,
                      style: const TextStyle(color: Colors.black54),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// Диалог для добавления терминала.
class _AddTerminalDialog extends StatefulWidget {
  const _AddTerminalDialog();

  @override
  State<_AddTerminalDialog> createState() => _AddTerminalDialogState();
}

class _AddTerminalDialogState extends State<_AddTerminalDialog> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _nameController = TextEditingController();
  final Set<String> _selectedWorkplaces = {};

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _toggleWorkplace(String id, bool selected) {
    setState(() {
      if (selected) {
        _selectedWorkplaces.add(id);
      } else {
        _selectedWorkplaces.remove(id);
      }
    });
  }

  void _submit(BuildContext context) {
    if (!_formKey.currentState!.validate()) return;
    final provider = Provider.of<PersonnelProvider>(context, listen: false);
    provider.addTerminal(
      name: _nameController.text.trim(),
      workplaceIds: _selectedWorkplaces.toList(),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<PersonnelProvider>(context);
    final workplaces = provider.workplaces;
    return AlertDialog(
      title: const Text('Добавить терминал'),
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
                  'Рабочие места',
                  style: TextStyle(fontWeight: FontWeight.w600, color: Colors.grey[700]),
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: workplaces.map((wp) {
                  final selected = _selectedWorkplaces.contains(wp.id);
                  return FilterChip(
                    label: Text(wp.name),
                    selected: selected,
                    onSelected: (val) => _toggleWorkplace(wp.id, val),
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