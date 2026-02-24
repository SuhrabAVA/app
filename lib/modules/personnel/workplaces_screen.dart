// lib/modules/personnel/workplaces_screen.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'personnel_provider.dart';
import 'workplace_model.dart';
import 'position_model.dart'; // <-- ВАЖНО: нужен для типов PositionModel
import 'dialog_utils.dart'; // showDialogWithFreshPositions

const Set<String> _protectedWorkplaceIds = {'w_bobiner', 'w_flexoprint'};

class WorkplacesScreen extends StatelessWidget {
  const WorkplacesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<PersonnelProvider>(
      builder: (context, pr, _) {
        final items = pr.workplaces;
        String modeLabel(WorkplaceExecutionMode mode) {
          switch (mode) {
            case WorkplaceExecutionMode.separate:
              return 'Отдельный исполнитель';
            case WorkplaceExecutionMode.joint:
              return 'Одиночная или совместная работа';
          }
        }
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
                    // Названия должностей вместо id
                    final provider = context.read<PersonnelProvider>();
                    final names = w.positionIds
                        .map((id) => provider.positionNameById(id))
                        .where((name) => name.isNotEmpty)
                        .join(', ');
                    final roles =
                        names.isEmpty ? w.positionIds.join(', ') : names;
                    final unit = (w.unit ?? '').isNotEmpty ? w.unit : '—';
                    return "Должности: $roles\nЕд. изм.: $unit\nСтанок: ${w.hasMachine ? 'да' : 'нет'}\nРежим: ${modeLabel(w.executionMode)}";
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
                      icon: Icon(
                        Icons.delete_forever,
                        color: _protectedWorkplaceIds.contains(w.id)
                            ? Colors.grey
                            : null,
                      ),
                      tooltip: _protectedWorkplaceIds.contains(w.id)
                          ? 'Системное рабочее место нельзя удалить'
                          : 'Удалить',
                      onPressed: _protectedWorkplaceIds.contains(w.id)
                          ? null
                          : () => _confirmDelete(context, w.id),
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
    // 1) Перед показом формы подтягиваем СВЕЖИЕ должности из БД
    await context.read<PersonnelProvider>().fetchPositions();

    final nameC = TextEditingController();
    final unitC = TextEditingController();
    bool hasMachine = false;
    WorkplaceExecutionMode executionMode = WorkplaceExecutionMode.joint;

    // Локально храним выбранные id должностей
    final Set<String> selectedPositions = <String>{};

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
                    TextField(
                      controller: unitC,
                      decoration: const InputDecoration(
                        labelText: 'Единица измерения',
                        hintText: 'шт., кг, м² и т.д.',
                      ),
                    ),
                    CheckboxListTile(
                      title: const Text('Настройка станка есть'),
                      value: hasMachine,
                      onChanged: (val) =>
                          setState(() => hasMachine = val ?? false),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Режим исполнения',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    RadioListTile<WorkplaceExecutionMode>(
                      title: const Text('Одиночная или совместная работа'),
                      value: WorkplaceExecutionMode.joint,
                      groupValue: executionMode,
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => executionMode = value);
                      },
                      contentPadding: EdgeInsets.zero,
                    ),
                    RadioListTile<WorkplaceExecutionMode>(
                      title: const Text('Отдельный исполнитель'),
                      value: WorkplaceExecutionMode.separate,
                      groupValue: executionMode,
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => executionMode = value);
                      },
                      contentPadding: EdgeInsets.zero,
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Доступ для должностей',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    const SizedBox(height: 4),

                    // 2) Список чипов берём из провайдера через Consumer,
                    //    чтобы он обновлялся при изменениях.
                    Consumer<PersonnelProvider>(
                      builder: (_, pr, __) {
                        final List<PositionModel> positions =
                            List<PositionModel>.from(pr.positions)
                              ..sort((a, b) => a.name
                                  .toLowerCase()
                                  .compareTo(b.name.toLowerCase()));

                        if (positions.isEmpty) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 6),
                            child: Text('Должности не найдены'),
                          );
                        }

                        return Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: positions.map<Widget>((p) {
                            final sel = selectedPositions.contains(p.id);
                            return FilterChip(
                              label: Text(p.name.isEmpty ? p.id : p.name),
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
                        );
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Добавить'),
                ),
              ],
            );
          },
        );
      },
    );

    if (ok == true && nameC.text.trim().isNotEmpty) {
      try {
        await context.read<PersonnelProvider>().addWorkplace(
          name: nameC.text.trim(),
          positionIds: selectedPositions.toList(),
          hasMachine: hasMachine,
          maxConcurrentWorkers: 0,
          unit: unitC.text.trim(),
          executionMode: executionMode,
        );
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Ошибка сохранения: $e')),
          );
        }
      }
    }
  }

  Future<void> _openEditDialog(
      BuildContext context, WorkplaceModel workplace) async {
    // Перед редактированием тоже обновим должности
    await showDialogWithFreshPositions(
      context: context,
      builder: (_) => _EditWorkplaceDialog(workplace: workplace),
    );
  }

  Future<void> _confirmDelete(BuildContext context, String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Удалить рабочее место?'),
        content: const Text(
          'Действие необратимо. Если место назначено сотрудникам, переназначьте его заранее.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok == true) {
      if (_protectedWorkplaceIds.contains(id)) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Системные рабочие места удалять нельзя')));
        }
        return;
      }
      await context.read<PersonnelProvider>().deleteWorkplace(id);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Удалено')));
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
  late final TextEditingController _name =
      TextEditingController(text: widget.workplace.name);
  final TextEditingController _desc = TextEditingController();
  late final TextEditingController _unit =
      TextEditingController(text: widget.workplace.unit ?? '');
  bool _hasMachine = false;
  late Set<String> _selectedPositions;
  late WorkplaceExecutionMode _executionMode;

  @override
  void initState() {
    super.initState();
    _hasMachine = widget.workplace.hasMachine;
    _selectedPositions = {...widget.workplace.positionIds};
    _executionMode = widget.workplace.executionMode;
    // Если есть описание в модели — можно раскомментировать:
    // _desc.text = widget.workplace.description;
  }

  Future<void> _submit() async {
    await context.read<PersonnelProvider>().updateWorkplace(
          id: widget.workplace.id,
          name: _name.text.trim(),
          description: _desc.text.trim(),
          hasMachine: _hasMachine,
          maxConcurrentWorkers: 0,
          positionIds: _selectedPositions.toList(),
          unit: _unit.text.trim(),
          executionMode: _executionMode,
        );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    // Используем watch, чтобы чипы обновлялись при изменении списка должностей
    final List<PositionModel> positions = List<PositionModel>.from(
        context.watch<PersonnelProvider>().positions)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return AlertDialog(
      title: const Text('Изменить рабочее место'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Название'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _desc,
              decoration: const InputDecoration(labelText: 'Описание'),
              maxLines: 2,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _unit,
              decoration: const InputDecoration(
                labelText: 'Единица измерения',
                hintText: 'шт., кг, м² и т.д.',
              ),
            ),
            CheckboxListTile(
              title: const Text('Настройка станка есть'),
              value: _hasMachine,
              onChanged: (val) => setState(() => _hasMachine = val ?? false),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Режим исполнения',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            RadioListTile<WorkplaceExecutionMode>(
              title: const Text('Одиночная или совместная работа'),
              value: WorkplaceExecutionMode.joint,
              groupValue: _executionMode,
              onChanged: (value) {
                if (value == null) return;
                setState(() => _executionMode = value);
              },
              contentPadding: EdgeInsets.zero,
            ),
            RadioListTile<WorkplaceExecutionMode>(
              title: const Text('Отдельный исполнитель'),
              value: WorkplaceExecutionMode.separate,
              groupValue: _executionMode,
              onChanged: (value) {
                if (value == null) return;
                setState(() => _executionMode = value);
              },
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Доступ для должностей',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: positions.map<Widget>((p) {
                final sel = _selectedPositions.contains(p.id);
                return FilterChip(
                  label: Text(p.name.isEmpty ? p.id : p.name),
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
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}
