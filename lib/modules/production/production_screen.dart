import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../orders/order_model.dart';
import '../orders/orders_provider.dart';
import '../tasks/task_model.dart';
import '../tasks/task_provider.dart';
// Экран редактирования плана и создания этапов. Используется для
// создания нового производственного задания.
import '../production_planning/production_planning_screen.dart';

// Экран с подробной информацией по конкретному заказу.
import 'production_details_screen.dart';

/// Статус заказа на основе всех его задач.
enum _AggregatedStatus { production, paused, problem, completed, waiting }

/// Вспомогательная функция для вычисления агрегированного статуса заказа по
/// списку задач. Приоритет проблем выше, затем паузы, затем производство,
/// затем ожидание, завершённые — если все задачи завершены.
_AggregatedStatus _computeAggregatedStatus(List<TaskModel> tasks) {
  if (tasks.isEmpty) return _AggregatedStatus.waiting;
  final hasProblem = tasks.any((t) => t.status == TaskStatus.problem);
  if (hasProblem) return _AggregatedStatus.problem;
  final hasPaused = tasks.any((t) => t.status == TaskStatus.paused);
  final allCompleted = tasks.isNotEmpty && tasks.every((t) => t.status == TaskStatus.completed);
  if (allCompleted) return _AggregatedStatus.completed;
  if (hasPaused) return _AggregatedStatus.paused;
  final hasInProgress = tasks.any((t) => t.status == TaskStatus.inProgress);
  // Ожидание и производство объединяем в одно состояние «производство»
  if (hasInProgress) return _AggregatedStatus.production;
  final hasWaiting = tasks.any((t) => t.status == TaskStatus.waiting);
  if (hasWaiting) return _AggregatedStatus.production;
  return _AggregatedStatus.production;
}

/// Отображаемые подписи для агрегированных статусов.
const Map<_AggregatedStatus, String> _statusLabels = {
  _AggregatedStatus.production: 'Производство',
  _AggregatedStatus.paused: 'На паузе',
  _AggregatedStatus.problem: 'Проблема',
  _AggregatedStatus.completed: 'Завершено',
  _AggregatedStatus.waiting: 'Ожидание',
};

/// Цвета для индикаторов статусов.
const Map<_AggregatedStatus, Color> _statusColors = {
  _AggregatedStatus.production: Colors.blue,
  _AggregatedStatus.paused: Colors.orange,
  _AggregatedStatus.problem: Colors.red,
  _AggregatedStatus.completed: Colors.green,
  _AggregatedStatus.waiting: Colors.grey,
};

/// Экран управления производственными заданиями (для технического лидера).
class ProductionScreen extends StatefulWidget {
  const ProductionScreen({super.key});

  @override
  State<ProductionScreen> createState() => _ProductionScreenState();
}

