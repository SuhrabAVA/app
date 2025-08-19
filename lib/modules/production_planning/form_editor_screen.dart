import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:provider/provider.dart';

import '../orders/order_model.dart';
import '../orders/orders_provider.dart';
import '../personnel/personnel_provider.dart';
import 'planned_stage_model.dart';
import 'template_provider.dart';
import 'template_model.dart';

/// A form editor for building and saving a production plan for a specific order.
///
/// This widget allows the technical leader to compose a list of stages for an
/// order, attach an optional photo and persist the plan to Firebase. It
/// supports reordering stages, deleting stages, adding stages from the list
/// of available workplaces or templates, and uploading a reference image. When the plan
/// is saved, corresponding tasks are synchronised in the `tasks` collection
/// so that employees see the updated stages in their workspace. Even if
/// there are no stages and no photo, saving will clear any existing plan
/// and associated tasks to reflect that the order has no current plan.
class FormEditorScreen extends StatefulWidget {
  final OrderModel order;
  const FormEditorScreen({super.key, required this.order});

  @override
  State<FormEditorScreen> createState() => _FormEditorScreenState();
}

class _FormEditorScreenState extends State<FormEditorScreen> {
  final List<PlannedStage> _stages = [];
    final SupabaseClient _supabase = Supabase.instance.client;
  String? _photoUrl;

  @override
  void initState() {
    super.initState();
    _loadExistingPlan();
  }
Future<void> _pickOrderImage() async {
  final picker = ImagePicker();
  final picked = await picker.pickImage(source: ImageSource.gallery);
  if (picked == null) return;

  final storage = _supabase.storage.from('order_photos');
  final path = '${widget.order.id}.jpg';
  await storage.upload(path, File(picked.path));
  final url = storage.getPublicUrl(path);

  setState(() {
    _photoUrl = url;
  });
}

  /// Loads an existing plan from Firebase if one exists for the current order.
  Future<void> _loadExistingPlan() async {
    final data = await _supabase
        .from('production_plans')
        .select()
        .eq('order_id', widget.order.id)
        .maybeSingle();
    if (data == null) return;
    final loaded = decodePlannedStages(data['stages']);
    if (!mounted) return;
    setState(() {
      _stages
        ..clear()
        ..addAll(loaded);
      _photoUrl = data['photo_url'] as String?;
    });
  }

  /// Opens a dialog to pick a workplace and add it to the plan.
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
      final stage =
          personnel.workplaces.firstWhere((w) => w.id == selectedId);
      setState(() {
        _stages
            .add(PlannedStage(stageId: stage.id, stageName: stage.name));
      });
    }
  }

  /// Applies a predefined template of stages to the current plan.
  Future<void> _applyTemplate() async {
    final provider = context.read<TemplateProvider>();
    String? templateId;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Выберите шаблон'),
        content: DropdownButtonFormField<String>(
          items: [
            for (final t in provider.templates)
              DropdownMenuItem(value: t.id, child: Text(t.name)),
          ],
          onChanged: (val) => templateId = val,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Загрузить'),
          ),
        ],
      ),
    );
    if (templateId != null) {
      final TemplateModel tpl =
          provider.templates.firstWhere((t) => t.id == templateId);
      setState(() {
        _stages
          ..clear()
          ..addAll(tpl.stages
              .map((s) => PlannedStage(stageId: s.stageId, stageName: s.stageName)));
      });
    }
  }

  /// Allows the user to pick an image from their gallery, upload it and store
  /// the download URL. This is optional metadata for the plan.
  

  /// Persists the current list of stages and optional photo to Firebase. Also
  /// synchronises tasks for employees based on these stages. When no stages
  /// remain, all existing tasks for this order are removed, and an empty plan
  /// is written so that the absence of a plan is reflected in Firebase.
  Future<void> _save() async {
    final orderId = widget.order.id;

    final stageMaps = _stages.map((stage) => stage.toMap()).toList();
    await _supabase.from('production_plans').upsert({
      'order_id': orderId,
      'stages': stageMaps,
      if (_photoUrl != null) 'photo_url': _photoUrl,
    }, onConflict: 'order_id');
    
    await _supabase.from('tasks').delete().eq('orderId', orderId);

    for (final stage in _stages) {
      final taskId = const Uuid().v4();
      await _supabase.from('tasks').insert({
        'id': taskId,
        'orderId': orderId,
        'stageId': stage.stageId,
        'status': 'waiting',
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      });
    }

    // После сохранения плана и создания задач формируем идентификатор производственного
    // задания (ЗК-...) и обновляем статус заказа на inWork. Если задание ранее
    // не создавалось (assignmentCreated == false), генерируем новый id. Далее
    // сохраняем обновлённую модель через OrdersProvider.
    final ordersProvider = context.read<OrdersProvider>();
    String? assignmentId = widget.order.assignmentId;
    bool assignmentCreated = widget.order.assignmentCreated;
    if (!assignmentCreated) {
      assignmentId = ordersProvider.generateAssignmentId();
      assignmentCreated = true;
    }
    final updatedOrder = OrderModel(
      id: widget.order.id,
      customer: widget.order.customer,
      orderDate: widget.order.orderDate,
      dueDate: widget.order.dueDate,
      products: widget.order.products,
      contractSigned: widget.order.contractSigned,
      paymentDone: widget.order.paymentDone,
      comments: widget.order.comments,
      status: OrderStatus.inWork,
      assignmentId: assignmentId,
      assignmentCreated: assignmentCreated,
    );
    await ordersProvider.updateOrder(updatedOrder);

    if (mounted) {
      Navigator.of(context).pop();
    }
  }


  @override
  Widget build(BuildContext context) {
    final personnel = context.watch<PersonnelProvider>();
    return Scaffold(
      appBar: AppBar(title: Text('План для ${widget.order.id}')),
      body: Column(
        children: [
          // Reorderable list of stages with delete buttons.
          Expanded(
  child: Column(
    children: [
      if (_photoUrl != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Image.network(_photoUrl!, height: 100),
        ),
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
              _buildStageCard(i, personnel),
          ],
        ),
      ),
    ],
  ),
),

          // Show a thumbnail of the selected photo if available.
          
          // Action buttons: add stage, add photo, and save plan.
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
                    onPressed: _applyTemplate,
                    icon: const Icon(Icons.list),
                    label: const Text('Применить шаблон'),
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
                    onPressed: () async {
                      await _save();
                    },
                    icon: const Icon(Icons.save),
                    label: const Text('Сохранить'),
                  ),
                ),
                if (_photoUrl != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Image.network(_photoUrl!, height: 100),
            ),
              ],
            ),
          )
          
        ],
        
      ),
    );
  }

  /// Builds a card for a single stage with a delete button and reorder handle.
  Widget _buildStageCard(int index, PersonnelProvider personnel) {
    final planned = _stages[index];
    final match =
        personnel.workplaces.where((w) => w.id == planned.stageId);
    final name = match.isNotEmpty ? match.first.name : planned.stageName;
    return Card(
      key: ValueKey(planned.stageId),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Stage name displayed prominently.
                Expanded(
                  child: Text(
                    name,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                // Delete stage button.
                IconButton(
                  tooltip: 'Удалить этап',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () {
                    setState(() {
                      _stages.removeAt(index);
                    });
                  },
                ),
                // Visual reorder handle (tap and hold to drag).
                const Icon(Icons.drag_handle, size: 20),
              ],
            ),
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