import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../orders/id_format.dart';
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
  static const String _allProductTypesValue = '__all_product_types__';
  late TabController _tabController;
  int _tabIndex = 0;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  _ProductionSort _sort = _ProductionSort.queue;
  bool _menuPinned = false;
  bool _menuEdgeHover = false;
  bool _menuPanelHover = false;
  String? _productTypeFilter;
  List<String> _productTypes = [];
  bool _loadingProductTypes = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 1, vsync: this);
    _tabController.addListener(_handleTabChange);
    _loadProductTypes();
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

  Future<void> _loadProductTypes() async {
    setState(() => _loadingProductTypes = true);
    try {
      final rows =
          await Supabase.instance.client.from('warehouse_categories').select();
      final types = ((rows as List?) ?? [])
          .map((row) => (row['title'] ?? '').toString().trim())
          .where((title) => title.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      if (!mounted) return;
      setState(() => _productTypes = types);
    } catch (_) {
      if (!mounted) return;
      setState(() => _productTypes = []);
    } finally {
      if (mounted) setState(() => _loadingProductTypes = false);
    }
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

  String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}.'
        '${date.month.toString().padLeft(2, '0')}.'
        '${date.year}';
  }

  String _formatDimensions(OrderModel order) {
    final product = order.product;

    String? formatDimension(double? value) {
      if (value == null || value <= 0) return null;
      if (value == value.roundToDouble()) {
        return value.toInt().toString();
      }
      return value.toStringAsFixed(2);
    }

    final dims = <String>[];
    final width = formatDimension(product.width);
    final height = formatDimension(product.height);
    final depth = formatDimension(product.depth);
    if (width != null) dims.add(width);
    if (height != null) dims.add(height);
    if (depth != null) dims.add(depth);

    var result = dims.join('×');

    final extras = <String>[];
    final roll = formatDimension(product.roll);
    if (roll != null) extras.add('Рулон $roll');
    final blQty = product.blQuantity;
    if (blQty != null && blQty.isNotEmpty) extras.add('Кол-во $blQty');

    if (extras.isNotEmpty) {
      final extraText = extras.join(', ');
      result = result.isEmpty ? extraText : '$result ($extraText)';
    }

    return result.isEmpty ? '—' : result;
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
    // Keep template/plan order (insertion order) instead of alphabetical sort.
    final groups = stageGroups.values.toList();

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

  @override
  Widget build(BuildContext context) {
    final ordersProvider = context.watch<OrdersProvider>();
    final taskProvider = context.watch<TaskProvider>();
    final personnelProvider = context.watch<PersonnelProvider>();
    final queue = context.watch<ProductionQueueProvider>();
    final templateProvider = context.watch<TemplateProvider>();

    final orders = ordersProvider.orders;
    final tasks = taskProvider.tasks;

    final productTypeOptions = {
      ..._productTypes,
      ...orders
          .map((order) => order.product.type.trim())
          .where((type) => type.isNotEmpty),
    }.toList()
      ..sort();

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
        actions: [
          IconButton(
            tooltip: _menuPinned
                ? 'Скрыть список рабочих мест'
                : 'Показать список рабочих мест',
            icon: Icon(_menuPinned ? Icons.menu_open : Icons.menu),
            onPressed: () {
              setState(() {
                _menuPinned = !_menuPinned;
              });
            },
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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
                    PopupMenuButton<String>(
                      tooltip: 'Фильтр по типу продукта',
                      onSelected: (value) {
                        setState(() {
                          _productTypeFilter =
                              value == _allProductTypesValue ? null : value;
                        });
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem<String>(
                          value: _allProductTypesValue,
                          child: Text('Все типы'),
                        ),
                        if (_loadingProductTypes)
                          const PopupMenuItem<String>(
                            enabled: false,
                            child: Text('Загрузка...'),
                          ),
                        for (final type in productTypeOptions)
                          PopupMenuItem<String>(
                            value: type,
                            child: Text(type),
                          ),
                      ],
                      child: IgnorePointer(
                        child: OutlinedButton.icon(
                          onPressed: () {},
                          icon: const Icon(Icons.filter_list),
                          label: Text(
                            _productTypeFilter == null ||
                                    _productTypeFilter!.trim().isEmpty
                                ? 'Фильтр'
                                : 'Тип: ${_productTypeFilter!}',
                            overflow: TextOverflow.ellipsis,
                          ),
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
        child: LayoutBuilder(
          builder: (context, constraints) {
            final panelWidth = constraints.maxWidth * 0.25;
            final itemExtent = constraints.maxHeight / 35;
            final menuOpen =
                _menuPinned || _menuEdgeHover || _menuPanelHover;

            return Stack(
              children: [
                TabBarView(
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
                        searchQuery: _searchQuery,
                        sort: _sort,
                        productTypeFilter: _productTypeFilter,
                      ),
                  ],
                ),
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: 12,
                  child: MouseRegion(
                    onEnter: (_) => setState(() => _menuEdgeHover = true),
                    onExit: (_) => setState(() => _menuEdgeHover = false),
                    child: const SizedBox.expand(),
                  ),
                ),
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  left: menuOpen ? 0 : -panelWidth,
                  top: 0,
                  bottom: 0,
                  width: panelWidth,
                  child: MouseRegion(
                    onEnter: (_) => setState(() => _menuPanelHover = true),
                    onExit: (_) => setState(() => _menuPanelHover = false),
                    child: Material(
                      elevation: 4,
                      color: Colors.white,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            color: Colors.grey.shade100,
                            child: const Text(
                              'Рабочие места',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          Expanded(
                            child: ListView.builder(
                              itemExtent: itemExtent,
                              itemCount: tabs.length,
                              itemBuilder: (context, index) {
                                final tab = tabs[index];
                                final isSelected = _tabIndex == index;
                                return InkWell(
                                  onTap: () {
                                    _tabController.animateTo(index);
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    color: isSelected
                                        ? Colors.blue.withOpacity(0.08)
                                        : Colors.transparent,
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      tab.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: isSelected
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                        color: isSelected
                                            ? Colors.blueGrey.shade800
                                            : Colors.black87,
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
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
    required this.searchQuery,
    required this.sort,
    required this.productTypeFilter,
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
  final String searchQuery;
  final _ProductionSort sort;
  final String? productTypeFilter;

  Map<String, _StageGroupInfo> _stageGroupsForOrder(
    OrderModel order,
    List<TaskModel> orderTasks,
  ) {
    final groups = <String, _StageGroupInfo>{};

    String normalizeStageId(String id) => id.trim();

    String groupKeyForIds(List<String> ids) {
      final canonical = ids.toSet().toList()..sort();
      return canonical.join('|');
    }

    final seenLabelKeys = <String>{};

    void addGroup(List<String> sourceIds, {String? explicitLabel}) {
      final ids = sourceIds
          .map(normalizeStageId)
          .where((id) => id.isNotEmpty)
          .fold<List<String>>(<String>[], (acc, id) {
        if (!acc.contains(id)) acc.add(id);
        return acc;
      });
      if (ids.isEmpty) return;

      final key = groupKeyForIds(ids);
      if (groups.containsKey(key)) return;
      final labels = <String>{};
      final explicit = explicitLabel?.trim();
      if (explicit != null && explicit.isNotEmpty) {
        labels.add(explicit);
      }
      for (final id in ids) {
        final resolved = _stageLabel(id, taskProvider, personnelProvider, order.id).trim();
        if (resolved.isNotEmpty) labels.add(resolved);
      }
      final label = labels.join(' / ');
      final normalizedLabelKey =
          (label.isEmpty ? key : label).trim().toLowerCase();
      if (normalizedLabelKey.isNotEmpty &&
          seenLabelKeys.contains(normalizedLabelKey)) {
        return;
      }

      groups[key] = _StageGroupInfo(
        key: key,
        stageIds: ids,
        label: label.isEmpty ? key : label,
      );
      if (normalizedLabelKey.isNotEmpty) {
        seenLabelKeys.add(normalizedLabelKey);
      }
    }

    final templateId = order.stageTemplateId;
    if (templateId != null && templateId.isNotEmpty) {
      final tpl = templateProvider.templates.firstWhere(
        (t) => t.id == templateId,
        orElse: () =>
            TemplateModel(id: '', name: '', stages: const <PlannedStage>[]),
      );
      if (tpl.id.isNotEmpty) {
        for (final stage in tpl.stages) {
          final labels = stage.allStageNames
              .map((name) => name.trim())
              .where((name) => name.isNotEmpty)
              .toSet()
              .toList();
          addGroup(
            stage.allStageIds,
            explicitLabel: labels.isEmpty ? null : labels.join(' / '),
          );
        }
      }
    }

    final orderedFallbackIds = <String>[];
    final plannedSequence = taskProvider.stageSequenceForOrder(order.id) ?? const <String>[];
    for (final id in plannedSequence.map(normalizeStageId)) {
      if (id.isNotEmpty && !orderedFallbackIds.contains(id)) {
        orderedFallbackIds.add(id);
      }
    }
    for (final id in orderTasks.map((t) => normalizeStageId(t.stageId))) {
      if (id.isNotEmpty && !orderedFallbackIds.contains(id)) {
        orderedFallbackIds.add(id);
      }
    }

    for (final id in orderedFallbackIds) {
      final existsInGroup = groups.values.any((group) => group.stageIds.contains(id));
      if (!existsInGroup) {
        addGroup([id]);
      }
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
      final normalizedStageId = task.stageId.trim();
      final groupKey = lookup[normalizedStageId] ?? normalizedStageId;
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
      final normalizedStageId = task.stageId.trim();
      final groupKey = lookup[normalizedStageId] ?? normalizedStageId;
      final groupTasks = tasksByGroup[groupKey] ?? const <TaskModel>[];
      final groupHasActive = groupTasks.any((t) => t.status != TaskStatus.waiting);
      if (!groupHasActive || task.status != TaskStatus.waiting) {
        visibleWorkplaceIds.add(normalizedStageId);
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

  bool get _hasActiveFilters {
    final query = searchQuery.trim();
    final type = (productTypeFilter ?? '').trim();
    return query.isNotEmpty || type.isNotEmpty;
  }

  bool _matchesFilters(OrderModel order) {
    final query = searchQuery.trim().toLowerCase();
    if (query.isNotEmpty) {
      final id = order.id.toLowerCase();
      final assignmentId = (order.assignmentId ?? '').toLowerCase();
      final customer = order.customer.toLowerCase();
      final product = order.product.type.toLowerCase();
      final matchesQuery = id.contains(query) ||
          assignmentId.contains(query) ||
          customer.contains(query) ||
          product.contains(query);
      if (!matchesQuery) return false;
    }

    final typeFilter = (productTypeFilter ?? '').trim().toLowerCase();
    if (typeFilter.isNotEmpty) {
      final productType = order.product.type.trim().toLowerCase();
      if (productType != typeFilter) return false;
    }

    return true;
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

      if (sort == _ProductionSort.queue && !_hasActiveFilters) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          queue.syncOrders(visible.map((o) => o.id), groupId: tab.id);
        });
      }

      if (sort == _ProductionSort.queue) {
        ordered = queue.sortByPriority(visible, (o) => o.id, groupId: tab.id);
      } else {
        ordered = _sortOrders(visible);
      }
    }

    ordered = ordered.where(_matchesFilters).toList();

    if (ordered.isEmpty) {
      return const Center(
        child: Text('Нет заказов в этой категории',
            style: TextStyle(color: Colors.grey)),
      );
    }

    final canReorder =
        !tab.isCompleted && !tab.isAll && sort == _ProductionSort.queue && !_hasActiveFilters;

    final Widget listView = tab.isCompleted
        ? ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 48),
            itemCount: ordered.length,
            itemBuilder: (context, index) {
              final order = ordered[index];
              final grouping = groupingByOrder[order.id]!;
              final stageRow = stageBuilder(
                grouping.stageGroups,
                grouping.tasksByGroup,
              );
              final qty = order.product.quantity.toDouble();

              return _buildOrderRow(
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
        : canReorder
            ? ReorderableListView.builder(
                buildDefaultDragHandles: false,
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 48),
                itemCount: ordered.length,
                onReorder: (oldIndex, newIndex) {
                  if (newIndex > oldIndex) newIndex -= 1;
                  final updated = List.of(ordered);
                  final item = updated.removeAt(oldIndex);
                  updated.insert(newIndex, item);
                  queue.applyVisibleReorder(
                    updated.map((e) => e.id).toList(),
                    groupId: tab.id,
                  );
                },
                itemBuilder: (context, index) {
                  final order = ordered[index];
                  final grouping = groupingByOrder[order.id]!;
                  final stageRow = stageBuilder(
                    grouping.stageGroups,
                    grouping.tasksByGroup,
                  );
                  final qty = order.product.quantity.toDouble();

                  return _buildOrderRow(
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
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 48),
                itemCount: ordered.length,
                itemBuilder: (context, index) {
                  final order = ordered[index];
                  final grouping = groupingByOrder[order.id]!;
                  final stageRow = stageBuilder(
                    grouping.stageGroups,
                    grouping.tasksByGroup,
                  );
                  final qty = order.product.quantity.toDouble();

                  return _buildOrderRow(
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
              );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTableHeader(context),
        const SizedBox(height: 8),
        Expanded(child: listView),
      ],
    );
  }

  Widget _buildTableHeader(BuildContext context) {
    final headerStyle = const TextStyle(fontWeight: FontWeight.w600);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.grey.shade200,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 140,
              child: Text('Номер заказа', style: headerStyle),
            ),
            SizedBox(width: 110, child: Text('Дата', style: headerStyle)),
            SizedBox(width: 150, child: Text('Заказчик', style: headerStyle)),
            SizedBox(width: 130, child: Text('Продукт', style: headerStyle)),
            SizedBox(width: 120, child: Text('Размер', style: headerStyle)),
            SizedBox(width: 90, child: Text('Тираж', style: headerStyle)),
            Expanded(child: Text('Этапы', style: headerStyle)),
            SizedBox(
              width: 90,
              child: Align(
                alignment: Alignment.centerRight,
                child: Text('Действия', style: headerStyle),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOrderRow({
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
    return Container(
      key: ValueKey(order.id),
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: completed ? Colors.green.withOpacity(0.08) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          showDialog(
            context: context,
            barrierDismissible: true,
            builder: (_) => ProductionDetailsScreen(order: order),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              SizedBox(
                width: 140,
                child: Text(
                  orderDisplayId(order),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              SizedBox(
                width: 110,
                child: Text(dateFormatter(order.orderDate)),
              ),
              SizedBox(
                width: 150,
                child: Text(
                  order.customer.isNotEmpty ? order.customer : orderLabel,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(
                width: 130,
                child: Text(
                  order.product.type,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(
                width: 120,
                child: Text(
                  dimensionFormatter(order),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(
                width: 90,
                child: Text(
                  qty % 1 == 0 ? qty.toInt().toString() : qty.toString(),
                ),
              ),
              Expanded(child: stageRow),
              SizedBox(
                width: 90,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (showDragHandle && dragIndex != null)
                      ReorderableDragStartListener(
                        index: dragIndex,
                        child: const Icon(
                          Icons.drag_indicator,
                          color: Colors.grey,
                        ),
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