class _ProductionScreenState extends State<ProductionScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  // Фильтры для табов. null обозначает список всех заказов без фильтра.
  final List<_AggregatedStatus?> _filters = const [
    null,
    _AggregatedStatus.production,
    _AggregatedStatus.paused,
    _AggregatedStatus.problem,
    _AggregatedStatus.completed,
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _filters.length, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final orders = context.watch<OrdersProvider>().orders;
    final tasks = context.watch<TaskProvider>().tasks;
    // Группируем задачи по ID заказа.
    final Map<String, List<TaskModel>> tasksByOrder = {};
    for (final task in tasks) {
      tasksByOrder.putIfAbsent(task.orderId, () => []).add(task);
    }

    return DefaultTabController(
      length: _filters.length,
      child: Scaffold(
        backgroundColor: Colors.grey[50],
        appBar: AppBar(
        leading: BackButton(),
        title: const Text('Модуль управления производственными заданиями'),
      ),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Модуль управления производственными заданиями',
                      style: TextStyle(
                          fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Интерфейс технического лидера для управления производственными процессами',
                      style: TextStyle(
                          fontSize: 14, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: TabBar(
                        controller: _tabController,
                        isScrollable: true,
                        indicatorColor: Colors.blue,
                        labelColor: Colors.black,
                        unselectedLabelColor: Colors.grey,
                        tabs: const [
                          Tab(text: 'Все задания'),
                          Tab(text: 'Производство'),
                          Tab(text: 'На паузе'),
                          Tab(text: 'Проблема'),
                          Tab(text: 'Завершённые'),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const ProductionPlanningScreen(),
                          ),
                        );
                      },
                      icon: const Icon(Icons.add),
                      label: const Text('Новое задание'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: _filters
                      .map((filter) => _buildList(
                            context,
                            filter,
                            orders,
                            tasksByOrder,
                          ))
                      .toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    _AggregatedStatus? filter,
    List<OrderModel> orders,
    Map<String, List<TaskModel>> tasksByOrder,
  ) {
    final dateFormat = DateFormat('dd.MM.yyyy');
    // Фильтруем заказы по выбранному статусу. Если filter == null, отображаем все.
    final filtered = orders.where((order) {
      final tasksForOrder = tasksByOrder[order.id] ?? const [];
      final agg = _computeAggregatedStatus(tasksForOrder);
      return filter == null || agg == filter;
    }).toList();
    if (filtered.isEmpty) {
      return const Center(child: Text('Задания отсутствуют'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final order = filtered[index];
        // Если для заказа создано производственное задание, отображаем его id (ЗК-...).
        final displayId = order.assignmentId ?? order.id;
        final orderTasks = tasksByOrder[order.id] ?? const [];
        final aggStatus = _computeAggregatedStatus(orderTasks);
        final color = _statusColors[aggStatus] ?? Colors.grey;
        final label = _statusLabels[aggStatus] ?? '';
        final product = order.product;
        final productDesc = product.type;
        final qty = '${product.quantity} шт.';
        final due = dateFormat.format(order.dueDate);
        // Вычисляем последний комментарий для заказа. Используется для
        // отображения причины паузы или проблемы, если такая есть.
        String? lastComment;
        String? lastCommentType;
        int lastTimestamp = 0;
        for (final task in orderTasks) {
          for (final c in task.comments) {
            if (c.timestamp > lastTimestamp) {
              lastTimestamp = c.timestamp;
              lastComment = c.text;
              lastCommentType = c.type;
            }
          }
        }
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        displayId,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: color.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        label,
                        style: TextStyle(color: color, fontSize: 12),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                if (productDesc.isNotEmpty)
                  Text(
                    productDesc,
                    style: const TextStyle(fontSize: 14),
                  ),
                const SizedBox(height: 2),
                // заказчик
                Text(
                  order.customer,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (qty.isNotEmpty) ...[
                      const Icon(Icons.layers, size: 16, color: Colors.grey),
                      const SizedBox(width: 4),
                      Text(qty),
                      const SizedBox(width: 16),
                    ],
                    const Icon(Icons.calendar_today, size: 16, color: Colors.grey),
                    const SizedBox(width: 4),
                    Text('до $due'),
                  ],
                ),
                const SizedBox(height: 8),
                // Если есть комментарий (причина проблемы или паузы), выводим его
                if (lastComment != null &&
                    (aggStatus == _AggregatedStatus.problem ||
                        aggStatus == _AggregatedStatus.paused))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8.0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          lastCommentType == 'problem'
                              ? Icons.error_outline
                              : Icons.pause_circle_outline,
                          size: 16,
                          color: lastCommentType == 'problem'
                              ? Colors.redAccent
                              : Colors.orange,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            lastComment!,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.black87),
                          ),
                        ),
                      ],
                    ),
                  ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () {
                      // Открыть страницу подробностей заказа
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ProductionDetailsScreen(order: order),
                        ),
                      );
                    },
                    child: const Text('Подробнее'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}