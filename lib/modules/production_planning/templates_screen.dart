import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'template_editor_screen.dart';
import 'template_provider.dart';
import 'template_model.dart';

class TemplatesScreen extends StatelessWidget {
  const TemplatesScreen({super.key});

  void _openEditor(BuildContext context, [TemplateModel? template]) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TemplateEditorScreen(template: template),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final templates = context.watch<TemplateProvider>().templates;
    return Scaffold(
      appBar: AppBar(title: const Text('Шаблоны')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openEditor(context),
        child: const Icon(Icons.add),
        tooltip: 'Создать шаблон',
      ),
      body: templates.isEmpty
          ? const Center(child: Text('Шаблоны отсутствуют'))
          : ListView.builder(
              itemCount: templates.length,
              itemBuilder: (context, index) {
                final tpl = templates[index];
                return ListTile(
                  title: Text(tpl.name),
                  onTap: () => _openEditor(context, tpl),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Удалить шаблон?'),
                          content: Text('Вы уверены, что хотите удалить "${tpl.name}"?'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('Отмена'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('Удалить'),
                            ),
                          ],
                        ),
                      );
                      if (confirm == true) {
                        try {
                          await context.read<TemplateProvider>().deleteTemplate(tpl.id);
                        } on TemplateDeleteException catch (e) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context)
                              .showSnackBar(SnackBar(content: Text(e.message)));
                        }
                      }
                    },
                  ),
                );
              },
            ),
    );
  }
}
