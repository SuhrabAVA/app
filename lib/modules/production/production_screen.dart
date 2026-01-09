import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../orders/order_model.dart';
import '../orders/orders_provider.dart';
import '../personnel/personnel_provider.dart';
import '../production/production_queue_provider.dart';
import '../tasks/task_model.dart';
import '../tasks/task_provider.dart';
import '../production_planning/template_provider.dart';
import '../production_planning/template_model.dart';
import '../production_planning/planned_stage_model.dart';
import 'production_details_screen.dart';

const _completedLabel = 'Завершенные';
const _completedTabId = '__completed__';
const _allLabel = 'Все';
const _allTabId = '__all__';

enum _ProductionSort {
  queue,
  dateDesc,
  dateAsc,
  nameAsc,
  nameDesc,
}

String _sortLabel(_ProductionSort sort) {
  switch (sort) {
    case _ProductionSort.queue:
      return 'По очереди';
    case _ProductionSort.dateDesc:
      return 'Сначала новые';
    case _ProductionSort.dateAsc:
      return 'Сначала старые';
    case _ProductionSort.nameAsc:
      return 'По названию А-Я';
    case _ProductionSort.nameDesc:
      return 'По названию Я-А';
  }
}

class _ProductionTabInfo {
  final String id;
  final String label;
  final bool isCompleted;
  final bool isAll;

  const _ProductionTabInfo({
    required this.id,
    required this.label,
    this.isCompleted = false,
    this.isAll = false,
  });
}

class _StageGroupInfo {
  final String key;
  final List<String> stageIds;
  final String label;

  const _StageGroupInfo({
    required this.key,
    required this.stageIds,
    required this.label,
  });
}

class _OrderGroupingData {
  final Map<String, _StageGroupInfo> stageGroups;
  final Map<String, List<TaskModel>> tasksByGroup;
  final Set<String> visibleWorkplaceIds;
  final bool isCompleted;

  const _OrderGroupingData({
    required this.stageGroups,
    required this.tasksByGroup,
    required this.visibleWorkplaceIds,
    required this.isCompleted,
  });
}

TaskStatus _groupStatus(List<TaskModel> tasks) {
  if (tasks.any((t) => t.status == TaskStatus.problem)) {
    return TaskStatus.problem;
  }
  if (tasks.any((t) => t.status == TaskStatus.inProgress)) {
    return TaskStatus.inProgress;
  }
  if (tasks.any((t) => t.status == TaskStatus.paused)) {
    return TaskStatus.paused;
  }
  if (tasks.any((t) => t.status == TaskStatus.completed)) {
    return TaskStatus.completed;
  }
  return TaskStatus.waiting;
}

bool _groupCompleted(List<TaskModel> tasks) =>
    tasks.any((t) => t.status == TaskStatus.completed);

