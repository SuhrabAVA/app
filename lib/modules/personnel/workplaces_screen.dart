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
                    'Должности: ${w.positionIds.join(', ')}\nСтанок: ${w.hasMachine ? 'да' : 'нет'}, макс.: ${w.maxConcurrentWorkers}'),
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setState) {
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
      context.read<PersonnelProvider>().addWorkplace(
        name: nameC.text.trim(),
        positionIds: const [],
        hasMachine: hasMachine,
        maxConcurrentWorkers: maxWorkers ?? 1,
      );
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

  @override
  void initState() {
    super.initState();
    _hasMachine = widget.workplace.hasMachine;
  }

  Future<void> _submit() async {
    final int? mw = int.tryParse(_maxWorkers.text.trim());
    await context.read<PersonnelProvider>().updateWorkplace(
      id: widget.workplace.id,
      name: _name.text.trim(),
      description: _desc.text.trim(),
      hasMachine: _hasMachine,
      maxConcurrentWorkers: mw,
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
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
