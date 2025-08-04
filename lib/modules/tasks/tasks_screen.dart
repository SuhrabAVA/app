import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../orders/order_model.dart';
import '../orders/orders_provider.dart';
import '../personnel/employee_model.dart';
import '../personnel/personnel_provider.dart';
import '../personnel/workplace_model.dart';
import '../production_planning/stage_model.dart';
import '../production_planning/stage_provider.dart';
import 'task_model.dart';
import 'task_provider.dart';

class TasksScreen extends StatefulWidget {
  final String employeeId;
  const TasksScreen({super.key, required this.employeeId});

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  String? _selectedWorkplaceId;
  TaskModel? _selectedTask;

  @override
  Widget build(BuildContext context) {
    final personnel = context.watch<PersonnelProvider>();
    final stageProvider = context.watch<StageProvider>();
    final ordersProvider = context.watch<OrdersProvider>();
    final taskProvider = context.watch<TaskProvider>();

    final EmployeeModel employee = personnel.employees.firstWhere(
      (e) => e.id == widget.employeeId,
      orElse: () => EmployeeModel(
        id: '',
        lastName: '',
        firstName: '',
        patronymic: '',
        iin: '',
        positionIds: [],
      ),
    );

    final workplaces = personnel.workplaces
        .where((w) => w.positionIds
            .any((p) => employee.positionIds.contains(p)))
        .toList();
    if (_selectedWorkplaceId == null && workplaces.isNotEmpty) {
      _selectedWorkplaceId = workplaces.first.id;
    }

    StageModel? findStage(String id) {
      for (final s in stageProvider.stages) {
        if (s.id == id) return s;
      }
      return null;
    }

    OrderModel? findOrder(String id) {
      for (final o in ordersProvider.orders) {
        if (o.id == id) return o;
      }
      return null;
    }

    final tasks = taskProvider.tasks.where((t) {
      final stage = findStage(t.stageId);
      return stage != null && stage.workplaceId == _selectedWorkplaceId;
    }).toList();

    final currentTask = _selectedTask != null
        ? taskProvider.tasks.firstWhere(
            (t) => t.id == _selectedTask!.id,
            orElse: () => _selectedTask!,
          )
        : null;

    final selectedStage =
        currentTask != null ? findStage(currentTask.stageId) : null;
    final selectedOrder =
        currentTask != null ? findOrder(currentTask.orderId) : null;

    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text('Производственный терминал'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0.5,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Рабочее место:'),
                  const SizedBox(height: 8),
                  DropdownButton<String>(
                    value: _selectedWorkplaceId,
                    items: [
                      for (final w in workplaces)
                        DropdownMenuItem(
                            value: w.id, child: Text(w.name)),
                    ],
                    onChanged: (val) {
                      setState(() {
                        _selectedWorkplaceId = val;
                        _selectedTask = null;
                      });
                    },
                  ),
                  const SizedBox(height: 24),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.grey.shade300,
                            blurRadius: 6,
                          )
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Список заданий',
                              style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Text(
                            _selectedWorkplaceId == null
                                ? ''
                                : 'Задания для рабочего места: ' +
                                    (workplaces
                                            .firstWhere(
                                                (w) =>
                                                    w.id ==
                                                    _selectedWorkplaceId,
                                                orElse: () =>
                                                    WorkplaceModel(
                                                        id: '',
                                                        name: '',
                                                        positionIds: []))
                                            .name),
                            style: const TextStyle(color: Colors.grey),
                          ),
                          const SizedBox(height: 12),
                          Expanded(
                            child: ListView(
                              children: [
                                for (final task in tasks)
                                  _TaskCard(
                                    task: task,
                                    order: findOrder(task.orderId),
                                    selected: _selectedTask?.id == task.id,
                                    onTap: () {
                                      setState(() {
                                        _selectedTask = task;
                                      });
                                    },
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (currentTask != null &&
                      selectedStage != null &&
                      selectedOrder != null)
                    _buildDetailsPanel(selectedOrder, selectedStage),
                  if (currentTask != null &&
                      selectedStage != null)
                    const SizedBox(height: 16),
                  if (currentTask != null &&
                      selectedStage != null)
                    _buildControlPanel(
                        currentTask, selectedStage, taskProvider),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailsPanel(OrderModel order, StageModel stage) {
    final product = order.products.isNotEmpty ? order.products.first : null;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(order.id,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                const Text('Детали производственного задания'),
                const SizedBox(height: 16),
                const Text('Информация о продукте',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                if (product != null) ...[
                  Text('Продукт: ${product.type}'),
                  Text('Тираж: ${product.quantity} шт.'),
                  Text(
                      'Размер: ${product.width}x${product.depth}x${product.height} мм'),
                ],
                Text('Заказчик: ${order.customer}'),
              ],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 36),
                const Text('Этап производства',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                Text(stage.name),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlPanel(
      TaskModel task, StageModel stage, TaskProvider provider) {
    final canStart =
        task.status == TaskStatus.waiting || task.status == TaskStatus.paused;
    final canPause = task.status == TaskStatus.inProgress;
    final canFinish =
        task.status == TaskStatus.inProgress || task.status == TaskStatus.paused;
    final canProblem = task.status == TaskStatus.inProgress;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Управление заданием',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          Text('Текущий этап: ${stage.name}'),
          const SizedBox(height: 12),
          Center(
            child: StreamBuilder<DateTime>(
              stream: Stream.periodic(const Duration(seconds: 1), (_) => DateTime.now()),
              builder: (context, snapshot) {
                final d = _elapsed(task);
                return Text(_formatDuration(d),
                    style: const TextStyle(
                        fontSize: 28, fontWeight: FontWeight.bold));
              },
            ),
          ),
          const Center(child: Text('Затраченное время')),
          const SizedBox(height: 12),
          Row(
            children: [
              ElevatedButton(
                onPressed: canStart
                    ? () {
                        provider.updateStatus(task.id, TaskStatus.inProgress,
                            startedAt:
                                DateTime.now().millisecondsSinceEpoch);
                      }
                    : null,
                child: const Text('▶ Начать'),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: canPause
                    ? () {
                        provider.updateStatus(task.id, TaskStatus.paused,
                            spentSeconds: _elapsed(task).inSeconds,
                            startedAt: null);
                      }
                    : null,
                child: const Text('⏸ Пауза'),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: canFinish
                    ? () {
                        provider.updateStatus(task.id, TaskStatus.completed,
                            spentSeconds: _elapsed(task).inSeconds,
                            startedAt: null);
                      }
                    : null,
                child: const Text('✓ Завершить'),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: canProblem
                    ? () {
                        provider.updateStatus(task.id, TaskStatus.problem,
                            spentSeconds: _elapsed(task).inSeconds,
                            startedAt: null);
                      }
                    : null,
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent),
                child: const Text('🚨 Проблема'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text('Комментарии к этапу'),
          const TextField(
            decoration:
                InputDecoration(hintText: 'Добавьте комментарии или заметки...'),
            maxLines: 2,
          ),
        ],
      ),
    );
  }

  Duration _elapsed(TaskModel task) {
    var seconds = task.spentSeconds;
    if (task.status == TaskStatus.inProgress && task.startedAt != null) {
      seconds +=
          (DateTime.now().millisecondsSinceEpoch - task.startedAt!) ~/ 1000;
    }
    return Duration(seconds: seconds);
  }

  String _formatDuration(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  }
}

class _TaskCard extends StatelessWidget {
  final TaskModel task;
  final OrderModel? order;
  final bool selected;
  final VoidCallback onTap;

  const _TaskCard({
    required this.task,
    required this.order,
    required this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(task.status);
    final name = order?.products.isNotEmpty == true
        ? order!.products.first.type
        : '';
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
            color: selected ? Colors.blue : color.withOpacity(0.5)),
      ),
      child: ListTile(
        onTap: onTap,
        title: Text(order?.id ?? task.orderId),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name),
          ],
        ),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: color.withOpacity(0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(_statusText(task.status),
              style:
                  TextStyle(color: color, fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }
}

Color _statusColor(TaskStatus status) {
  switch (status) {
    case TaskStatus.waiting:
      return Colors.amber;
    case TaskStatus.inProgress:
      return Colors.blue;
    case TaskStatus.paused:
      return Colors.grey;
    case TaskStatus.completed:
      return Colors.green;
    case TaskStatus.problem:
      return Colors.redAccent;
  }
}

String _statusText(TaskStatus status) {
  switch (status) {
    case TaskStatus.waiting:
      return 'Ожидает';
    case TaskStatus.inProgress:
      return 'В работе';
    case TaskStatus.paused:
      return 'Пауза';
    case TaskStatus.completed:
      return 'Завершено';
    case TaskStatus.problem:
      return 'Проблема';
  }
}
