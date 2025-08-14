import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../orders/order_model.dart';
import '../orders/orders_provider.dart';
import 'planned_stage_model.dart';
import 'stage_provider.dart';

/// A form editor for building and saving a production plan for a specific order.
///
/// This widget allows the technical leader to compose a list of stages for an
/// order, attach an optional photo and persist the plan to Supabase. It
/// supports reordering stages, deleting stages, adding stages from the list
/// defined in [StageProvider], and uploading a reference image. When the plan
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

  /// Loads an existing plan from Supabase if one exists for the current order.
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

  /// Opens a dialog to pick a stage from [StageProvider] and add it to the plan.
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
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
    if (selectedId != null) {
      final stage = provider.stages.firstWhere((s) => s.id == selectedId);
      setState(() {
        _stages.add(PlannedStage(stageId: selectedId!, stageName: stage.name));
      });
    }
  }

  /// Allows the user to pick an image from their gallery, upload it and store
  /// the download URL. This is optional metadata for the plan.
  

  /// Persists the current list of stages and optional photo to Supabase. Also
  /// synchronises tasks for employees based on these stages. When no stages
  /// remain, all existing tasks for this order are removed, and an empty plan
  /// is written so that the absence of a plan is reflected in Supabase.
  Future<void> _save() async {
    final orderId = widget.order.id;

    final stageMaps = _stages.map((stage) => stage.toMap()).toList();
    await _supabase.from('production_plans').upsert({
      'order_id': orderId,
      'stages': stageMaps,
      if (_photoUrl != null) 'photo_url': _photoUrl,
    });

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
    ordersProvider.updateOrder(updatedOrder);

    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final stageProvider = context.watch<StageProvider>();
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
              _buildStageCard(i, stageProvider),
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
  Widget _buildStageCard(int index, StageProvider provider) {
    final planned = _stages[index];
    final match = provider.stages.where((s) => s.id == planned.stageId);
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