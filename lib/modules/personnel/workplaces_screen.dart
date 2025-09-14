import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'personnel_provider.dart';
import 'workplace_model.dart';

class WorkplacesScreen extends StatelessWidget {
  const WorkplacesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<PersonnelProvider>(
      create: (_) => PersonnelProvider(),
      builder: (context, _) {
        final pr = context.watch<PersonnelProvider>();
        final items = pr.workplaces;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Рабочие места'),
            actions: [
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: () => _showAddDialog(context),
                tooltip: 'Добавить место',
              ),
            ],
          ),
          body: ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final WorkplaceModel w = items[i];
              return ListTile(
                leading: const Icon(Icons.chair_alt_outlined),
                title: Text(w.name),
                subtitle: Text(
                    () {
                      // отобразим названия должностей вместо id
                      final provider = context.read<PersonnelProvider>();
                      final names = w.positionIds
                          .map((id) => provider.positionNameById(id))
                          .where((name) => name.isNotEmpty)
                          .join(', ');
                      final roles = names.isEmpty ? w.positionIds.join(', ') : names;
                      return "Должности: $roles\nСтанок: ${w.hasMachine ? 'да' : 'нет'}, макс.: ${w.maxConcurrentWorkers}";
                    }(),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit),
                      tooltip: 'Изменить',
                      onPressed: () => _openEditDialog(context, w),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_forever),
                      tooltip: 'Удалить',
                      onPressed: () => _confirmDelete(context, w.id),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _showAddDialog(BuildContext context) async {
    final nameC = TextEditingController();
    final maxWorkersC = TextEditingController(text: '1');
    bool hasMachine = false;
    // Selected position ids for new workplace
    final Set<String> selectedPositions = {};
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setState) {
            // get positions from provider (use read to avoid rebuild issues in dialog context)
            final positions = context.read<PersonnelProvider>().positions;
            return AlertDialog(
              title: const Text('Новое рабочее место'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameC,
                      decoration: const InputDecoration(labelText: 'Название'),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: maxWorkersC,
                            decoration: const InputDecoration(labelText: 'Макс. сотрудников'),
                            keyboardType: TextInputType.number,
                          ),
                        ),
                      ],
                    ),
                    CheckboxListTile(
                      title: const Text('Настройка станка есть'),
                      value: hasMachine,
                      onChanged: (val) => setState(() => hasMachine = val ?? false),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Доступ для должностей',
                          style: Theme.of(context).textTheme.titleSmall),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: positions.map((p) {
                        final sel = selectedPositions.contains(p.id);
                        return FilterChip(
                          label: Text(p.name),
                          selected: sel,
                          onSelected: (v) {
                            setState(() {
                              if (v) {
                                selectedPositions.add(p.id);
                              } else {
                                selectedPositions.remove(p.id);
                              }
                            });
                          },
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
                FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Добавить')),
              ],
            );
          },
        );
      },
    );
    if (ok == true && nameC.text.trim().isNotEmpty) {
      final int? maxWorkers = int.tryParse(maxWorkersC.text.trim());
      try {
        await context.read<PersonnelProvider>().addWorkplace(
          name: nameC.text.trim(),
          positionIds: selectedPositions.toList(),
          hasMachine: hasMachine,
          maxConcurrentWorkers: maxWorkers ?? 1,
        );
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('Ошибка сохранения: $e')));
        }
      }
    }
  }

  void _openEditDialog(BuildContext context, WorkplaceModel workplace) {
    showDialog(
      context: context,
      builder: (_) => _EditWorkplaceDialog(workplace: workplace),
    );
  }

  Future<void> _confirmDelete(BuildContext context, String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Удалить рабочее место?'),
        content: const Text('Действие необратимо. Если место назначено сотрудникам, переназначьте его заранее.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok == true) {
      await context.read<PersonnelProvider>().deleteWorkplace(id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Удалено')));
      }
    }
  }
}

class _EditWorkplaceDialog extends StatefulWidget {
  final WorkplaceModel workplace;
  const _EditWorkplaceDialog({required this.workplace});

  @override
  State<_EditWorkplaceDialog> createState() => _EditWorkplaceDialogState();
}

class _EditWorkplaceDialogState extends State<_EditWorkplaceDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.workplace.name);
  final TextEditingController _desc = TextEditingController();
  late final TextEditingController _maxWorkers =
      TextEditingController(text: widget.workplace.maxConcurrentWorkers.toString());
  bool _hasMachine = false;
  late Set<String> _selectedPositions;

  @override
  void initState() {
    super.initState();
    _hasMachine = widget.workplace.hasMachine;
    _selectedPositions = {...widget.workplace.positionIds};
  }

  Future<void> _submit() async {
    final int? mw = int.tryParse(_maxWorkers.text.trim());
    await context.read<PersonnelProvider>().updateWorkplace(
      id: widget.workplace.id,
      name: _name.text.trim(),
      description: _desc.text.trim(),
      hasMachine: _hasMachine,
      maxConcurrentWorkers: mw,
      positionIds: _selectedPositions.toList(),
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final positions = context.read<PersonnelProvider>().positions;
    return AlertDialog(
      title: const Text('Изменить рабочее место'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Название')),
            const SizedBox(height: 8),
            TextField(controller: _desc, decoration: const InputDecoration(labelText: 'Описание'), maxLines: 2),
            const SizedBox(height: 8),
            TextField(
              controller: _maxWorkers,
              decoration: const InputDecoration(labelText: 'Макс. сотрудников'),
              keyboardType: TextInputType.number,
            ),
            CheckboxListTile(
              title: const Text('Настройка станка есть'),
              value: _hasMachine,
              onChanged: (val) => setState(() => _hasMachine = val ?? false),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Доступ для должностей',
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: positions.map((p) {
                final sel = _selectedPositions.contains(p.id);
                return FilterChip(
                  label: Text(p.name),
                  selected: sel,
                  onSelected: (v) {
                    setState(() {
                      if (v) {
                        _selectedPositions.add(p.id);
                      } else {
                        _selectedPositions.remove(p.id);
                      }
                    });
                  },
                );
              }).toList(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(onPressed: _submit, child: const Text('Сохранить')),
      ],
    );
  }
}
