import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'personnel_provider.dart';
import 'position_model.dart';

class PositionsScreen extends StatelessWidget {
  const PositionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<PersonnelProvider>(
      create: (_) => PersonnelProvider(),
      builder: (context, _) {
        final pr = context.watch<PersonnelProvider>();
        final items = pr.positions;
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
          body: ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final PositionModel position = items[i];
              return ListTile(
                leading: const Icon(Icons.badge_outlined),
                title: Text(position.name),
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
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Добавить')),
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
        content: const Text('Действие необратимо. Если должность назначена сотрудникам, переназначьте её заранее.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok == true) {
      await context.read<PersonnelProvider>().deletePosition(id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Удалено')));
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
  late final TextEditingController _name = TextEditingController(text: widget.position.name);
  final TextEditingController _desc = TextEditingController();

  Future<void> _submit() async {
    await context.read<PersonnelProvider>()
        .updatePosition(id: widget.position.id, name: _name.text.trim(), description: _desc.text.trim());
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Изменить должность'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Название')),
          const SizedBox(height: 8),
          TextField(controller: _desc, decoration: const InputDecoration(labelText: 'Описание'), maxLines: 2),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(onPressed: _submit, child: const Text('Сохранить')),
      ],
    );
  }
}
