import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'personnel_list_controls.dart';
import 'personnel_list_filters.dart';
import 'personnel_provider.dart';
import 'position_model.dart';

class PositionsScreen extends StatefulWidget {
  const PositionsScreen({super.key});

  @override
  State<PositionsScreen> createState() => _PositionsScreenState();
}

class _PositionsScreenState extends State<PositionsScreen> {
  final PositionListFilter _filter = PositionListFilter();
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

  @override
  Widget build(BuildContext context) {
    final pr = context.watch<
        PersonnelProvider>(); // используем ГЛОБАЛЬНЫЙ провайдер из main.dart
    // Сколько действующих сотрудников и рабочих мест держат должность —
    // и для фильтра, и для подписи: удалять должность «вслепую» опасно.
    final employeeCount = <String, int>{};
    for (final e in pr.employees.where((e) => !e.isFired)) {
      for (final id in e.positionIds) {
        employeeCount[id] = (employeeCount[id] ?? 0) + 1;
      }
    }
    final workplaceCount = <String, int>{};
    for (final w in pr.workplaces) {
      for (final id in w.positionIds) {
        workplaceCount[id] = (workplaceCount[id] ?? 0) + 1;
      }
    }
    final items = pr.positions
        .where((p) => _filter.matches(
              p,
              employeeCount: employeeCount[p.id] ?? 0,
              workplaceCount: workplaceCount[p.id] ?? 0,
            ))
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Должности'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _showAddDialog(context),
            tooltip: 'Добавить должность',
          ),
          IconButton(
            icon: const Icon(Icons.verified_user),
            onPressed: pr.ensureManagerPosition,
            tooltip: 'Добавить «Менеджер» (если нет)',
          ),
        ],
      ),
      body: Column(
        children: [
          PersonnelFilterBar(
            controller: _search,
            hint: 'Название должности…',
            onQueryChanged: (v) => setState(() => _filter.query = v),
            shown: items.length,
            total: pr.positions.length,
            isActive: _filter.isActive,
            onReset: _reset,
            filters: [
              TriFilterChip(
                label: 'Сотрудники',
                value: _filter.hasEmployees,
                onChanged: (v) => setState(() => _filter.hasEmployees = v),
              ),
              TriFilterChip(
                label: 'Рабочие места',
                value: _filter.hasWorkplaces,
                onChanged: (v) => setState(() => _filter.hasWorkplaces = v),
              ),
            ],
          ),
          Expanded(
            child: items.isEmpty
                ? PersonnelEmptyResult(
                    isFiltered: _filter.isActive,
                    emptyText: 'Должностей пока нет',
                    onReset: _reset,
                  )
                : _buildList(items, employeeCount, workplaceCount),
          ),
        ],
      ),
    );
  }

  Widget _buildList(
    List<PositionModel> items,
    Map<String, int> employeeCount,
    Map<String, int> workplaceCount,
  ) {
    return ListView.separated(
        itemCount: items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final PositionModel position = items[i];
          return ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: Text(position.name),
            subtitle: Text(
              'Сотрудников: ${employeeCount[position.id] ?? 0} · '
              'Рабочих мест: ${workplaceCount[position.id] ?? 0}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit),
                  tooltip: 'Изменить',
                  onPressed: () => _openEditDialog(context, position),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_forever),
                  tooltip: 'Удалить',
                  onPressed: () => _confirmDelete(context, position.id),
                ),
              ],
            ),
          );
        },
    );
  }

  Future<void> _showAddDialog(BuildContext context) async {
    final nameC = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Новая должность'),
        content: TextField(
          controller: nameC,
          decoration: const InputDecoration(labelText: 'Название'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Добавить')),
        ],
      ),
    );
    if (ok == true && nameC.text.trim().isNotEmpty) {
      context.read<PersonnelProvider>().addPosition(nameC.text.trim());
    }
  }

  void _openEditDialog(BuildContext context, PositionModel position) {
    showDialog(
      context: context,
      builder: (_) => _EditPositionDialog(position: position),
    );
  }

  Future<void> _confirmDelete(BuildContext context, String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Удалить должность?'),
        content: const Text(
            'Действие необратимо. Если должность назначена сотрудникам, переназначьте её заранее.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Удалить')),
        ],
      ),
    );
    if (ok == true) {
      await context.read<PersonnelProvider>().deletePosition(id);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Удалено')));
      }
    }
  }
}

class _EditPositionDialog extends StatefulWidget {
  final PositionModel position;
  const _EditPositionDialog({required this.position});

  @override
  State<_EditPositionDialog> createState() => _EditPositionDialogState();
}

class _EditPositionDialogState extends State<_EditPositionDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.position.name);
  final TextEditingController _desc = TextEditingController();

  Future<void> _submit() async {
    await context.read<PersonnelProvider>().updatePosition(
        id: widget.position.id,
        name: _name.text.trim(),
        description: _desc.text.trim());
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Изменить должность'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Название')),
          const SizedBox(height: 8),
          TextField(
              controller: _desc,
              decoration: const InputDecoration(labelText: 'Описание'),
              maxLines: 2),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена')),
        FilledButton(onPressed: _submit, child: const Text('Сохранить')),
      ],
    );
  }
}
