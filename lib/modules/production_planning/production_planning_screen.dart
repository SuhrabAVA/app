import 'package:flutter/material.dart';
import 'form_editor_screen.dart';
import 'form_preview_screen.dart';
import 'stage_editor_screen.dart';

class ProductionPlanningScreen extends StatelessWidget {
  const ProductionPlanningScreen({super.key});

  void _open(BuildContext context, Widget page) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Планирование производства')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton(
              onPressed: () => _open(context, const StageEditorScreen()),
              child: const Text('Создать этап'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => _open(context, const FormEditorScreen()),
              child: const Text('Редактор формы'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => _open(context, const FormPreviewScreen()),
              child: const Text('Предпросмотр формы'),
            ),
          ],
        ),
      ),
    );
  }
}
