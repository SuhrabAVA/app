import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../orders/order_model.dart';
import '../orders/orders_provider.dart';
import '../personnel/personnel_provider.dart';
import '../production/production_queue_provider.dart';
import '../products/products_provider.dart';
import '../tasks/task_model.dart';
import '../tasks/task_provider.dart';
import 'production_details_screen.dart';

const _allLabel = 'Все изделия';

class ProductionScreen extends StatefulWidget {
  const ProductionScreen({super.key});

  @override
  State<ProductionScreen> createState() => _ProductionScreenState();
}

class _ProductionScreenState extends State<ProductionScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 1, vsync: this);
    _tabController.addListener(_handleTabChange);
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    super.dispose();
  }

  void _handleTabChange() {
    setState(() {
      _tabIndex = _tabController.index;
    });
  }

  void _ensureController(int length) {
    if (_tabController.length == length) return;
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    _tabController = TabController(
      length: length,
      vsync: this,
      initialIndex: _tabIndex.clamp(0, length - 1),
    );
    _tabController.addListener(_handleTabChange);
  }

  String _formatDate(DateTime date) =>
      DateFormat('dd MMM yyyy', 'ru').format(date.toLocal());

  String _formatDimensions(OrderModel order) {
    final w = order.product.width;
    final h = order.product.height;
    final d = order.product.depth;

    String fmt(num value) {
      if (value == value.toInt()) return value.toInt().toString();
      return value.toString();
    }

    return '${fmt(w)}×${fmt(h)}×${fmt(d)} мм';
  }

  TaskStatus _stageStatus(List<TaskModel> tasks) {
    if (tasks.any((t) => t.status == TaskStatus.problem)) {
      return TaskStatus.problem;
    }
    if (tasks.any((t) => t.status == TaskStatus.inProgress)) {
      return TaskStatus.inProgress;
    }
    if (tasks.any((t) => t.status == TaskStatus.paused)) {
      return TaskStatus.paused;
    }
    if (tasks.isNotEmpty && tasks.every((t) => t.status == TaskStatus.completed)) {
      return TaskStatus.completed;
    }
    return TaskStatus.waiting;
  }

  bool _orderCompleted(List<TaskModel> tasks) =>
      tasks.isNotEmpty && tasks.every((t) => t.status == TaskStatus.completed);

  Color _stageColor(TaskStatus status) {
    switch (status) {
      case TaskStatus.completed:
        return Colors.green;
      case TaskStatus.paused:
      case TaskStatus.waiting:
        return Colors.orange;
      case TaskStatus.inProgress:
        return Colors.blue;
      case TaskStatus.problem:
        return Colors.red;
    }
  }

  String _stageLabel(
    String stageId,
    TaskProvider tasks,
    PersonnelProvider personnel,
    String orderId,
  ) {
    final byOrder = tasks.stageNameForOrder(orderId, stageId)?.trim();
    if (byOrder != null && byOrder.isNotEmpty) return byOrder;

    try {
      final wp = personnel.workplaces.firstWhere((w) => w.id == stageId);
      if (wp.name.trim().isNotEmpty) return wp.name;
    } catch (_) {}

    return stageId;
  }

  Widget _buildStageRow(
    OrderModel order,
    List<TaskModel> orderTasks,
    TaskProvider tasks,
    PersonnelProvider personnel,
  ) {
    if (orderTasks.isEmpty) {
      return const Text('Этапы не назначены',
          style: TextStyle(color: Colors.black54));
    }

    final Map<String, List<TaskModel>> byStage = {};
    for (final task in orderTasks) {
      byStage.putIfAbsent(task.stageId, () => []).add(task);
    }

    final chips = <Widget>[];
    final stageIds = byStage.keys.toList()
      ..sort((a, b) => _stageLabel(a, tasks, personnel, order.id)
          .toLowerCase()
          .compareTo(_stageLabel(b, tasks, personnel, order.id).toLowerCase()));

    for (final stageId in stageIds) {
      final tasksForStage = byStage[stageId] ?? const <TaskModel>[];
      final status = _stageStatus(tasksForStage);
      final color = _stageColor(status);
      final label = _stageLabel(stageId, tasks, personnel, order.id);

      chips.add(Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.7)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 13)),
          ],
        ),
      ));
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: chips),
    );
  }

  double _finalQuantity(OrderModel order) {
    return order.actualQty ?? order.shippedQty ?? order.product.quantity.toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final ordersProvider = context.watch<OrdersProvider>();
    final taskProvider = context.watch<TaskProvider>();
    final personnelProvider = context.watch<PersonnelProvider>();
    final queue = context.watch<ProductionQueueProvider>();
    final productsProvider = context.watch<ProductsProvider>();

    final orders = ordersProvider.orders;
    final tasks = taskProvider.tasks;

    queue.syncOrders(orders.map((o) => o.id));

    final types = <String>{
      ...productsProvider.products,
      ...orders.map((o) => o.product.type).where((t) => t.trim().isNotEmpty),
    }.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    final tabs = <String>[_allLabel, ...types];
    _ensureController(tabs.length);

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Модуль управления производственными заданиями'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TabBar(
              controller: _tabController,
              isScrollable: true,
              labelColor: Colors.black,
              unselectedLabelColor: Colors.grey,
              tabs: [for (final t in tabs) Tab(text: t)],
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _tabController,
          children: [
            for (final tab in tabs)
              _ProductionTab(
                tab: tab,
                allTasks: tasks,
                taskProvider: taskProvider,
                personnelProvider: personnelProvider,
                orders: orders,
                queue: queue,
                dateFormatter: _formatDate,
                dimensionFormatter: _formatDimensions,
                stageBuilder: _buildStageRow,
                isOrderCompleted: _orderCompleted,
                finalQuantity: _finalQuantity,
              ),
          ],
        ),
      ),
    );
  }
}

