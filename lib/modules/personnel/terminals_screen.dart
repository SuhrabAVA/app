import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'personnel_list_controls.dart';
import 'personnel_list_filters.dart';
import 'personnel_provider.dart';

/// Экран для отображения и управления списком терминалов.
class TerminalsScreen extends StatefulWidget {
  const TerminalsScreen({super.key});

  @override
  State<TerminalsScreen> createState() => _TerminalsScreenState();
}

class _TerminalsScreenState extends State<TerminalsScreen> {
  final TerminalListFilter _filter = TerminalListFilter();
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _reset() {
    _search.clear();
    setState(_filter.clear);
  }

  void _openAddDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => const _AddTerminalDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<PersonnelProvider>(context);
    final workplacesById = {for (var w in provider.workplaces) w.id: w.name};
    final terminals = provider.terminals
        .where((t) => _filter.matches(t,
            workplaceName: (id) => workplacesById[id] ?? ''))
        .toList();
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
      body: Column(
        children: [
          PersonnelFilterBar(
            controller: _search,
            hint: 'Название терминала или рабочего места…',
            onQueryChanged: (v) => setState(() => _filter.query = v),
            shown: terminals.length,
            total: provider.terminals.length,
            isActive: _filter.isActive,
            onReset: _reset,
            filters: [
              MultiSelectFilterChip(
                label: 'Рабочее место',
                options: [
                  const FilterOption(kFilterNoneId, 'Без рабочих мест'),
                  for (final w in provider.workplaces)
                    FilterOption(w.id, w.name),
                ],
                selected: _filter.workplaceIds,
                onChanged: (ids) => setState(() => _filter.workplaceIds
                  ..clear()
                  ..addAll(ids)),
              ),
            ],
          ),
          Expanded(
            child: terminals.isEmpty
          ? PersonnelEmptyResult(
              isFiltered: _filter.isActive,
              emptyText: 'Список терминалов пуст',
              onReset: _reset,
            )
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
          ),
        ],
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