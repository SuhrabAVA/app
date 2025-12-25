import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'template_model.dart';
import '../personnel/personnel_provider.dart';
import '../personnel/workplace_model.dart';
import 'planned_stage_model.dart';
import 'template_provider.dart';

class TemplateEditorScreen extends StatefulWidget {
  final TemplateModel? template; // Важно: параметр называется template
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
      _stages.addAll(tpl.stages.map(
        (s) => PlannedStage(
          stageId: s.stageId,
          stageName: s.stageName,
          alternativeStageIds: s.alternativeStageIds,
          alternativeStageNames: s.alternativeStageNames,
          comment: s.comment,
        ),
      ));
    }
  }

  Future<void> _addStage() async {
    final personnel = context.read<PersonnelProvider>();
    final Set<String> selectedIds = {};

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text('Выберите этапы'),
              content: SizedBox(
                width: 480,
                child: ListView(
                  shrinkWrap: true,
                  children: personnel.workplaces.map((WorkplaceModel w) {
                    final checked = selectedIds.contains(w.id);
                    return CheckboxListTile(
                      value: checked,
                      title: Text(w.name),
                      onChanged: (v) {
                        setStateDialog(() {
                          if (v == true) {
                            selectedIds.add(w.id);
                          } else {
                            selectedIds.remove(w.id);
                          }
                        });
                      },
                    );
                  }).toList(),
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
                FilledButton(
                  onPressed: () {
                    if (selectedIds.isEmpty) return;
                    final selected = personnel.workplaces
                        .where((e) => selectedIds.contains(e.id))
                        .toList();
                    final primary = selected.first;
                    final alternatives = selected.skip(1).toList();
                    setState(() {
                      _stages.add(
                        PlannedStage(
                          stageId: primary.id,
                          stageName: primary.name,
                          alternativeStageIds: alternatives.map((e) => e.id).toList(),
                          alternativeStageNames: alternatives.map((e) => e.name).toList(),
                        ),
                      );
                    });
                    Navigator.pop(ctx);
                  },
                  child: const Text('Добавить'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Введите название')));
      return;
    }
    if (_stages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Добавьте хотя бы один этап')));
      return;
    }

    final provider = context.read<TemplateProvider>();

    if (widget.template == null) {
      await provider.createTemplate(name: name, stages: _stages);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Шаблон создан')));
      }
    } else {
      await provider.updateTemplate(id: widget.template!.id, name: name, stages: _stages);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Шаблон обновлён')));
      }
    }
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.template == null ? 'Новый шаблон' : 'Редактировать шаблон')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Название шаблона',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              itemCount: _stages.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final s = _stages[i];
                final stageNames = s.allStageNames;
                return ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: Theme.of(context).dividerColor),
                  ),
                  title: Text(stageNames.join(' / ')),
                  subtitle: s.comment?.isNotEmpty == true ? Text(s.comment!) : null,
                  trailing: IconButton(
                    tooltip: 'Удалить',
                    onPressed: () => setState(() => _stages.removeAt(i)),
                    icon: const Icon(Icons.delete_outline),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: _addStage,
                    child: const Text('Добавить этап'),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save),
                    label: const Text('Сохранить'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