class _ProductionTab extends StatelessWidget {
  const _ProductionTab({
    required this.tab,
    required this.allTasks,
    required this.taskProvider,
    required this.personnelProvider,
    required this.orders,
    required this.queue,
    required this.dateFormatter,
    required this.dimensionFormatter,
    required this.stageBuilder,
    required this.isOrderCompleted,
    required this.finalQuantity,
  });

  final String tab;
  final List<TaskModel> allTasks;
  final TaskProvider taskProvider;
  final PersonnelProvider personnelProvider;
  final List<OrderModel> orders;
  final ProductionQueueProvider queue;
  final String Function(DateTime) dateFormatter;
  final String Function(OrderModel) dimensionFormatter;
  final Widget Function(
    OrderModel,
    List<TaskModel>,
    TaskProvider,
    PersonnelProvider,
  ) stageBuilder;
  final bool Function(List<TaskModel>) isOrderCompleted;
  final double Function(OrderModel) finalQuantity;

  List<OrderModel> _filteredOrders() {
    final visible = orders.where((o) {
      final matchesType = tab == _allLabel || o.product.type == tab;
      return matchesType && !queue.isHidden(o.id);
    }).toList();

    return queue.sortByPriority(visible, (o) => o.id);
  }

  String _orderLabel(OrderModel order) {
    if (order.customer.trim().isNotEmpty) return order.customer;
    if (order.id.trim().isNotEmpty) return 'Заказ ${order.id}';
    return 'Без названия';
  }

  @override
  Widget build(BuildContext context) {
    final tasksByOrder = <String, List<TaskModel>>{};
    for (final task in allTasks) {
      tasksByOrder.putIfAbsent(task.orderId, () => []).add(task);
    }

    final ordered = _filteredOrders();

    if (ordered.isEmpty) {
      return const Center(
        child: Text('Нет заказов в этой категории',
            style: TextStyle(color: Colors.grey)),
      );
    }

    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 48),
      itemCount: ordered.length,
      onReorder: (oldIndex, newIndex) {
        if (newIndex > oldIndex) newIndex -= 1;
        final updated = List.of(ordered);
        final item = updated.removeAt(oldIndex);
        updated.insert(newIndex, item);
        queue.applyVisibleReorder(updated.map((e) => e.id).toList());
      },
      itemBuilder: (context, index) {
        final order = ordered[index];
        final orderTasks = tasksByOrder[order.id] ?? const <TaskModel>[];
        final completed = isOrderCompleted(orderTasks);
        final stageRow = stageBuilder(
          order,
          orderTasks,
          taskProvider,
          personnelProvider,
        );

        final qty = finalQuantity(order);

        return Card(
          key: ValueKey(order.id),
          elevation: 0.5,
          margin: const EdgeInsets.symmetric(vertical: 6),
          color: completed ? Colors.green.withOpacity(0.12) : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ProductionDetailsScreen(order: order),
                ),
              );
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 120,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          dateFormatter(order.orderDate),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          order.product.type,
                          style: const TextStyle(fontSize: 12, color: Colors.black54),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _orderLabel(order),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          dimensionFormatter(order),
                          style: const TextStyle(color: Colors.black87),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: stageRow,
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 140,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (completed)
                          Text(
                            'Итог: ${qty % 1 == 0 ? qty.toInt() : qty}',
                            style: const TextStyle(
                              color: Colors.green,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        if (completed) const SizedBox(width: 8),
                        if (completed)
                          IconButton(
                            tooltip: 'Скрыть завершённый заказ',
                            icon: const Icon(Icons.check_circle, color: Colors.green),
                            onPressed: () => queue.hideOrder(order.id),
                          ),
                        ReorderableDragStartListener(
                          index: index,
                          child: const Icon(Icons.drag_indicator, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
