import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../personnel/personnel_provider.dart';
import 'stage_provider.dart';

class StageEditorScreen extends StatefulWidget {


  const StageEditorScreen({super.key});
  @override
  State<StageEditorScreen> createState() => _StageEditorScreenState();
}

class _StageEditorScreenState extends State<StageEditorScreen> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  String? _selectedWorkplaceId;



  @override
  Widget build(BuildContext context) {
    final personnel = context.watch<PersonnelProvider>();
    final workplaces = personnel.workplaces;


    return Scaffold(
      appBar: AppBar(title: const Text('Новый этап')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Название',
                hintText: 'Введите название этапа',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
               controller: _descCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Описание',
                hintText: 'Введите описание этапа',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _selectedWorkplaceId,
              decoration: const InputDecoration(
                labelText: 'Оборудование / Рабочее место',
                border: OutlineInputBorder(),
              ),
                 items: [
                for (final w in workplaces)
                  DropdownMenuItem(value: w.id, child: Text(w.name)),
                
              ],
              onChanged: (val) => setState(() => _selectedWorkplaceId = val),
            ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  if (_selectedWorkplaceId == null ||
                      _nameCtrl.text.isEmpty) return;
                  context.read<StageProvider>().createStage(
                        name: _nameCtrl.text,
                        description: _descCtrl.text,
                        workplaceId: _selectedWorkplaceId!,
                      );
                  Navigator.pop(context);
                },
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