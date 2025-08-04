import 'package:flutter/material.dart';

class StageEditorScreen extends StatelessWidget {
  const StageEditorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final stageNameController = TextEditingController();
    final stageDescController = TextEditingController();

    return Scaffold(
      appBar: AppBar(title: const Text('Новый этап')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: stageNameController,
              decoration: const InputDecoration(
                labelText: 'Название',
                hintText: 'Введите название этапа',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: stageDescController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Описание',
                hintText: 'Введите описание этапа',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              decoration: const InputDecoration(
                labelText: 'Оборудование / Рабочее место',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'Станок', child: Text('Станок')),
                DropdownMenuItem(value: 'Упаковка', child: Text('Упаковка')),
              ],
              onChanged: (val) {},
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('Временные метки'),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.add),
                  label: const Text('Добавить'),
                ),
              ],
            ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.save_alt),
                label: const Text('Создать этап'),
                style:
                    ElevatedButton.styleFrom(padding: const EdgeInsets.all(14)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
