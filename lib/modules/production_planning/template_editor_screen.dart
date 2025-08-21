import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'template_model.dart';
import '../personnel/personnel_provider.dart';
import '../personnel/workplace_model.dart';
import 'planned_stage_model.dart';
import 'template_provider.dart';

class TemplateEditorScreen extends StatefulWidget {
  final TemplateModel? template;
  const TemplateEditorScreen({super.key, this.template});

  @override
  State<TemplateEditorScreen> createState() => _TemplateEditorScreenState();
}

class _TemplateEditorScreenState extends State<TemplateEditorScreen> {
  final _nameCtrl = TextEditingController();
  final List<PlannedStage> _stages = [];

  @override
  void initState() {
    super.initState();
    final tpl = widget.template;
    if (tpl != null) {
      _nameCtrl.text = tpl.name;
      _stages.addAll(tpl.stages.map((s) =>
          PlannedStage(stageId: s.stageId, stageName: s.stageName, comment: s.comment)));
    }
  }

  Future<void> _addStage() async {
    final personnel = context.read<PersonnelProvider>();
    String? selectedId;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Выберите этап'),
        content: DropdownButtonFormField<String>(
          items: [
            for (final w in personnel.workplaces)
              DropdownMenuItem(value: w.id, child: Text(w.name)),
          ],
          onChanged: (val) => selectedId = val,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
    if (selectedId != null) {
      final w = personnel.workplaces.firstWhere((w) => w.id == selectedId);
      setState(() {
        _stages.add(PlannedStage(stageId: w.id, stageName: w.name));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final personnel = context.watch<PersonnelProvider>();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.template == null ? 'Новый шаблон' : 'Редактировать шаблон'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Название шаблона',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ReorderableListView(
                onReorder: (oldIndex, newIndex) {
                  setState(() {
                    if (newIndex > oldIndex) newIndex--;
                    final item = _stages.removeAt(oldIndex);
                    _stages.insert(newIndex, item);
                  });
                },
                children: [
                  for (int i = 0; i < _stages.length; i++)
                    ListTile(
                      key: ValueKey(_stages[i].stageId),
                      title: Text(personnel.workplaces
                          .firstWhere(
                              (w) => w.id == _stages[i].stageId,
                              orElse: () => WorkplaceModel(
                                  id: _stages[i].stageId,
                                  name: _stages[i].stageName,
                                  positionIds: []))
                          .name),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => setState(() => _stages.removeAt(i)),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _addStage,
                icon: const Icon(Icons.add),
                label: const Text('Добавить этап'),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () async {
                  if (_nameCtrl.text.isEmpty) return;
                  final provider = context.read<TemplateProvider>();
                  if (widget.template == null) {
                    await provider.createTemplate(
                        name: _nameCtrl.text, stages: _stages);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Шаблон создан')));
                    }
                  } else {
                    await provider.updateTemplate(
                        id: widget.template!.id,
                        name: _nameCtrl.text,
                        stages: _stages);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Шаблон обновлён')));
                    }
                  }
                  if (mounted) Navigator.pop(context);
                },
                icon: const Icon(Icons.save),
                label: const Text('Сохранить'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}