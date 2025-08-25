import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../orders/order_model.dart';
import '../tasks/task_model.dart';
import '../tasks/task_provider.dart';
import '../production_planning/planned_stage_model.dart';
import '../personnel/personnel_provider.dart';
import '../personnel/workplace_model.dart';

/// Статус заказа на основе всех его задач. Дублируется здесь, поскольку
/// оригинальное определение является приватным в production_screen.dart.
enum _AggregatedStatus { production, paused, problem, completed, waiting }

/// Отображаемые подписи для агрегированных статусов. Используется для
/// отображения заголовков и кнопок в деталях заказа.
const Map<_AggregatedStatus, String> _statusLabels = {
  _AggregatedStatus.production: 'Производство',
  _AggregatedStatus.paused: 'На паузе',
  _AggregatedStatus.problem: 'Проблема',
  _AggregatedStatus.completed: 'Завершено',
  _AggregatedStatus.waiting: 'Ожидание',
};

/// Цвета для индикаторов агрегированных статусов.
const Map<_AggregatedStatus, Color> _statusColors = {
  _AggregatedStatus.production: Colors.blue,
  _AggregatedStatus.paused: Colors.orange,
  _AggregatedStatus.problem: Colors.red,
  _AggregatedStatus.completed: Colors.green,
  _AggregatedStatus.waiting: Colors.grey,
};

/// Страница подробностей производственного задания.
///
/// Эта страница отображает детальную информацию о выбранном заказе,
/// включая список этапов производства и их состояние. Информация
/// о плане этапов подгружается из таблицы `production_plans` Supabase.
/// Для каждого этапа отображаются начальное и конечное время (если
/// задание уже выполнялось), а также количество комментариев.
class ProductionDetailsScreen extends StatefulWidget {
  final OrderModel order;
  const ProductionDetailsScreen({super.key, required this.order});

  @override
  State<ProductionDetailsScreen> createState() => _ProductionDetailsScreenState();
}

class _ProductionDetailsScreenState extends State<ProductionDetailsScreen> {
  /// Загруженный список запланированных этапов для текущего заказа.
  List<PlannedStage> _plannedStages = [];
  bool _loadingPlan = true;

  @override
  void initState() {
    super.initState();
    _loadPlan();
  }

  /// Загружает список этапов производства для заказа из базы данных.
  /// Данные хранятся в таблице `production_plans`, и поле `stages`
  /// может быть сохранено как массив или словарь. Если план отсутствует,
  /// список будет пустым.
  Future<void> _loadPlan() async {
    
    try {
      final data = await Supabase.instance.client
          .from('production_plans')
          .select()
          .eq('order_id', widget.order.id)
          .maybeSingle();
      List<PlannedStage> stages = [];
      if (data != null) {
        final value = data['stages'];
        stages = decodePlannedStages(value);
      
      }
      if (mounted) {
        setState(() {
          _plannedStages = stages;
          _loadingPlan = false;
        });
      }
    } catch (_) {
      // В случае ошибки загрузки просто выставляем пустой список
      if (mounted) {
        setState(() {
          _plannedStages = [];
          _loadingPlan = false;
        });
      }
    }
  }

  /// Вычисляет агрегированный статус по списку задач. Этот метод
  /// копирует логику из модуля production_screen.dart для вычисления
  /// общего состояния заказа.
  _AggregatedStatus _computeAggregatedStatus(List<TaskModel> tasks) {
    if (tasks.isEmpty) return _AggregatedStatus.waiting;
    final hasProblem = tasks.any((t) => t.status == TaskStatus.problem);
    if (hasProblem) return _AggregatedStatus.problem;
    final hasPaused = tasks.any((t) => t.status == TaskStatus.paused);
    final allCompleted = tasks.isNotEmpty && tasks.every((t) => t.status == TaskStatus.completed);
    if (allCompleted) return _AggregatedStatus.completed;
    if (hasPaused) return _AggregatedStatus.paused;
    final hasInProgress = tasks.any((t) => t.status == TaskStatus.inProgress);
    if (hasInProgress) return _AggregatedStatus.production;
    final hasWaiting = tasks.any((t) => t.status == TaskStatus.waiting);
    if (hasWaiting) return _AggregatedStatus.production;
    return _AggregatedStatus.production;
  }

