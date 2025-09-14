import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../orders/order_model.dart';
import '../orders/orders_provider.dart';
import '../personnel/employee_model.dart';
import '../personnel/personnel_provider.dart';
import '../personnel/workplace_model.dart';
import '../analytics/analytics_provider.dart';
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
        positionIds: const [],
      ),
    );

    final workplaces = personnel.workplaces
        .where(
            (w) => w.positionIds.any((p) => employee.positionIds.contains(p)))
        .toList();

    if (_selectedWorkplaceId == null && workplaces.isNotEmpty) {
      _selectedWorkplaceId = workplaces.first.id;
    }

    OrderModel? findOrder(String id) {
      for (final o in ordersProvider.orders) {
        if (o.id == id) return o;
      }
      return null;
    }

    final tasks = taskProvider.tasks
        .where((t) => t.stageId == _selectedWorkplaceId)
        .toList();

    final currentTask = _selectedTask != null
        ? taskProvider.tasks.firstWhere(
            (t) => t.id == _selectedTask!.id,
            orElse: () => _selectedTask!,
          )
        : null;

    final selectedWorkplace = currentTask != null
        ? personnel.workplaces.firstWhere(
            (w) => w.id == currentTask.stageId,
            orElse: () =>
                WorkplaceModel(id: '', name: '', positionIds: const []),
          )
        : null;

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
            // ===== Левая колонка: список задач + выбор рабочего места
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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
                          const Text(
                            'Список заданий',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _selectedWorkplaceId == null
                                ? ''
                                : 'Задания для рабочего места: '
                                    '${workplaces.firstWhere(
                                          (w) => w.id == _selectedWorkplaceId,
                                          orElse: () => WorkplaceModel(
                                            id: '',
                                            name: '',
                                            positionIds: const [],
                                          ),
                                        ).name}',
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
                  const SizedBox(height: 24),
                  const Text('Рабочее место:'),
                  const SizedBox(height: 8),
                  DropdownButton<String>(
                    value: _selectedWorkplaceId,
                    items: [
                      for (final w in workplaces)
                        DropdownMenuItem(value: w.id, child: Text(w.name)),
                    ],
                    onChanged: (val) {
                      setState(() {
                        _selectedWorkplaceId = val;
                        _selectedTask = null;
                      });
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),

            // ===== Правая колонка: детали + панель управления
            Expanded(
              flex: 5,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (currentTask != null &&
                        selectedWorkplace != null &&
                        selectedOrder != null)
                      _buildDetailsPanel(selectedOrder, selectedWorkplace),
                    if (currentTask != null && selectedWorkplace != null)
                      const SizedBox(height: 16),
                    if (currentTask != null && selectedWorkplace != null)
                      _buildControlPanel(
                          currentTask, selectedWorkplace, taskProvider),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailsPanel(OrderModel order, WorkplaceModel stage) {
    final product = order.product;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      order.assignmentId ?? order.id,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    const Text('Детали производственного задания'),
                    const SizedBox(height: 16),
                    const Text('Информация о продукте',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    Text('Продукт: ${product.type}'),
                    Text('Тираж: ${product.quantity} шт.'),
                    Text(
                        'Размер: ${product.width}x${product.depth}x${product.height} мм'),
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
          const SizedBox(height: 12),
          _buildStageList(order),
        ],
      ),
    );
  }

  /// Список этапов производства с иконками выполнено/ожидание.
  Widget _buildStageList(OrderModel order) {
    final taskProvider = context.read<TaskProvider>();
    final personnel = context.read<PersonnelProvider>();
    final tasksForOrder =
        taskProvider.tasks.where((t) => t.orderId == order.id).toList();

    final stageIds = <String>{};
    for (final t in tasksForOrder) {
      stageIds.add(t.stageId);
    }
    if (stageIds.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Этапы производства',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        for (final id in stageIds)
          Builder(
            builder: (context) {
              final stage = personnel.workplaces.firstWhere(
                (w) => w.id == id,
                orElse: () =>
                    WorkplaceModel(id: id, name: id, positionIds: const []),
              );
              final stageTasks =
                  tasksForOrder.where((t) => t.stageId == id).toList();
              final completed = stageTasks.isNotEmpty &&
                  stageTasks.every((t) => t.status == TaskStatus.completed);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(
                      completed ? Icons.check_circle : Icons.access_time,
                      size: 16,
                      color: completed ? Colors.green : Colors.orange,
                    ),
                    const SizedBox(width: 4),
                    Text(stage.name, style: const TextStyle(fontSize: 14)),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _buildControlPanel(
      TaskModel task, WorkplaceModel stage, TaskProvider provider) {
    final bool takenByAnother = task.status == TaskStatus.inProgress &&
        task.assignees.isNotEmpty &&
        !task.assignees.contains(widget.employeeId);

    final canStart = !takenByAnother &&
        (task.status == TaskStatus.waiting ||
            task.status == TaskStatus.paused ||
            task.status == TaskStatus.problem);

    final canPause = !takenByAnother && task.status == TaskStatus.inProgress;

    final canFinish = !takenByAnother &&
        (task.status == TaskStatus.inProgress ||
            task.status == TaskStatus.paused ||
            task.status == TaskStatus.problem);

    final canProblem = !takenByAnother && task.status == TaskStatus.inProgress;

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Управление заданием',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          Text('Текущий этап: ${stage.name}',
              style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 6),
          _AssignedEmployeesRow(task: task),
          const SizedBox(height: 6),
          Center(
            child: StreamBuilder<DateTime>(
              stream: Stream.periodic(
                  const Duration(seconds: 1), (_) => DateTime.now()),
              builder: (context, snapshot) {
                final d = _elapsed(task);
                return Text(
                  _formatDuration(d),
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold),
                );
              },
            ),
          ),
          const Center(
              child: Text('Затраченное время', style: TextStyle(fontSize: 12))),
          const SizedBox(height: 6),
          Row(
            children: [
              if (_hasMachineForStage(stage)) ...[
                Row(
                  children: [
                    ElevatedButton.icon(
                      onPressed:
                          !_isSetupCompletedForUser(task, widget.employeeId)
                              ? () => _startSetup(task, provider)
                              : null,
                      icon: const Icon(Icons.build),
                      label: const Text('Настройка станка'),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed:
                          _isSetupCompletedForUser(task, widget.employeeId)
                              ? null
                              : () => _finishSetup(task, provider),
                      child: const Text('Завершить настройку станка'),
                    ),
                  ],
                ),
                const SizedBox(width: 8),
              ],

              // ▶ Начать
              ElevatedButton(
                onPressed: canStart
                    ? () async {
                        final analytics = context.read<AnalyticsProvider>();
                        final isResume = task.status == TaskStatus.paused ||
                            task.status == TaskStatus.problem;

                        await provider.updateStatus(
                          task.id,
                          TaskStatus.inProgress,
                          startedAt: DateTime.now().millisecondsSinceEpoch,
                        );

                        if (!task.assignees.contains(widget.employeeId)) {
                          String mode = 'helper';
                          if (task.status == TaskStatus.inProgress &&
                              task.assignees.isNotEmpty) {
                            final sel = await _askJoinMode(context);
                            if (sel != null) mode = sel;
                          }

                          if (mode == 'helper') {
                            final newAssignees =
                                List<String>.from(task.assignees)
                                  ..add(widget.employeeId);
                            await provider.updateAssignees(
                                task.id, newAssignees);
                          } else {
                            // параллельная задача для пользователя (если метода нет — fallback)
                            try {
                              await (provider as dynamic)
                                  .cloneTaskForUser(task, widget.employeeId);
                            } catch (_) {
                              final fallback = List<String>.from(task.assignees)
                                ..add(widget.employeeId);
                              await provider.updateAssignees(task.id, fallback);
                            }
                          }
                        }

                        await analytics.logEvent(
                          orderId: task.orderId,
                          stageId: task.stageId,
                          userId: widget.employeeId,
                          action: isResume ? 'resume' : 'start',
                          category: 'production',
                        );
                      }
                    : null,
                child: const Text('▶ Начать'),
              ),
              const SizedBox(width: 8),

              // ⏸ Пауза
              ElevatedButton(
                onPressed: canPause ? () => _handlePause(task, provider) : null,
                child: const Text('⏸ Пауза'),
              ),
              const SizedBox(width: 8),

              // ✓ Завершить
              ElevatedButton(
                onPressed: canFinish
                    ? () async {
                        final analytics = context.read<AnalyticsProvider>();
                        await provider.updateStatus(
                          task.id,
                          TaskStatus.completed,
                          spentSeconds: _elapsed(task).inSeconds,
                          startedAt: null,
                        );
                        await analytics.logEvent(
                          orderId: task.orderId,
                          stageId: task.stageId,
                          userId: widget.employeeId,
                          action: 'finish',
                          category: 'production',
                        );
                      }
                    : null,
                child: const Text('✓ Завершить'),
              ),
              const SizedBox(width: 8),

              // 🚨 Проблема
              ElevatedButton(
                onPressed:
                    canProblem ? () => _handleProblem(task, provider) : null,
                style:
                    ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                child: const Text('🚨 Проблема'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text('Комментарии к этапу',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Builder(
            builder: (context) {
              final comments = task.comments;
              if (comments.isEmpty) {
                return const Text('Нет комментариев',
                    style: TextStyle(color: Colors.grey));
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final c in comments)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            c.type == 'problem'
                                ? Icons.error_outline
                                : (c.type == 'pause'
                                    ? Icons.pause_circle_outline
                                    : Icons.info_outline),
                            size: 18,
                            color: c.type == 'problem'
                                ? Colors.redAccent
                                : (c.type == 'pause'
                                    ? Colors.orange
                                    : Colors.blueGrey),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              c.text,
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
          if (takenByAnother)
            Padding(
              padding: const EdgeInsets.only(top: 12.0),
              child: Text(
                'Задание выполняется другим сотрудником',
                style: TextStyle(color: Colors.red.shade700, fontSize: 14),
              ),
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

  Future<String?> _askComment(String title) async {
    final controller = TextEditingController();
    return showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Укажите причину'),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () {
              final text = controller.text.trim();
              Navigator.of(ctx).pop(text.isEmpty ? null : text);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }

  bool _hasMachineForStage(WorkplaceModel stage) {
    try {
      return (stage as dynamic).hasMachine == true;
    } catch (_) {
      return false;
    }
  }

  bool _isSetupCompletedForUser(TaskModel task, String userId) {
    final starts = task.comments
        .where((c) => c.type == 'setup_start' && c.userId == userId)
        .toList();
    final dones = task.comments
        .where((c) => c.type == 'setup_done' && c.userId == userId)
        .toList();
    if (starts.isEmpty) return false;
    final lastStartTs =
        starts.map((c) => c.timestamp).reduce((a, b) => a > b ? a : b);
    final lastDoneTs = dones.isEmpty
        ? 0
        : dones.map((c) => c.timestamp).reduce((a, b) => a > b ? a : b);
    return lastDoneTs > lastStartTs;
  }

  Future<void> _startSetup(TaskModel task, TaskProvider provider) async {
    await provider.addComment(
      taskId: task.id,
      userId: widget.employeeId,
      type: 'setup_start',
      text: 'Начал(а) настройку станка',
    );
    if (!task.assignees.contains(widget.employeeId)) {
      try {
        await (provider as dynamic).addAssignee(task.id, widget.employeeId);
      } catch (_) {
        final newAssignees = List<String>.from(task.assignees)
          ..add(widget.employeeId);
        await provider.updateAssignees(task.id, newAssignees);
      }
    }
  }

  Future<void> _finishSetup(TaskModel task, TaskProvider provider) async {
    await provider.addComment(
      taskId: task.id,
      userId: widget.employeeId,
      type: 'setup_done',
      text: 'Завершил(а) настройку станка',
    );
  }

  Future<String?> _askFinishNote(BuildContext context) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Комментарий к завершению'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Кратко опишите, что сделано на этапе',
            border: OutlineInputBorder(),
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => Navigator.of(context).pop(controller.text.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Отмена')),
          ElevatedButton(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: const Text('Сохранить')),
        ],
      ),
    );
  }

  Future<String?> _askJoinMode(BuildContext context) {
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Режим участия'),
        content: const Text(
          'Выберите способ участия в этапе: как помощник (общее количество) '
          'или отдельный (своё количество).',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop('helper'),
              child: const Text('Помощник')),
          ElevatedButton(
              onPressed: () => Navigator.of(context).pop('separate'),
              child: const Text('Отдельный')),
        ],
      ),
    );
  }

  Future<void> _handlePause(TaskModel task, TaskProvider provider) async {
    final comment = await _askComment('Причина паузы');
    if (comment == null) return;
    final seconds = _elapsed(task).inSeconds;

    await provider.updateStatus(
      task.id,
      TaskStatus.paused,
      spentSeconds: seconds,
      startedAt: null,
    );

    await provider.addComment(
      taskId: task.id,
      type: 'pause',
      text: comment,
      userId: widget.employeeId,
    );

    final analytics = context.read<AnalyticsProvider>();
    await analytics.logEvent(
      orderId: task.orderId,
      stageId: task.stageId,
      userId: widget.employeeId,
      action: 'pause',
      category: 'production',
      details: comment,
    );
  }

  Future<void> _handleProblem(TaskModel task, TaskProvider provider) async {
    final comment = await _askComment('Причина проблемы');
    if (comment == null) return;
    final seconds = _elapsed(task).inSeconds;

    await provider.updateStatus(
      task.id,
      TaskStatus.problem,
      spentSeconds: seconds,
      startedAt: null,
    );

    await provider.addComment(
      taskId: task.id,
      type: 'problem',
      text: comment,
      userId: widget.employeeId,
    );

    final analytics = context.read<AnalyticsProvider>();
    await analytics.logEvent(
      orderId: task.orderId,
      stageId: task.stageId,
      userId: widget.employeeId,
      action: 'problem',
      category: 'production',
      details: comment,
    );
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
    final name = order?.product.type ?? '';
    final displayId = order?.assignmentId ?? order?.id ?? task.orderId;

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side:
            BorderSide(color: selected ? Colors.blue : color.withOpacity(0.5)),
      ),
      child: ListTile(
        onTap: onTap,
        title: Text(displayId),
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
          child: Text(
            _statusText(task.status),
            style: TextStyle(color: color, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }
}

class _AssignedEmployeesRow extends StatelessWidget {
  final TaskModel task;
  const _AssignedEmployeesRow({required this.task});

  @override
  Widget build(BuildContext context) {
    final personnel = context.watch<PersonnelProvider>();
    final taskProvider = context.read<TaskProvider>();

    final names = task.assignees.map((id) {
      final emp = personnel.employees.firstWhere(
        (e) => e.id == id,
        orElse: () => EmployeeModel(
          id: '',
          lastName: 'Неизвестно',
          firstName: '',
          patronymic: '',
          iin: '',
          positionIds: const [],
        ),
      );
      return '${emp.firstName} ${emp.lastName}'.trim();
    }).toList();

    Future<void> _addAssignee() async {
      final available = personnel.employees
          .where((e) => !task.assignees.contains(e.id))
          .toList();
      if (available.isEmpty) return;

      String? selectedId;
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Назначить сотрудника'),
          content: DropdownButtonFormField<String>(
            items: [
              for (final e in available)
                DropdownMenuItem(
                  value: e.id,
                  child: Text('${e.lastName} ${e.firstName}'),
                ),
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
              child: const Text('Назначить'),
            ),
          ],
        ),
      );

      if (selectedId != null) {
        final newAssignees = List<String>.from(task.assignees)
          ..add(selectedId!);
        await taskProvider.updateAssignees(task.id, newAssignees);
      }
    }

    return Row(
      children: [
        const Text('Исполнители:'),
        const SizedBox(width: 4),
        Expanded(
          child: Wrap(
            spacing: 4,
            children: [
              for (final name in names) Chip(label: Text(name)),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.person_add),
          tooltip: 'Добавить исполнителя',
          onPressed: _addAssignee,
        ),
      ],
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
