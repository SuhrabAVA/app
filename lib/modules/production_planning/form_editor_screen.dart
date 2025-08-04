import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:provider/provider.dart';

import '../orders/order_model.dart';
import 'planned_stage_model.dart';
import 'stage_provider.dart';

class FormEditorScreen extends StatefulWidget {
  final OrderModel order;
  const FormEditorScreen({super.key, required this.order});

  @override
  State<FormEditorScreen> createState() => _FormEditorScreenState();
}

class _FormEditorScreenState extends State<FormEditorScreen> {
  final List<PlannedStage> _stages = [];
  final _plansRef = FirebaseDatabase.instance.ref('production_plans');
  String? _photoUrl;

  @override
  void initState() {
    super.initState();
    _loadExistingPlan();
  }

  Future<void> _loadExistingPlan() async {
    final snapshot = await _plansRef.child(widget.order.id).get();
    if (!snapshot.exists) return;

    final value = snapshot.value;
    Map<String, dynamic> data = {};
    if (value is Map) {
      data = Map<String, dynamic>.from(value as Map);
    }

    final loaded = <PlannedStage>[];
    final stagesData = data['stages'];
    if (stagesData is List) {
      for (final item in stagesData) {
        if (item is Map) {
          loaded.add(PlannedStage.fromMap(Map<String, dynamic>.from(item)));
        }
      }
    } else if (stagesData is Map) {
      stagesData.forEach((_, value) {
        if (value is Map) {
          loaded.add(PlannedStage.fromMap(Map<String, dynamic>.from(value)));
        }
      });
    }

    setState(() {
      _stages..clear()..addAll(loaded);
      _photoUrl = data['photoUrl'] as String?;
    });
  }

  Future<void> _addStage() async {
    final provider = context.read<StageProvider>();
    String? selectedId;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Выберите этап'),
        content: DropdownButtonFormField<String>(
          items: [
            for (final s in provider.stages)
              DropdownMenuItem(value: s.id, child: Text(s.name)),
          ],
          onChanged: (val) => selectedId = val,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
            },
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
    if (selectedId != null) {
      setState(() {
        _stages.add(PlannedStage(stageId: selectedId!));
      });
    }
  }

  Future<void> _pickOrderImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final file = File(picked.path);
    final ref = FirebaseStorage.instance.ref(
        'plan_photos/${widget.order.id}/${DateTime.now().millisecondsSinceEpoch}.jpg');
    await ref.putFile(file);
    final url = await ref.getDownloadURL();
    if (!mounted) return;
    setState(() {
      _photoUrl = url;
    });
  }

  Future<void> _save() async {
    if (_stages.isEmpty && _photoUrl == null) return;
    final plan = <String, dynamic>{};
    if (_stages.isNotEmpty) {
      plan['stages'] = _stages.map((s) => s.toMap()).toList();
    }
    if (_photoUrl != null) plan['photoUrl'] = _photoUrl;
    await _plansRef.child(widget.order.id).set(plan);

    // Синхронизируем задачи для этого заказа, чтобы они отображались
    // в рабочем пространстве сотрудников.
    final tasksRef = FirebaseDatabase.instance.ref('tasks');
    final existing = await tasksRef
        .orderByChild('orderId')
        .equalTo(widget.order.id)
        .get();
    final value = existing.value;
    if (value is Map) {
      final map = Map<dynamic, dynamic>.from(value);
      for (final key in map.keys) {
        await tasksRef.child(key.toString()).remove();
      }
    }

    for (final stage in _stages) {
      final newTaskRef = tasksRef.push();
      await newTaskRef.set({
        'orderId': widget.order.id,
        'stageId': stage.stageId,
        'status': 'waiting',
        'spentSeconds': 0,
      });
    }

    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final stageProvider = context.watch<StageProvider>();
    return Scaffold(
      appBar: AppBar(title: Text('План для ${widget.order.id}')),
      body: Column(
        children: [
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
                  _buildStageCard(i, stageProvider),
              ],
            ),
          ),
          if (_photoUrl != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Image.network(_photoUrl!, height: 100),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
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
                    onPressed: _pickOrderImage,
                    icon: const Icon(Icons.image),
                    label: const Text('Добавить фото'),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save),
                    label: const Text('Сохранить'),
                  ),
                ),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildStageCard(int index, StageProvider provider) {
    final planned = _stages[index];
    final stage = provider.stages.firstWhere((s) => s.id == planned.stageId);
    return Card(
      key: ValueKey(planned.stageId),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            Text(stage.name, style: const TextStyle(fontWeight: FontWeight.bold)),
            TextFormField(
              initialValue: planned.comment,
              decoration: const InputDecoration(labelText: 'Комментарий'),
              onChanged: (val) => setState(
                  () => _stages[index] = _stages[index].copyWith(comment: val)),
            ),
          ],
        ),
      ),
    );
  }
}
