import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../utils/auth_helper.dart';
import 'employee_status_model.dart';
import 'personnel_list_controls.dart';
import 'personnel_list_filters.dart';
import 'personnel_provider.dart';

/// Статусы сотрудников с фиксированной оплатой (например «Стажер»,
/// «Грузчик»). Создавать/редактировать/удалять может только технический
/// лидер — остальным доступен только просмотр списка.
class StatusesScreen extends StatefulWidget {
  const StatusesScreen({super.key});

  @override
  State<StatusesScreen> createState() => _StatusesScreenState();
}

class _StatusesScreenState extends State<StatusesScreen> {
  final StatusListFilter _filter = StatusListFilter();
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
    final pr = context.watch<PersonnelProvider>();
    // Статус «присвоен», если он текущий хотя бы у одного действующего.
    final assignedCount = <String, int>{};
    for (final e in pr.employees.where((e) => !e.isFired)) {
      final id = pr.currentStatusIdFor(e.id);
      if (id == null || id.isEmpty) continue;
      assignedCount[id] = (assignedCount[id] ?? 0) + 1;
    }
    final items = pr.statuses
        .where((s) =>
            _filter.matches(s, assignedCount: assignedCount[s.id] ?? 0))
        .toList();
    final canEdit = AuthHelper.isTechLeader;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Статусы'),
        actions: [
          if (canEdit)
            IconButton(
              icon: const Icon(Icons.add),
              onPressed: () => _showAddDialog(context),
              tooltip: 'Добавить статус',
            ),
        ],
      ),
      body: Column(
        children: [
          PersonnelFilterBar(
            controller: _search,
            hint: 'Название или описание статуса…',
            onQueryChanged: (v) => setState(() => _filter.query = v),
            shown: items.length,
            total: pr.statuses.length,
            isActive: _filter.isActive,
            onReset: _reset,
            filters: [
              TriFilterChip(
                label: 'Присвоен сотрудникам',
                value: _filter.assigned,
                yes: 'да',
                no: 'нет',
                onChanged: (v) => setState(() => _filter.assigned = v),
              ),
            ],
          ),
          Expanded(
            child: items.isEmpty
          ? PersonnelEmptyResult(
              isFiltered: _filter.isActive,
              emptyText: 'Статусов пока нет',
              onReset: _reset,
            )
          : ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final EmployeeStatus status = items[i];
                final description = (status.description ?? '').trim();
                final count = assignedCount[status.id] ?? 0;
                return ListTile(
                  leading: const Icon(Icons.workspace_premium_outlined),
                  title: Text(status.name),
                  subtitle: Text([
                    if (description.isNotEmpty) description,
                    'Сотрудников: $count',
                  ].join('\n')),
                  trailing: canEdit
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit),
                              tooltip: 'Изменить',
                              onPressed: () => _openEditDialog(context, status),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_forever),
                              tooltip: 'Удалить',
                              onPressed: () => _confirmDelete(context, status.id),
                            ),
                          ],
                        )
                      : null,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddDialog(BuildContext context) async {
    final nameC = TextEditingController();
    final descC = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Новый статус'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameC,
              decoration: const InputDecoration(labelText: 'Название'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: descC,
              decoration: const InputDecoration(labelText: 'Описание (необязательно)'),
              maxLines: 2,
            ),
          ],
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
      final desc = descC.text.trim();
      await context
          .read<PersonnelProvider>()
          .addStatus(nameC.text.trim(), description: desc.isEmpty ? null : desc);
    }
  }

  void _openEditDialog(BuildContext context, EmployeeStatus status) {
    showDialog(
      context: context,
      builder: (_) => _EditStatusDialog(status: status),
    );
  }

  Future<void> _confirmDelete(BuildContext context, String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Удалить статус?'),
        content: const Text(
            'Действие необратимо. Если статус присвоен сотрудникам, история сохранится, но текущее назначение будет потеряно.'),
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
      await context.read<PersonnelProvider>().deleteStatus(id);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Удалено')));
      }
    }
  }
}

class _EditStatusDialog extends StatefulWidget {
  final EmployeeStatus status;
  const _EditStatusDialog({required this.status});

  @override
  State<_EditStatusDialog> createState() => _EditStatusDialogState();
}

class _EditStatusDialogState extends State<_EditStatusDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.status.name);
  late final TextEditingController _desc =
      TextEditingController(text: widget.status.description ?? '');

  Future<void> _submit() async {
    final desc = _desc.text.trim();
    await context.read<PersonnelProvider>().updateStatus(
          id: widget.status.id,
          name: _name.text.trim(),
          description: desc.isEmpty ? null : desc,
        );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Изменить статус'),
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