  /// Возвращает виджет кнопки для управления агрегированным статусом
  /// заказа. При нажатии изменяет статус всех задач согласно выбранному
  /// состоянию.
  Widget _buildStatusButton(
      {required String label,
      required Color color,
      required _AggregatedStatus targetStatus,
      required _AggregatedStatus currentStatus,
      required List<TaskModel> tasks,
      required TaskProvider provider}) {
    final bool selected = currentStatus == targetStatus;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: ElevatedButton(
          onPressed: selected
              ? null
              : () async {
                  // Обновляем статус всех задач заказа.
                  for (final t in tasks) {
                    // Вычисляем новое состояние для каждой задачи.
                    TaskStatus newStatus;
                    switch (targetStatus) {
                      case _AggregatedStatus.production:
                        newStatus = TaskStatus.inProgress;
                        break;
                      case _AggregatedStatus.paused:
                        newStatus = TaskStatus.paused;
                        break;
                      case _AggregatedStatus.problem:
                        newStatus = TaskStatus.problem;
                        break;
                      case _AggregatedStatus.completed:
                        newStatus = TaskStatus.completed;
                        break;
                      case _AggregatedStatus.waiting:
                        newStatus = TaskStatus.waiting;
                        break;
                    }
                    // При изменении статуса сохраняем потраченное время и сбрасываем
                    // start time для оконченных/остановленных задач.
                    final seconds = _elapsed(t).inSeconds;
                    await provider.updateStatus(t.id, newStatus,
                        spentSeconds: newStatus == TaskStatus.inProgress
                            ? t.spentSeconds
                            : seconds,
                        startedAt: newStatus == TaskStatus.inProgress
                            ? DateTime.now().millisecondsSinceEpoch
                            : null);
                  }
                },
          style: ElevatedButton.styleFrom(
            backgroundColor:
                selected ? color.withOpacity(0.8) : color.withOpacity(0.2),
            foregroundColor: color,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: Text(label, textAlign: TextAlign.center),
        ),
      ),
    );
  }

  /// Вычисляет затраченное время для задачи. Если задача находится в
  /// процессе, добавляет время с начала выполнения.
  Duration _elapsed(TaskModel task) {
    var seconds = task.spentSeconds;
    if (task.status == TaskStatus.inProgress && task.startedAt != null) {
      seconds += (DateTime.now().millisecondsSinceEpoch - task.startedAt!) ~/
          1000;
    }
    return Duration(seconds: seconds);
  }

  /// Форматирует длительность для отображения в формате HH:MM.
  String _formatTime(DateTime? dt) {
    if (dt == null) return '';
    final formatter = DateFormat('yyyy-MM-dd HH:mm');
    return formatter.format(dt);
  }

  @override
  Widget build(BuildContext context) {
    final taskProvider = context.watch<TaskProvider>();
    final personnel = context.watch<PersonnelProvider>();
    // Отбираем задачи, относящиеся к текущему заказу.
    final tasks = taskProvider.tasks
        .where((t) => t.orderId == widget.order.id)
        .toList();
    // Группируем задачи по идентификатору этапа.
    final Map<String, List<TaskModel>> tasksByStage = {};
    for (final t in tasks) {
      tasksByStage.putIfAbsent(t.stageId, () => []).add(t);
    }
    // Определяем агрегированный статус заказа.
    final aggStatus = _computeAggregatedStatus(tasks);

    return Scaffold(
      appBar: AppBar(
        title: Text('Производственное задание №${widget.order.assignmentId ?? widget.order.id}'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _loadingPlan
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Карточка с общей информацией и управлением статусом
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.grey.withOpacity(0.2),
                            blurRadius: 6,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.order.assignmentId ?? widget.order.id,
                              style: const TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Text(
                            widget.order.product.type,
                            style: const TextStyle(fontSize: 16),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.order.customer,
                            style: TextStyle(
                                color: Colors.grey.shade600, fontSize: 14),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Icon(Icons.layers,
                                  size: 16, color: Colors.grey),
                              const SizedBox(width: 4),
                              Text('${widget.order.product.quantity} шт.'),
                              const SizedBox(width: 16),
                              const Icon(Icons.calendar_today,
                                  size: 16, color: Colors.grey),
                              const SizedBox(width: 4),
                              Text(
                                  'до ${DateFormat('dd.MM.yyyy').format(widget.order.dueDate)}'),
                            ],
                          ),
                          const SizedBox(height: 8),
                          // Управление статусом заказа
                          Row(
                            children: [
                              _buildStatusButton(
                                label: 'Производство',
                                color: Colors.blue,
                                targetStatus: _AggregatedStatus.production,
                                currentStatus: aggStatus,
                                tasks: tasks,
                                provider: taskProvider,
                              ),
                              _buildStatusButton(
                                label: 'На паузе',
                                color: Colors.orange,
                                targetStatus: _AggregatedStatus.paused,
                                currentStatus: aggStatus,
                                tasks: tasks,
                                provider: taskProvider,
                              ),
                              _buildStatusButton(
                                label: 'Проблема',
                                color: Colors.redAccent,
                                targetStatus: _AggregatedStatus.problem,
                                currentStatus: aggStatus,
                                tasks: tasks,
                                provider: taskProvider,
                              ),
                              _buildStatusButton(
                                label: 'Завершено',
                                color: Colors.green,
                                targetStatus: _AggregatedStatus.completed,
                                currentStatus: aggStatus,
                                tasks: tasks,
                                provider: taskProvider,
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          // Список комментариев к заказу
                          const Text('Комментарии',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Builder(builder: (context) {
                            // Собираем все комментарии из задач, сортируем по времени
                            final comments = <TaskComment>[];
                            for (final t in tasks) {
                              comments.addAll(t.comments);
                            }
                            comments.sort(
                                (a, b) => a.timestamp.compareTo(b.timestamp));
                            if (comments.isEmpty) {
                              return const Text('Нет комментариев',
                                  style: TextStyle(color: Colors.grey));
                            }
                            return Column(
                              children: [
                                for (final c in comments)
                                  Padding(
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 2),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Icon(
                                          c.type == 'problem'
                                              ? Icons.error_outline
                                              : c.type == 'pause'
                                                  ? Icons.pause_circle_outline
                                                  : Icons.info_outline,
                                          size: 18,
                                          color: c.type == 'problem'
                                              ? Colors.redAccent
                                              : c.type == 'pause'
                                                  ? Colors.orange
                                                  : Colors.blueGrey,
                                        ),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Text(
                                            c.text,
                                            style: const TextStyle(
                                                fontSize: 14),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            );
                          }),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Этапы производства
                    Text('Этапы производства',
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    if (_plannedStages.isEmpty)
                      const Text('План этапов отсутствует',
                          style: TextStyle(color: Colors.grey))
                    else
                      Column(
                        children: [
                          for (final planned in _plannedStages)
                            Builder(builder: (context) {
                              final stageId = planned.stageId;
                              final stage = personnel.workplaces.firstWhere(
                                  (s) => s.id == stageId,
                                  orElse: () => WorkplaceModel(
                                      id: stageId,
                                      name: planned.stageName,
                                      positionIds: []));
                              final stageTasks = tasksByStage[stageId] ?? [];
                              // Определяем статус этапа по задачам: если все завершены — completed,
                              // если есть проблемы — problem, если есть в работе — inProgress,
                              // если есть паузы — paused, иначе waiting.
                              TaskStatus? stageStatus;
                              if (stageTasks.isEmpty) {
                                stageStatus = null;
                              } else if (stageTasks
                                  .every((t) => t.status == TaskStatus.completed)) {
                                stageStatus = TaskStatus.completed;
                              } else if (stageTasks
                                  .any((t) => t.status == TaskStatus.problem)) {
                                stageStatus = TaskStatus.problem;
                              } else if (stageTasks
                                  .any((t) => t.status == TaskStatus.inProgress)) {
                                stageStatus = TaskStatus.inProgress;
                              } else if (stageTasks
                                  .any((t) => t.status == TaskStatus.paused)) {
                                stageStatus = TaskStatus.paused;
                              } else {
                                stageStatus = TaskStatus.waiting;
                              }
                              Color bgColor;
                              switch (stageStatus) {
                                case TaskStatus.completed:
                                  bgColor = Colors.green.withOpacity(0.2);
                                  break;
                                case TaskStatus.inProgress:
                                  bgColor = Colors.blue.withOpacity(0.2);
                                  break;
                                case TaskStatus.paused:
                                  bgColor = Colors.orange.withOpacity(0.2);
                                  break;
                                case TaskStatus.problem:
                                  bgColor = Colors.redAccent.withOpacity(0.2);
                                  break;
                                case TaskStatus.waiting:
                                default:
                                  bgColor = Colors.yellow.withOpacity(0.2);
                                  break;
                              }
                              // Вычисляем начало и завершение для первого (если несколько) задания этапа.
                              DateTime? start;
                              DateTime? end;
                              if (stageTasks.isNotEmpty) {
                                // Находим минимальное startedAt и максимальное завершённое время.
                                for (final t in stageTasks) {
                                  if (t.startedAt != null) {
                                    final st = DateTime.fromMillisecondsSinceEpoch(
                                        t.startedAt!);
                                    if (start == null || st.isBefore(start!)) {
                                      start = st;
                                    }
                                    final spent = _elapsed(t);
                                    if (spent.inSeconds > 0) {
                                      final en = st.add(spent);
                                      if (end == null || en.isAfter(end!)) {
                                        end = en;
                                      }
                                    }
                                  }
                                }
                              }
                              return Container(
                                margin: const EdgeInsets.symmetric(
                                    vertical: 4),
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: bgColor,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // Номер этапа
                                    CircleAvatar(
                                      radius: 12,
                                      backgroundColor: Colors.white,
                                      child: Text(
                                        '${_plannedStages.indexOf(planned) + 1}',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 12),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(stage.name,
                                              style: const TextStyle(
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.bold)),
                                          Text(
                                            stageTasks.isNotEmpty
                                                ? 'Исполнители: ${stageTasks.first.assignees.join(', ')}'
                                                : '',
                                            style: const TextStyle(
                                                fontSize: 14,
                                                color: Colors.black87),
                                          ),
                                          const SizedBox(height: 4),
                                          // Начало
                                          Text(
                                            start != null
                                                ? 'Начало: ${_formatTime(start)}'
                                                : 'Начало: —',
                                            style: const TextStyle(
                                                fontSize: 12,
                                                color: Colors.black54),
                                          ),
                                          Text(
                                            end != null
                                                ? 'Завершение: ${_formatTime(end)}'
                                                : stageStatus == TaskStatus.completed
                                                    ? 'Завершено'
                                                    : stageStatus == TaskStatus.inProgress
                                                        ? 'В процессе'
                                                        : 'Плановое завершение: —',
                                            style: const TextStyle(
                                                fontSize: 12,
                                                color: Colors.black54),
                                          ),
                                        ],
                                      ),
                                    ),
                                    // Количество комментариев
                                    if (stageTasks.isNotEmpty)
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(left: 8.0),
                                        child: Row(
                                          children: [
                                            const Icon(Icons.message_outlined,
                                                size: 16,
                                                color: Colors.grey),
                                            const SizedBox(width: 2),
                                            Text(
                                              '${stageTasks.fold<int>(0, (p, t) => p + t.comments.length)}',
                                              style: const TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.black54),
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              );
                            }),
                        ],
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}