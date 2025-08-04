import 'package:flutter/material.dart';

class FormPreviewScreen extends StatelessWidget {
  const FormPreviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    bool hasHandle = false;
    final noteController = TextEditingController(text: 'Окей');

    return Scaffold(
      appBar: AppBar(title: const Text('Предпросмотр формы')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Наличие ручки *',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('В Даном П-Пакете должна быть ручка',
                style: TextStyle(fontSize: 12)),
            Row(
              children: [
                StatefulBuilder(
                  builder: (context, setState) => Switch(
                    value: hasHandle,
                    onChanged: (val) => setState(() => hasHandle = val),
                  ),
                ),
                const Text('Имеется ли ручка в заказе?'),
              ],
            ),
            const SizedBox(height: 24),
            const Text('Приметы',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('Если есть что добавить – пиши',
                style: TextStyle(fontSize: 12)),
            const SizedBox(height: 4),
            TextField(
              controller: noteController,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            const SizedBox(height: 24),
            Center(
              child: ElevatedButton(
                onPressed: () {},
                style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 40, vertical: 14)),
                child: const Text('Отправить'),
              ),
            )
          ],
        ),
      ),
    );
  }
}