bool _orderCompletedByGroups(
  Map<String, _StageGroupInfo> stageGroups,
  Map<String, List<TaskModel>> tasksByGroup,
) {
  if (stageGroups.isEmpty) return false;
  for (final group in stageGroups.values) {
    final groupTasks = tasksByGroup[group.key] ?? const <TaskModel>[];
    if (groupTasks.isEmpty || !_groupCompleted(groupTasks)) {
      return false;
    }
  }
  return true;
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

class ProductionScreen extends StatefulWidget {
  const ProductionScreen({super.key});

  @override
  State<ProductionScreen> createState() => _ProductionScreenState();
}

class _ProductionScreenState extends State<ProductionScreen>
    with TickerProviderStateMixin {
  late TabController _tabController;
  int _tabIndex = 0;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  _ProductionSort _sort = _ProductionSort.queue;

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
    _searchController.dispose();
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

    final oldController = _tabController;
    _tabController = TabController(
      length: length,
      vsync: this,
      initialIndex: _tabIndex.clamp(0, length - 1),
    );
    _tabController.addListener(_handleTabChange);

    oldController.dispose();
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

  Widget _buildStageRow(
    Map<String, _StageGroupInfo> stageGroups,
    Map<String, List<TaskModel>> tasksByGroup,
  ) {
    if (stageGroups.isEmpty) {
      return const Text('Этапы не назначены',
          style: TextStyle(color: Colors.black54));
    }

    final chips = <Widget>[];
    final groups = stageGroups.values.toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));

    for (final group in groups) {
      final tasksForStage = tasksByGroup[group.key] ?? const <TaskModel>[];
      final status = _groupStatus(tasksForStage);
      final color = _stageColor(status);
      final label = group.label;

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
    final templateProvider = context.watch<TemplateProvider>();

    final orders = ordersProvider.orders;
    final tasks = taskProvider.tasks;

    final workplaces = List.of(personnelProvider.workplaces)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final tabs = [
      const _ProductionTabInfo(id: _allTabId, label: _allLabel, isAll: true),
      for (final w in workplaces) _ProductionTabInfo(id: w.id, label: w.name),
      const _ProductionTabInfo(
        id: _completedTabId,
        label: _completedLabel,
        isCompleted: true,
      ),
    ];
    _ensureController(tabs.length);

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Модуль управления производственными заданиями'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(112),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: TabBar(
                  controller: _tabController,
                  isScrollable: true,
                  labelColor: Colors.black,
                  unselectedLabelColor: Colors.grey,
                  tabs: [for (final t in tabs) Tab(text: t.label)],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        onChanged: (value) {
                          setState(() {
                            _searchQuery = value;
                          });
                        },
                        decoration: InputDecoration(
                          hintText: 'Поиск по заказам и заданиям',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _searchQuery.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() {
                                      _searchQuery = '';
                                    });
                                  },
                                ),
                          isDense: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    DropdownButtonHideUnderline(
                      child: DropdownButton<_ProductionSort>(
                        value: _sort,
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() {
                            _sort = value;
                          });
                        },
                        items: _ProductionSort.values
                            .map(
                              (sort) => DropdownMenuItem(
                                value: sort,
                                child: Text(_sortLabel(sort)),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  ],
                ),
              ),
            ],
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
                templateProvider: templateProvider,
                dateFormatter: _formatDate,
                dimensionFormatter: _formatDimensions,
                stageBuilder: _buildStageRow,
                finalQuantity: _finalQuantity,
                searchQuery: _searchQuery,
                sort: _sort,
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
    required this.templateProvider,
    required this.dateFormatter,
    required this.dimensionFormatter,
    required this.stageBuilder,
    required this.finalQuantity,
    required this.searchQuery,
    required this.sort,
  });

  final _ProductionTabInfo tab;
  final List<TaskModel> allTasks;
  final TaskProvider taskProvider;
  final PersonnelProvider personnelProvider;
  final List<OrderModel> orders;
  final ProductionQueueProvider queue;
  final TemplateProvider templateProvider;
  final String Function(DateTime) dateFormatter;
  final String Function(OrderModel) dimensionFormatter;
  final Widget Function(
    Map<String, _StageGroupInfo>,
    Map<String, List<TaskModel>>,
  ) stageBuilder;
  final double Function(OrderModel) finalQuantity;
  final String searchQuery;
  final _ProductionSort sort;

  Map<String, _StageGroupInfo> _stageGroupsForOrder(
    OrderModel order,
    List<TaskModel> orderTasks,
  ) {
    final groups = <String, _StageGroupInfo>{};
    final templateId = order.stageTemplateId;
    if (templateId != null && templateId.isNotEmpty) {
      final tpl = templateProvider.templates.firstWhere(
        (t) => t.id == templateId,
        orElse: () =>
            TemplateModel(id: '', name: '', stages: const <PlannedStage>[]),
      );
      if (tpl.id.isNotEmpty) {
        for (final stage in tpl.stages) {
          final ids = stage.allStageIds.where((id) => id.trim().isNotEmpty).toList();
          if (ids.isEmpty) continue;
          final sortedIds = List<String>.from(ids)..sort();
          final key = sortedIds.join('|');
          final labels = <String>{};
          for (final name in stage.allStageNames) {
            final trimmed = name.trim();
            if (trimmed.isNotEmpty) labels.add(trimmed);
          }
          if (labels.isEmpty) {
            for (final id in sortedIds) {
              labels.add(_stageLabel(id, taskProvider, personnelProvider, order.id));
            }
          }
          final label = labels.join(' / ');
          groups[key] = _StageGroupInfo(key: key, stageIds: sortedIds, label: label);
        }
      }
    }

    if (groups.isNotEmpty) return groups;

    final uniqueStageIds = orderTasks
        .map((t) => t.stageId)
        .where((id) => id.trim().isNotEmpty)
        .toSet();
    for (final id in uniqueStageIds) {
      final label = _stageLabel(id, taskProvider, personnelProvider, order.id);
      groups[id] = _StageGroupInfo(key: id, stageIds: [id], label: label);
    }
    return groups;
  }

  Map<String, String> _stageGroupLookup(Map<String, _StageGroupInfo> groups) {
    final lookup = <String, String>{};
    for (final entry in groups.entries) {
      for (final stageId in entry.value.stageIds) {
        lookup[stageId] = entry.key;
      }
    }
    return lookup;
  }

  Map<String, List<TaskModel>> _tasksByGroup(
    List<TaskModel> orderTasks,
    Map<String, String> lookup,
  ) {
    final byGroup = <String, List<TaskModel>>{};
    for (final task in orderTasks) {
      final groupKey = lookup[task.stageId] ?? task.stageId;
      byGroup.putIfAbsent(groupKey, () => []).add(task);
    }
    return byGroup;
  }

  _OrderGroupingData _groupingForOrder(
    OrderModel order,
    List<TaskModel> orderTasks,
  ) {
    final stageGroups = _stageGroupsForOrder(order, orderTasks);
    final lookup = _stageGroupLookup(stageGroups);
    final tasksByGroup = _tasksByGroup(orderTasks, lookup);
    final visibleWorkplaceIds = <String>{};
    for (final task in orderTasks) {
      final groupKey = lookup[task.stageId] ?? task.stageId;
      final groupTasks = tasksByGroup[groupKey] ?? const <TaskModel>[];
      final groupHasActive = groupTasks.any((t) => t.status != TaskStatus.waiting);
      if (!groupHasActive || task.status != TaskStatus.waiting) {
        visibleWorkplaceIds.add(task.stageId);
      }
    }
    final completed = _orderCompletedByGroups(stageGroups, tasksByGroup);
    return _OrderGroupingData(
      stageGroups: stageGroups,
      tasksByGroup: tasksByGroup,
      visibleWorkplaceIds: visibleWorkplaceIds,
      isCompleted: completed,
    );
  }

  String _orderLabel(OrderModel order) {
    if (order.customer.trim().isNotEmpty) return order.customer;
    if (order.id.trim().isNotEmpty) return 'Заказ ${order.id}';
    return 'Без названия';
  }

  bool _matchesSearch(OrderModel order) {
    final query = searchQuery.trim().toLowerCase();
    if (query.isEmpty) return true;
    final id = order.id.toLowerCase();
    final assignmentId = (order.assignmentId ?? '').toLowerCase();
    final customer = order.customer.toLowerCase();
    final product = order.product.type.toLowerCase();
    return id.contains(query) ||
        assignmentId.contains(query) ||
        customer.contains(query) ||
        product.contains(query);
  }

  List<OrderModel> _sortOrders(List<OrderModel> source) {
    if (source.length < 2) return source;
    final sorted = List<OrderModel>.from(source);
    switch (sort) {
      case _ProductionSort.queue:
        return source;
      case _ProductionSort.dateDesc:
        sorted.sort((a, b) => b.orderDate.compareTo(a.orderDate));
        break;
      case _ProductionSort.dateAsc:
        sorted.sort((a, b) => a.orderDate.compareTo(b.orderDate));
        break;
      case _ProductionSort.nameAsc:
        sorted.sort(
          (a, b) => _orderLabel(a).toLowerCase().compareTo(
                _orderLabel(b).toLowerCase(),
              ),
        );
        break;
      case _ProductionSort.nameDesc:
        sorted.sort(
          (a, b) => _orderLabel(b).toLowerCase().compareTo(
                _orderLabel(a).toLowerCase(),
              ),
        );
        break;
    }
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    final tasksByOrder = <String, List<TaskModel>>{};
    for (final task in allTasks) {
      tasksByOrder.putIfAbsent(task.orderId, () => []).add(task);
    }

    final groupingByOrder = <String, _OrderGroupingData>{};
    for (final order in orders) {
      final orderTasks = tasksByOrder[order.id] ?? const <TaskModel>[];
      groupingByOrder[order.id] = _groupingForOrder(order, orderTasks);
    }

    List<OrderModel> ordered;
    if (tab.isCompleted) {
      ordered = orders
          .where((o) {
            final grouping = groupingByOrder[o.id];
            return grouping != null &&
                grouping.isCompleted &&
                o.shippedAt == null;
          })
          .toList();
      ordered = _sortOrders(ordered);
      if (sort == _ProductionSort.queue) {
        ordered.sort((a, b) => b.orderDate.compareTo(a.orderDate));
      }
    } else if (tab.isAll) {
      ordered = orders.toList();
      ordered = _sortOrders(ordered);
      if (sort == _ProductionSort.queue) {
        ordered.sort((a, b) => b.orderDate.compareTo(a.orderDate));
      }
    } else {
      final visible = orders.where((o) {
        final grouping = groupingByOrder[o.id];
        if (grouping == null || grouping.isCompleted) return false;
        if (!grouping.visibleWorkplaceIds.contains(tab.id)) return false;
        return !queue.isHidden(o.id, groupId: tab.id);
      }).toList();

      WidgetsBinding.instance.addPostFrameCallback((_) {
        queue.syncOrders(visible.map((o) => o.id), groupId: tab.id);
      });

      if (sort == _ProductionSort.queue) {
        ordered = queue.sortByPriority(visible, (o) => o.id, groupId: tab.id);
      } else {
        ordered = _sortOrders(visible);
      }
    }

    ordered = ordered.where(_matchesSearch).toList();

    if (ordered.isEmpty) {
      return const Center(
        child: Text('Нет заказов в этой категории',
            style: TextStyle(color: Colors.grey)),
      );
    }

    return tab.isCompleted
        ? ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 48),
            itemCount: ordered.length,
            itemBuilder: (context, index) {
              final order = ordered[index];
              final grouping = groupingByOrder[order.id]!;
              final stageRow = stageBuilder(
                grouping.stageGroups,
                grouping.tasksByGroup,
              );
              final qty = finalQuantity(order);

              return _buildOrderCard(
                context: context,
                order: order,
                stageRow: stageRow,
                completed: grouping.isCompleted,
                qty: qty,
                dateFormatter: dateFormatter,
                dimensionFormatter: dimensionFormatter,
                orderLabel: _orderLabel(order),
                showDragHandle: false,
              );
            },
          )
        : ReorderableListView.builder(
            buildDefaultDragHandles: false,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 48),
            itemCount: ordered.length,
            onReorder: (oldIndex, newIndex) {
              if (newIndex > oldIndex) newIndex -= 1;
              final updated = List.of(ordered);
              final item = updated.removeAt(oldIndex);
              updated.insert(newIndex, item);
              queue.applyVisibleReorder(updated.map((e) => e.id).toList(), groupId: tab.id);
            },
            itemBuilder: (context, index) {
              final order = ordered[index];
              final grouping = groupingByOrder[order.id]!;
              final stageRow = stageBuilder(
                grouping.stageGroups,
                grouping.tasksByGroup,
              );
              final qty = finalQuantity(order);

              return _buildOrderCard(
                context: context,
                order: order,
                stageRow: stageRow,
                completed: grouping.isCompleted,
                qty: qty,
                dateFormatter: dateFormatter,
                dimensionFormatter: dimensionFormatter,
                orderLabel: _orderLabel(order),
                showDragHandle: true,
                dragIndex: index,
              );
            },
          );
  }

  Widget _buildOrderCard({
    required BuildContext context,
    required OrderModel order,
    required Widget stageRow,
    required bool completed,
    required double qty,
    required String Function(DateTime) dateFormatter,
    required String Function(OrderModel) dimensionFormatter,
    required String orderLabel,
    required bool showDragHandle,
    int? dragIndex,
  }) {
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
                      orderLabel,
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
                    if (showDragHandle && dragIndex != null)
                      ReorderableDragStartListener(
                        index: dragIndex,
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
  }
}
