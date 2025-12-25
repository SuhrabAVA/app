import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../orders/order_model.dart';
import '../orders/orders_provider.dart';
import '../tasks/task_model.dart';
import '../tasks/task_provider.dart';

// Экран редактирования плана и создания этапов
// Экран с подробной информацией по конкретному заказу
import 'production_details_screen.dart';

/// Статус заказа на основе всех его задач.
enum _AggregatedStatus { production, paused, problem, completed, waiting }

/// Вычисляем агрегированный статус по списку задач.
_AggregatedStatus _computeAggregatedStatus(List<TaskModel> tasks) {
  if (tasks.isEmpty) return _AggregatedStatus.waiting;

  final hasProblem = tasks.any((t) => t.status == TaskStatus.problem);
  if (hasProblem) return _AggregatedStatus.problem;

  final hasPaused = tasks.any((t) => t.status == TaskStatus.paused);
  final allCompleted =
      tasks.isNotEmpty && tasks.every((t) => t.status == TaskStatus.completed);
  if (allCompleted) return _AggregatedStatus.completed;
  if (hasPaused) return _AggregatedStatus.paused;

  final hasInProgress = tasks.any((t) => t.status == TaskStatus.inProgress);
  if (hasInProgress) return _AggregatedStatus.production;

  final hasWaiting = tasks.any((t) => t.status == TaskStatus.waiting);
  if (hasWaiting) return _AggregatedStatus.production;

  return _AggregatedStatus.production;
}

/// Подписи статусов.
const Map<_AggregatedStatus, String> _statusLabels = {
  _AggregatedStatus.production: 'Производство',
  _AggregatedStatus.paused: 'На паузе',
  _AggregatedStatus.problem: 'Проблема',
  _AggregatedStatus.completed: 'Завершено',
  _AggregatedStatus.waiting: 'Ожидание',
};

/// Цвета статусов.
const Map<_AggregatedStatus, Color> _statusColors = {
  _AggregatedStatus.production: Colors.blue,
  _AggregatedStatus.paused: Colors.orange,
  _AggregatedStatus.problem: Colors.red,
  _AggregatedStatus.completed: Colors.green,
  _AggregatedStatus.waiting: Colors.grey,
};

class ProductionScreen extends StatefulWidget {
  const ProductionScreen({super.key});

  @override
  State<ProductionScreen> createState() => _ProductionScreenState();
}

