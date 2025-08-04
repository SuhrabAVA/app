import 'package:flutter/material.dart';

class FormEditorScreen extends StatefulWidget {
  const FormEditorScreen({super.key});

  @override
  State<FormEditorScreen> createState() => _FormEditorScreenState();
}

class _FormEditorScreenState extends State<FormEditorScreen> {
  bool isRequired = true;
  String fieldType1 = 'Логическое';
  String fieldType2 = 'Строка';
  final fieldTypes = ['Логическое', 'Строка', 'Число'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Редактор формы')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildFieldCard(
              title: 'Наличие ручки',
              fieldName: 'Наличие ручки',
              fieldType: fieldType1,
              helpText: 'Имеется ли ручка в заказе?',
              description: 'В данном П-Пакете должна быть ручка',
              isRequired: isRequired,
              onTypeChanged: (val) => setState(() => fieldType1 = val!),
              onRequiredChanged: (val) => setState(() => isRequired = val),
            ),
            const SizedBox(height: 24),
            _buildFieldCard(
              title: 'Приметы',
              fieldName: 'Особые примечания',
              fieldType: fieldType2,
              helpText: 'Окей',
              description: 'Если есть что добавить — пиши',
              isRequired: false,
              onTypeChanged: (val) => setState(() => fieldType2 = val!),
            ),
            const SizedBox(height: 32),
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.add),
                label: const Text('Добавить поле'),
              ),
            )
          ],
        ),
      ),
    );
  }

  Widget _buildFieldCard({
    required String title,
    required String fieldName,
    required String fieldType,
    required String helpText,
    required String description,
    required bool isRequired,
    required ValueChanged<String?> onTypeChanged,
    ValueChanged<bool>? onRequiredChanged,
  }) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: fieldName,
                    decoration: const InputDecoration(labelText: 'Имя поля'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: fieldType,
                    decoration: const InputDecoration(labelText: 'Тип поля'),
                    items: fieldTypes
                        .map((type) => DropdownMenuItem(value: type, child: Text(type)))
                        .toList(),
                    onChanged: onTypeChanged,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: title,
                    decoration: const InputDecoration(labelText: 'Метка'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    initialValue: helpText,
                    decoration: const InputDecoration(labelText: 'Подсказка'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: description,
              decoration: const InputDecoration(labelText: 'Описание'),
            ),
            if (onRequiredChanged != null)
              SwitchListTile(
                value: isRequired,
                onChanged: onRequiredChanged,
                title: const Text('Обязательное'),
              ),
          ],
        ),
      ),
    );
  }
}