class _ProductionScreenState extends State<ProductionScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  // Фильтры для табов: null — все заказы
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

  // ---------- Безопасные геттеры для динамических полей ваших моделей ----------
  T? _try<T>(T Function() fn) {
    try {
      return fn();
    } catch (_) {
      return null;
    }
  }

  String _displayName(OrderModel order) {
    final code = _try<String?>(() => (order as dynamic).code);
    final orderCode = _try<String?>(() => (order as dynamic).orderCode);
    final id = _try<String?>(() => (order as dynamic).id) ?? '';
    return code ??
        orderCode ??
        (id.isNotEmpty
            ? 'ID ${id.substring(0, id.length.clamp(0, 8))}'
            : 'Заказ');
  }

  String _displayCustomer(OrderModel order) {
    final name = _try<String?>(() => (order as dynamic).customer)?.trim();
    if (name != null && name.isNotEmpty) return name;
    return _displayName(order);
  }

  String _productDesc(OrderModel order) {
    final name = _try<String?>(() => (order as dynamic).productName) ??
        _try<String?>(() => (order as dynamic).name) ??
        _try<String?>(() => (order as dynamic).title);
    final desc = _try<String?>(() => (order as dynamic).description) ??
        _try<String?>(() => (order as dynamic).productDescription);
    return [name, desc].where((e) => (e ?? '').trim().isNotEmpty).join(' • ');
  }

  String _qtyText(OrderModel order) {
    final q = _try<num?>(() => (order as dynamic).quantity) ??
        _try<num?>(() => (order as dynamic).qty);
    final unit = _try<String?>(() => (order as dynamic).unit) ??
        _try<String?>(() => (order as dynamic).unitName) ??
        _try<String?>(() => (order as dynamic).unitCode);
    if (q == null) return '';
    return unit == null || unit.isEmpty ? '$q' : '$q $unit';
  }

  DateTime? _dueDate(OrderModel order) {
    final dt = _try<DateTime?>(() => (order as dynamic).dueDate);
    if (dt != null) return dt;
    final raw = _try<String?>(() => (order as dynamic).dueDate) ??
        _try<String?>(() => (order as dynamic).deadline);
    if (raw == null || raw.isEmpty) return null;
    // Пробуем ISO/DateTime.parse
    try {
      return DateTime.parse(raw);
    } catch (_) {
      return null;
    }
  }

  /// Ищем последний комментарий по «проблеме»/«паузе»
  (String? text, String type)? _lastIssueComment(List<TaskModel> tasks) {
    if (tasks.isEmpty) return null;

    // Сортируем по updatedAt/createdAt, если есть
    tasks = [...tasks];
    tasks.sort((a, b) {
      final au = _try<DateTime?>(() => (a as dynamic).updatedAt) ??
          _try<DateTime?>(() => (a as dynamic).createdAt);
      final bu = _try<DateTime?>(() => (b as dynamic).updatedAt) ??
          _try<DateTime?>(() => (b as dynamic).createdAt);
      return (bu ?? DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(au ?? DateTime.fromMillisecondsSinceEpoch(0));
    });

    for (final t in tasks) {
      if (t.status == TaskStatus.problem || t.status == TaskStatus.paused) {
        final text = _try<String?>(() => (t as dynamic).comment) ??
            _try<String?>(() => (t as dynamic).lastComment);
        final type = t.status == TaskStatus.problem ? 'problem' : 'paused';
        if (text != null && text.trim().isNotEmpty) {
          return (text, type);
        }
      }
    }
    return null;
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

    // Пары (order, tasksForOrder)
    final List<(OrderModel, List<TaskModel>)> paired = [
      for (final order in orders)
        (
          order,
          tasksByOrder[_try<String?>(() => (order as dynamic).id) ?? ''] ??
              const <TaskModel>[]
        )
    ];

    // Предсортировка по дедлайну, если есть.
    paired.sort((a, b) {
      final ad = _dueDate(a.$1);
      final bd = _dueDate(b.$1);
      if (ad == null && bd == null) return 0;
      if (ad == null) return 1;
      if (bd == null) return -1;
      return ad.compareTo(bd);
    });

    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Модуль управления производственными заданиями'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
              ],
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _tabController,
          children: _filters.map((flt) {
            // Фильтруем пары по агрегированному статусу
            final filtered = paired.where((p) {
              final agg = _computeAggregatedStatus(p.$2);
              return flt == null ? true : agg == flt;
            }).toList();

            if (filtered.isEmpty) {
              return const Center(
                child:
                    Text('Нет записей', style: TextStyle(color: Colors.grey)),
              );
            }

            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final order = filtered[index].$1;
                final orderTasks = filtered[index].$2;
                final agg = _computeAggregatedStatus(orderTasks);
                final label = _statusLabels[agg]!;
                final color = _statusColors[agg]!;

                final displayName = _displayCustomer(order);
                final productDesc = _productDesc(order);
                final qty = _qtyText(order);
                final dueDt = _dueDate(order);
                final due = dueDt != null
                    ? DateFormat('dd.MM.yyyy').format(dueDt)
                    : '—';

                final issue = _lastIssueComment(orderTasks);
                final lastComment = issue?.$1;
                final lastCommentType = issue?.$2;

                return Card(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                displayName,
                                style: TextStyle(
                                  color: Colors.grey.shade700,
                                  fontSize: 12,
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
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            if (qty.isNotEmpty) ...[
                              const Icon(Icons.layers,
                                  size: 16, color: Colors.grey),
                              const SizedBox(width: 4),
                              Text(qty),
                              const SizedBox(width: 16),
                            ],
                            const Icon(Icons.calendar_today,
                                size: 16, color: Colors.grey),
                            const SizedBox(width: 4),
                            Text('до $due'),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (lastComment != null &&
                            (agg == _AggregatedStatus.problem ||
                                agg == _AggregatedStatus.paused))
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
                                    lastComment,
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
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      ProductionDetailsScreen(order: order),
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
          }).toList(),
        ),
      ),
    );
  }
}
