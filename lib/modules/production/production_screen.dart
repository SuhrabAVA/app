import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../orders/order_deadline_timer.dart';
import '../orders/order_form_design.dart';
import '../orders/order_deadline_countdown.dart';
import '../orders/order_model.dart';
import '../orders/orders_provider.dart';
import '../personnel/personnel_provider.dart';
import '../production/production_queue_provider.dart';
import '../common/pulsing_dot.dart';
import '../personnel/workplace_model.dart';
import '../tasks/quantity_status_service.dart'
    show formatQuantityNumber, getQuantityStatusColor;
import '../tasks/stage_quantity_deviation.dart';
import '../tasks/stage_status_colors.dart';
import '../tasks/task_model.dart';
import '../tasks/task_run_state.dart';
import '../tasks/task_provider.dart';
import '../tasks/task_completion_rules.dart';
import '../production_planning/template_provider.dart';
import '../production_planning/template_model.dart';
import '../production_planning/planned_stage_model.dart';
import 'production_details_screen.dart';
import 'production_order_visibility.dart';
import 'workplace_history.dart';

/// Ширины колонок таблицы заданий. Порядок колонок — по тому, как список
/// читают в цеху: сначала кто и сколько, потом чем это делать (размер, форма,
/// продукт), и только потом маршрут по этапам.
///
/// «Заказчик» шире прежнего (было 150): при 150 длинные имена вроде «ИП Прайм
/// фуд - Пармезан» переносились на вторую строку, и такая строка становилась
/// в полтора раза выше соседних — именно из-за этого список не читался как
/// таблица.
const double _colNumber = 40;
const double _colDate = 90;
/// Срок стоит сразу за датой: в цеху решают, что брать следующим, и остаток
/// времени отвечает на это прямее любой другой колонки.
const double _colTimer = 120;
const double _colCustomer = 190;
const double _colQty = 70;
const double _colSize = 115;
const double _colFormNo = 90;
const double _colProduct = 130;

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
  if (isStageGroupFinallyCompleted(tasks)) {
    return TaskStatus.completed;
  }
  if (tasks.any((t) => t.status == TaskStatus.problem)) {
    return TaskStatus.problem;
  }
  if (tasks.any((t) => t.status == TaskStatus.inProgress)) {
    return TaskStatus.inProgress;
  }
  if (tasks.any((t) => t.status == TaskStatus.paused)) {
    return TaskStatus.paused;
  }
  return TaskStatus.waiting;
}

bool _groupCompleted(List<TaskModel> tasks) =>
    isStageGroupFinallyCompleted(tasks);

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

Map<String, String> _stageGroupLookupForGroups(
  Map<String, _StageGroupInfo> groups,
) {
  final lookup = <String, String>{};
  for (final entry in groups.entries) {
    for (final stageId in entry.value.stageIds) {
      lookup[stageId] = entry.key;
    }
  }
  return lookup;
}

Map<String, List<TaskModel>> _tasksByStageGroup(
  List<TaskModel> orderTasks,
  Map<String, String> lookup,
) {
  final byGroup = <String, List<TaskModel>>{};
  for (final task in orderTasks) {
    final normalizedStageId = task.stageId.trim();
    final persistedGroup = task.stageGroupKey.trim();
    final groupKey = persistedGroup.isNotEmpty
        ? persistedGroup
        : (lookup[normalizedStageId] ?? normalizedStageId);
    byGroup.putIfAbsent(groupKey, () => []).add(task);
  }
  return byGroup;
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

List<String> _normalizeProductionLabelParts(Iterable<String> raw) {
  final normalized = <String>[];
  final seen = <String>{};
  for (final value in raw) {
    for (final part in value.split(RegExp(r'[/,]'))) {
      final trimmed = part.trim();
      final key = trimmed.toLowerCase();
      if (trimmed.isEmpty || !seen.add(key)) continue;
      normalized.add(trimmed);
    }
  }
  if (normalized.length >= 4 && normalized.length.isEven) {
    final half = normalized.length ~/ 2;
    var mirrored = true;
    for (var i = 0; i < half; i++) {
      if (normalized[i].toLowerCase() !=
          normalized[normalized.length - 1 - i].toLowerCase()) {
        mirrored = false;
        break;
      }
    }
    if (mirrored) {
      normalized.removeRange(half, normalized.length);
    }
  }
  return normalized;
}

Map<String, _StageGroupInfo> _buildProductionStageGroupsForOrder({
  required OrderModel order,
  required List<TaskModel> orderTasks,
  required Iterable<String> plannedSequence,
  required Map<String, String> stageGroupMap,
  required List<TemplateModel> templates,
  required String Function(String stageId) labelForStage,
}) {
  final groups = <String, _StageGroupInfo>{};
  final seenLabelKeys = <String>{};

  String normalizeStageId(String id) => id.trim();

  String fallbackGroupKeyForIds(List<String> ids) {
    final canonical = ids.toSet().toList()..sort();
    return canonical.join('|');
  }

  void addGroup(
    List<String> sourceIds, {
    String? explicitKey,
    String? explicitLabel,
  }) {
    final ids = sourceIds
        .map(normalizeStageId)
        .where((id) => id.isNotEmpty)
        .fold<List<String>>(<String>[], (acc, id) {
      if (!acc.contains(id)) acc.add(id);
      return acc;
    });
    if (ids.isEmpty) return;

    final key = (explicitKey ?? '').trim().isNotEmpty
        ? explicitKey!.trim()
        : fallbackGroupKeyForIds(ids);
    if (key.isEmpty || groups.containsKey(key)) return;

    final labels = <String>[];
    final explicit = explicitLabel?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      labels.addAll(_normalizeProductionLabelParts([explicit]));
    }
    for (final id in ids) {
      final resolved = labelForStage(id).trim();
      if (resolved.isNotEmpty) {
        labels.addAll(_normalizeProductionLabelParts([resolved]));
      }
    }
    final label = _normalizeProductionLabelParts(labels).join(' / ');
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

  final sequence = <String>[];
  for (final id in plannedSequence.map(normalizeStageId)) {
    if (id.isNotEmpty && !sequence.contains(id)) {
      sequence.add(id);
    }
  }

  final plannedIdsByGroup = <String, List<String>>{};
  for (final id in sequence) {
    final mappedGroupKey = stageGroupMap[id]?.trim();
    final groupKey = mappedGroupKey != null && mappedGroupKey.isNotEmpty
        ? mappedGroupKey
        : id;
    plannedIdsByGroup.putIfAbsent(groupKey, () => <String>[]);
    final ids = plannedIdsByGroup[groupKey]!;
    if (!ids.contains(id)) ids.add(id);
  }

  final tasksByGroup = <String, List<TaskModel>>{};
  final firstTaskByStage = <String, TaskModel>{};
  for (final task in orderTasks) {
    final stageId = normalizeStageId(task.stageId);
    final groupKey = task.stageGroupKey.trim().isNotEmpty
        ? task.stageGroupKey.trim()
        : stageId;
    if (stageId.isNotEmpty) {
      firstTaskByStage.putIfAbsent(stageId, () => task);
    }
    if (groupKey.isNotEmpty) {
      tasksByGroup.putIfAbsent(groupKey, () => <TaskModel>[]).add(task);
    }
  }

  void addTaskBackedGroup(String groupKey, {String? sequenceStageId}) {
    final groupTasks = tasksByGroup[groupKey] ?? const <TaskModel>[];
    final ids = groupTasks
        .map((task) => normalizeStageId(task.stageId))
        .where((id) => id.isNotEmpty)
        .toList();
    if (ids.isEmpty && sequenceStageId != null) {
      ids.add(sequenceStageId);
    }
    addGroup(ids, explicitKey: groupKey);
  }

  for (final id in sequence) {
    final taskGroupKey = firstTaskByStage[id]?.stageGroupKey.trim();
    final mappedGroupKey = stageGroupMap[id]?.trim();
    final groupKey = taskGroupKey != null && taskGroupKey.isNotEmpty
        ? taskGroupKey
        : (mappedGroupKey != null && mappedGroupKey.isNotEmpty
            ? mappedGroupKey
            : id);
    if (tasksByGroup.containsKey(groupKey)) {
      addTaskBackedGroup(groupKey, sequenceStageId: id);
    } else {
      addGroup(plannedIdsByGroup[groupKey] ?? [id], explicitKey: groupKey);
    }
  }

  for (final entry in tasksByGroup.entries) {
    if (!groups.containsKey(entry.key)) {
      addTaskBackedGroup(entry.key);
    }
  }

  if (groups.isEmpty && sequence.isEmpty && orderTasks.isEmpty) {
    final templateId = order.stageTemplateId;
    if (templateId != null && templateId.isNotEmpty) {
      final tpl = templates.firstWhere(
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
  }

  return groups;
}

@visibleForTesting
List<String> productionStageLabelsForTesting({
  required OrderModel order,
  required List<TaskModel> orderTasks,
  required Iterable<String> plannedSequence,
  Map<String, String> stageGroupMap = const <String, String>{},
  Map<String, String> stageNames = const <String, String>{},
  List<TemplateModel> templates = const <TemplateModel>[],
}) {
  final groups = _buildProductionStageGroupsForOrder(
    order: order,
    orderTasks: orderTasks,
    plannedSequence: plannedSequence,
    stageGroupMap: stageGroupMap,
    templates: templates,
    labelForStage: (stageId) => stageNames[stageId] ?? stageId,
  );
  return groups.values.map((group) => group.label).toList(growable: false);
}

_OrderGroupingData _groupingForOrderData({
  required OrderModel order,
  required List<TaskModel> orderTasks,
  required Iterable<String> plannedSequence,
  required Map<String, String> stageGroupMap,
  required List<TemplateModel> templates,
  required String Function(String stageId) labelForStage,
}) {
  final stageGroups = _buildProductionStageGroupsForOrder(
    order: order,
    orderTasks: orderTasks,
    plannedSequence: plannedSequence,
    stageGroupMap: stageGroupMap,
    templates: templates,
    labelForStage: labelForStage,
  );
  final lookup = _stageGroupLookupForGroups(stageGroups);
  final tasksByGroup = _tasksByStageGroup(orderTasks, lookup);
  final visibleWorkplaceIds = <String>{};

  String firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      final trimmed = value?.trim() ?? '';
      if (trimmed.isNotEmpty) return trimmed;
    }
    return '';
  }

  void addVisibleForGroup(_StageGroupInfo group) {
    final groupTasks = tasksByGroup[group.key] ?? const <TaskModel>[];
    if (firstNonEmpty(group.stageIds.map((stageId) => stageId)).isEmpty) {
      return;
    }

    if (groupTasks.isEmpty) {
      // Saved queues may describe planned stages before task rows are created.
      // Show every workplace from a parallel stage group so the order is visible
      // on all equivalent workstations, not only on the first one.
      visibleWorkplaceIds.addAll(group.stageIds);
      return;
    }

    if (_groupCompleted(groupTasks)) return;

    final capturedWorkplace = firstNonEmpty(
      groupTasks.map((task) => task.capturedByWorkplaceId),
    );
    if (capturedWorkplace.isNotEmpty) {
      visibleWorkplaceIds.add(capturedWorkplace);
      return;
    }

    final activeStageIds = groupTasks
        .where((task) =>
            task.status != TaskStatus.waiting &&
            task.status != TaskStatus.completed)
        .map((task) => task.stageId.trim())
        .where((stageId) => stageId.isNotEmpty)
        .toSet();
    if (activeStageIds.isNotEmpty) {
      visibleWorkplaceIds.addAll(activeStageIds);
      return;
    }

    // Waiting parallel groups must be available on every equivalent
    // workstation; switchable stages still contain only the selected workplace
    // in the saved queue, so they remain visible on one selected tab.
    visibleWorkplaceIds.addAll(group.stageIds);
  }

  for (final group in stageGroups.values) {
    addVisibleForGroup(group);
  }

  final completed = _orderCompletedByGroups(stageGroups, tasksByGroup);
  return _OrderGroupingData(
    stageGroups: stageGroups,
    tasksByGroup: tasksByGroup,
    visibleWorkplaceIds: visibleWorkplaceIds,
    isCompleted: completed,
  );
}

@visibleForTesting
List<TaskStatus> productionStageStatusesForTesting({
  required OrderModel order,
  required List<TaskModel> orderTasks,
  required Iterable<String> plannedSequence,
  Map<String, String> stageGroupMap = const <String, String>{},
  Map<String, String> stageNames = const <String, String>{},
  List<TemplateModel> templates = const <TemplateModel>[],
}) {
  final grouping = _groupingForOrderData(
    order: order,
    orderTasks: orderTasks,
    plannedSequence: plannedSequence,
    stageGroupMap: stageGroupMap,
    templates: templates,
    labelForStage: (stageId) => stageNames[stageId] ?? stageId,
  );
  return grouping.stageGroups.values
      .map((group) => _groupStatus(grouping.tasksByGroup[group.key] ?? const []))
      .toList(growable: false);
}

@visibleForTesting
List<String> productionVisibleWorkplaceIdsForTesting({
  required OrderModel order,
  required List<TaskModel> orderTasks,
  required Iterable<String> plannedSequence,
  Map<String, String> stageGroupMap = const <String, String>{},
  Map<String, String> stageNames = const <String, String>{},
  List<TemplateModel> templates = const <TemplateModel>[],
}) {
  final grouping = _groupingForOrderData(
    order: order,
    orderTasks: orderTasks,
    plannedSequence: plannedSequence,
    stageGroupMap: stageGroupMap,
    templates: templates,
    labelForStage: (stageId) => stageNames[stageId] ?? stageId,
  );
  return grouping.visibleWorkplaceIds.toList(growable: false);
}

class ProductionScreen extends StatefulWidget {
  /// Может ли пользователь управлять ходом производства: переставлять очередь
  /// заданий, пропускать и возобновлять этапы.
  ///
  /// Менеджеру МУПЗ открыт, чтобы он видел, где стоят его заказы, но маршрутом
  /// он не управляет — это работа цеха. Просмотр, поиск, фильтры, карточка
  /// заказа, история и комментарии остаются доступны полностью: ограничение
  /// касается только действий, меняющих ход производства.
  final bool canManageProduction;

  const ProductionScreen({super.key, this.canManageProduction = true});

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

  /// Показывать только заказы с назначенным сроком завершения.
  ///
  /// «Отмеченные» — это те, кому цех назначил свой срок: в списке они видны
  /// белыми цифрами в цветной плашке. Фильтр отвечает на вопрос «что я уже
  /// пообещал», ради которого отметку и ставят.
  bool _onlyPromised = false;
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
    if (blQty != null && blQty.isNotEmpty) extras.add('');

    if (extras.isNotEmpty) {
      final extraText = extras.join(', ');
      result = result.isEmpty ? extraText : '$result ($extraText)';
    }

    return result.isEmpty ? '—' : result;
  }


  /// Лента «История»: последние заказы, уже сданные текущим рабочим местом.
  ///
  /// На вкладках «Все» и «Завершенные» рабочего места нет, поэтому там лента
  /// показывает последние полностью пройденные заказы.
  void _showHistory({
    required _ProductionTabInfo? tab,
    required List<OrderModel> allOrders,
    required List<TaskModel> allTasks,
    required Map<String, String> workplaceNamesById,
  }) {
    final isWorkplaceTab =
        tab != null && !tab.isAll && !tab.isCompleted && tab.id.trim().isNotEmpty;
    final entries = isWorkplaceTab
        ? workplaceHistory(
            workplaceId: tab.id,
            orders: allOrders,
            tasks: allTasks,
          )
        : completedOrdersHistory(orders: allOrders, tasks: allTasks);
    final title = isWorkplaceTab
        ? 'История — ${workplaceNamesById[tab.id] ?? tab.label}'
        : 'История — последние сданные заказы';

    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: OrderFormColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OrderFormMetrics.cardRadius),
        ),
        title: Text(
          title,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: OrderFormColors.text,
          ),
        ),
        content: SizedBox(
          width: 520,
          child: entries.isEmpty
              ? const Text(
                  'Сданных заказов пока нет.',
                  style: TextStyle(fontSize: 12, color: OrderFormColors.muted),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Последние ${entries.length} — новые сверху. '
                        'Откройте заказ, чтобы посмотреть этапы и комментарии '
                        'или возобновить свой этап.',
                        style: const TextStyle(
                          fontSize: 11,
                          color: OrderFormColors.muted,
                        ),
                      ),
                    ),
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: entries.length,
                        separatorBuilder: (_, __) => const Divider(
                          height: 1,
                          color: OrderFormColors.divider,
                        ),
                        itemBuilder: (context, index) => _buildHistoryRow(
                          entries[index],
                          workplaceNamesById,
                        ),
                      ),
                    ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryRow(
    WorkplaceHistoryEntry entry,
    Map<String, String> workplaceNamesById,
  ) {
    final order = entry.order;
    final label = order.customer.trim().isNotEmpty
        ? order.customer.trim()
        : (order.assignmentId ?? order.id);
    final stages = entry.stageIds
        .map((id) => workplaceNamesById[id] ?? id)
        .where((name) => name.trim().isNotEmpty)
        .join(', ');
    final doneAt = entry.doneAt > 0
        ? _formatDate(DateTime.fromMillisecondsSinceEpoch(entry.doneAt))
        : null;

    return InkWell(
      borderRadius: BorderRadius.circular(OrderFormMetrics.fieldRadius),
      onTap: () {
        // Та же карточка, что и по обычной строке МУПЗ: детали, этапы,
        // комментарии и возобновление этапа.
        showDialog<void>(
          context: context,
          barrierDismissible: true,
          builder: (_) => ProductionDetailsScreen(
            order: order,
            allowStageActions: widget.canManageProduction,
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: OrderFormColors.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if ((order.assignmentId ?? '').trim().isNotEmpty)
                        order.assignmentId!.trim(),
                      if (order.product.type.trim().isNotEmpty)
                        order.product.type.trim(),
                      if (stages.isNotEmpty) stages,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: OrderFormColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              doneAt ?? '—',
              style: const TextStyle(
                fontSize: 11,
                color: OrderFormColors.muted,
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right,
                size: 16, color: OrderFormColors.label),
          ],
        ),
      ),
    );
  }

  /// Заказ, которому принадлежат задачи этапа. `null` — заказ ещё не подъехал
  /// в провайдер: тогда сверять количество не с чем, и точка не рисуется.
  OrderModel? _orderForStageTasks(List<TaskModel> stageTasks) {
    final orderId = stageTasks.first.orderId.trim();
    if (orderId.isEmpty) return null;
    for (final order in context.read<OrdersProvider>().orders) {
      if (order.id == orderId) return order;
    }
    return null;
  }

  /// Рабочее место этапа — из него берутся единица измерения и правило
  /// деления тиража между бригадой.
  WorkplaceModel? _stageWorkplace(String stageId) =>
      context.read<PersonnelProvider>().workplaceById(stageId);

  Widget _buildStageRow(
    Map<String, _StageGroupInfo> stageGroups,
    Map<String, List<TaskModel>> tasksByGroup,
  ) {
    if (stageGroups.isEmpty) {
      return const Text('Этапы не назначены',
          style: TextStyle(fontSize: 12, color: OrderFormColors.placeholder));
    }

    final chips = <Widget>[];
    // Keep template/plan order (insertion order) instead of alphabetical sort.
    final groups = stageGroups.values.toList();

    // Доступность к началу — «предыдущий этап уже начат», то же правило, что
    // разблокирует кнопку «Начать» в рабочем пространстве. Первый этап
    // маршрута доступен всегда.
    //
    // Без этого нетронутые этапы были бы поголовно серыми, и мастер не видел
    // бы, за какой из них уже можно браться.
    var previousUnlocksNext = true;

    for (final group in groups) {
      final tasksForStage = tasksByGroup[group.key] ?? const <TaskModel>[];
      // Цвет этапа считает общий stageRunStatusForTasks — тот же, что в
      // рабочем пространстве. Своя лесенка по TaskStatus красила ожидающий и
      // приостановленный этап одинаково оранжевым, а про пересмену и
      // доступность к началу не знала вовсе: цех видел на планшете одно, а на
      // этом экране — другое.
      final status = stageRunStatusForTasks(
        tasksForStage,
        availableToStart: previousUnlocksNext,
      );
      previousUnlocksNext = stageUnlocksNextStage(status);
      final color = stageRunStatusColor(status);
      final label = group.label;

      // Сверка тиража с планом — только у завершённых этапов: пока этап идёт,
      // сделано меньше плана по определению, и точка горела бы у всех подряд.
      // Расчёт тот же, что на карточке заказа: списку и карточке нельзя
      // отвечать по-разному на вопрос «этот этап сделан правильно».
      final quantityCheck =
          status == StageRunStatus.completed && tasksForStage.isNotEmpty
              ? checkStageQuantity(
                  order: _orderForStageTasks(tasksForStage),
                  stageTasks: tasksForStage,
                  unit: _stageWorkplace(tasksForStage.first.stageId)?.unit,
                  splitByTime:
                      _stageWorkplace(tasksForStage.first.stageId)
                              ?.splitQuantityByTime ??
                          true,
                )
              : null;
      final deviationColor = quantityCheck != null && quantityCheck.isProblem
          ? getQuantityStatusColor(quantityCheck.status)
          : null;

      chips.add(Tooltip(
        message: deviationColor != null
            ? '$label — количество разошлось с планом: '
                '${formatQuantityNumber(quantityCheck!.actual)} из '
                '${formatQuantityNumber(quantityCheck.expected)} '
                '(${quantityCheck.signedPercentLabel})'
            : '$label — ${stageRunStatusLabel(status).toLowerCase()}',
        child: Container(
          margin: const EdgeInsets.only(right: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: color.withOpacity(0.10),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: (deviationColor ?? color).withOpacity(
                deviationColor != null ? 0.55 : 0.28,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (deviationColor != null)
                PulsingDot(color: deviationColor, size: 6)
              else
                Container(
                  width: 6,
                  height: 6,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ));
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: chips),
    );
  }

  /// Подпись текущего рабочего места рядом с заголовком. Нажатие открывает
  /// панель со списком — там же, где его и меняют.
  Widget _buildCurrentTabChip(_ProductionTabInfo tab) {
    final isWorkplace = !tab.isAll && !tab.isCompleted;
    final color =
        isWorkplace ? OrderFormColors.accent : OrderFormColors.muted;
    final background =
        isWorkplace ? OrderFormColors.accentSoft : OrderFormColors.fieldFill;
    final borderColor =
        isWorkplace ? OrderFormColors.accentBorder : OrderFormColors.border;

    return Tooltip(
      message: isWorkplace
          ? 'Очередь рабочего места «${tab.label}». Нажмите, чтобы выбрать другое.'
          : 'Нажмите, чтобы выбрать рабочее место',
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () => setState(() => _menuPinned = !_menuPinned),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isWorkplace
                      ? Icons.precision_manufacturing_outlined
                      : Icons.list_alt_outlined,
                  size: 14,
                  color: color,
                ),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260),
                  child: Text(
                    tab.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(Icons.expand_more, size: 15, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static OutlineInputBorder _productionFieldBorder(Color color,
          [double w = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(OrderFormMetrics.fieldRadius),
        borderSide: BorderSide(color: color, width: w),
      );

  /// Кнопки-управления в шапке: ровно та же высота и радиус, что у поиска,
  /// иначе строка фильтров разъезжается по вертикали.
  static ButtonStyle _productionControlStyle({required bool active}) =>
      OutlinedButton.styleFrom(
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        foregroundColor:
            active ? OrderFormColors.accent : OrderFormColors.muted,
        backgroundColor:
            active ? OrderFormColors.accentSoft : OrderFormColors.fieldFill,
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        side: BorderSide(
          color: active ? OrderFormColors.accentBorder : OrderFormColors.border,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OrderFormMetrics.fieldRadius),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final ordersProvider = context.watch<OrdersProvider>();
    final taskProvider = context.watch<TaskProvider>();
    final personnelProvider = context.watch<PersonnelProvider>();
    final queue = context.watch<ProductionQueueProvider>();
    final templateProvider = context.watch<TemplateProvider>();

    final orders = ordersProvider.orders
        .where(isOrderVisibleInProductionJobs)
        .toList(growable: false);
    final tasks = taskProvider.tasks;

    final productTypeOptions = {
      ..._productTypes,
      ...orders
          .map((order) => order.product.type.trim())
          .where((type) => type.isNotEmpty),
    }.toList()
      ..sort();

    final workplaceNamesById = {
      for (final workplace in personnelProvider.workplaces)
        workplace.id: workplace.name,
    };

    final tasksByOrder = <String, List<TaskModel>>{};
    for (final task in tasks) {
      tasksByOrder.putIfAbsent(task.orderId, () => []).add(task);
    }

    final groupingByOrder = <String, _OrderGroupingData>{};
    for (final order in orders) {
      final orderTasks = tasksByOrder[order.id] ?? const <TaskModel>[];
      groupingByOrder[order.id] = _groupingForOrderData(
        order: order,
        orderTasks: orderTasks,
        plannedSequence:
            taskProvider.stageSequenceForOrder(order.id) ?? const <String>[],
        stageGroupMap: taskProvider.stageGroupMapForOrder(order.id) ??
            const <String, String>{},
        templates: templateProvider.templates,
        labelForStage: (stageId) =>
            _stageLabel(stageId, taskProvider, personnelProvider, order.id),
      );
    }

    final activeStageTabs = <String, _ProductionTabInfo>{};
    for (final order in orders) {
      if (order.statusEnum != OrderStatus.in_production) continue;
      final grouping = groupingByOrder[order.id];
      if (grouping == null || grouping.isCompleted) continue;

      for (final group in grouping.stageGroups.values) {
        if (group.stageIds.isEmpty) continue;

        final groupTasks =
            grouping.tasksByGroup[group.key] ?? const <TaskModel>[];
        if (_groupCompleted(groupTasks)) continue;

        for (final stageId in group.stageIds) {
          final tabId = stageId.trim();
          if (tabId.isEmpty || !grouping.visibleWorkplaceIds.contains(tabId)) {
            continue;
          }

          activeStageTabs.putIfAbsent(
            tabId,
            () => _ProductionTabInfo(
              id: tabId,
              label: workplaceNamesById[tabId] ?? group.label,
            ),
          );
        }
      }
    }

    final tabs = [
      const _ProductionTabInfo(id: _allTabId, label: _allLabel, isAll: true),
      ...activeStageTabs.values,
      const _ProductionTabInfo(
        id: _completedTabId,
        label: _completedLabel,
        isCompleted: true,
      ),
    ];
    _ensureController(tabs.length);

    // Какое рабочее место открыто сейчас. Вкладок на экране не видно —
    // список рабочих мест живёт в выезжающей панели, — поэтому без явной
    // подписи очередь правили вслепую, не понимая, чью именно.
    final currentTab =
        tabs.isEmpty ? null : tabs[_tabIndex.clamp(0, tabs.length - 1)];

    final filterActive = _productTypeFilter != null &&
        _productTypeFilter!.trim().isNotEmpty;

    // Оформление общее с формой заказа и карточкой задания: экраны модуля
    // открываются один из другого, разный вид читался бы как разные окна.
    return Scaffold(
      backgroundColor: OrderFormColors.background,
      appBar: AppBar(
        backgroundColor: OrderFormColors.surface,
        surfaceTintColor: OrderFormColors.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        // 48, а не стандартные 56: во вкладке рабочего места эта шапка идёт
        // второй, и лишние пиксели отжимали таблицу заданий вниз. Меньше 48
        // ставить нельзя — столько занимает IconButton в строке.
        toolbarHeight: 48,
        shape: const Border(
          bottom: BorderSide(color: OrderFormColors.border),
        ),
        titleTextStyle: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: OrderFormColors.text,
        ),
        iconTheme: const IconThemeData(color: OrderFormColors.muted),
        // Кнопку «назад» подставляет сам AppBar, когда есть куда возвращаться.
        // Раньше она стояла безусловно, и во вкладке рабочего места менеджера
        // получалась мёртвая стрелка: возвращаться из корневого маршрута
        // некуда. Из панели администратора экран по-прежнему открывается
        // пушем, и кнопка остаётся на месте.
        title: Row(
          children: [
            const Flexible(
              child: Text(
                'Модуль управления производственными заданиями',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (currentTab != null) ...[
              const SizedBox(width: 12),
              _buildCurrentTabChip(currentTab),
            ],
          ],
        ),
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
                          prefixIcon: const Icon(Icons.search, size: 18),
                          suffixIcon: _searchQuery.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close, size: 16),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() {
                                      _searchQuery = '';
                                    });
                                  },
                                ),
                          isDense: true,
                          filled: true,
                          fillColor: OrderFormColors.fieldFill,
                          hintStyle: const TextStyle(
                            fontSize: 12,
                            color: OrderFormColors.placeholder,
                          ),
                          border: _productionFieldBorder(
                              OrderFormColors.border),
                          enabledBorder: _productionFieldBorder(
                              OrderFormColors.border),
                          focusedBorder: _productionFieldBorder(
                              OrderFormColors.accent, 1.4),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton.icon(
                      onPressed: () =>
                          setState(() => _onlyPromised = !_onlyPromised),
                      style: _productionControlStyle(active: _onlyPromised),
                      icon: const Icon(Icons.event_available, size: 16),
                      label: const Text('Отмеченные'),
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
                          style: _productionControlStyle(active: filterActive),
                          icon: const Icon(Icons.filter_list, size: 16),
                          label: Text(
                            filterActive
                                ? 'Тип: ${_productTypeFilter!}'
                                : 'Фильтр',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      height: 38,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: OrderFormColors.fieldFill,
                        borderRadius: BorderRadius.circular(
                          OrderFormMetrics.fieldRadius,
                        ),
                        border: Border.all(color: OrderFormColors.border),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<_ProductionSort>(
                          value: _sort,
                          isDense: true,
                          borderRadius: BorderRadius.circular(
                            OrderFormMetrics.fieldRadius,
                          ),
                          icon: const Icon(Icons.expand_more,
                              size: 18, color: OrderFormColors.muted),
                          style: const TextStyle(
                            fontSize: 12,
                            color: OrderFormColors.text,
                          ),
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
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton.icon(
                      style: _productionControlStyle(active: false),
                      onPressed: () => _showHistory(
                        tab: currentTab,
                        // Лента истории живёт вне производственных списков:
                        // заказ, сданный этим рабочим местом, мог уйти дальше
                        // по маршруту или уже отгрузиться, а вернуться к нему
                        // всё равно нужно.
                        allOrders: ordersProvider.orders,
                        allTasks: tasks,
                        workplaceNamesById: workplaceNamesById,
                      ),
                      icon: const Icon(Icons.history, size: 16),
                      label: const Text('История'),
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
                        onlyPromised: _onlyPromised,
                        sort: _sort,
                        productTypeFilter: _productTypeFilter,
                        canManageProduction: widget.canManageProduction,
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
                      color: OrderFormColors.surface,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                            decoration: const BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: OrderFormColors.border,
                                ),
                              ),
                            ),
                            child: const Text(
                              'РАБОЧИЕ МЕСТА',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.2,
                                color: OrderFormColors.label,
                              ),
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
                                    // Рабочее место выбрано — панель своё
                                    // отработала и уходит. Раньше она
                                    // оставалась открытой: закреплённой её
                                    // держал _menuPinned, а незакреплённую —
                                    // курсор, который после нажатия никуда не
                                    // уезжает. Сотрудник выбирал место и
                                    // упирался в панель поверх таблицы.
                                    setState(() {
                                      _menuPinned = false;
                                      _menuPanelHover = false;
                                      _menuEdgeHover = false;
                                    });
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    color: isSelected
                                        ? OrderFormColors.accentSoft
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
                                            ? OrderFormColors.accent
                                            : OrderFormColors.muted,
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

class _ProductionTab extends StatefulWidget {
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
    required this.onlyPromised,
    required this.sort,
    required this.productTypeFilter,
    required this.canManageProduction,
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

  /// Только заказы с назначенным сроком завершения.
  final bool onlyPromised;

  /// Проброшено из [ProductionScreen.canManageProduction]: перестановка
  /// очереди и действия над этапами в карточке.
  final bool canManageProduction;

  @override
  State<_ProductionTab> createState() => _ProductionTabState();
}

class _ProductionTabState extends State<_ProductionTab> {
  _ProductionTabInfo get tab => widget.tab;
  List<TaskModel> get allTasks => widget.allTasks;
  TaskProvider get taskProvider => widget.taskProvider;
  PersonnelProvider get personnelProvider => widget.personnelProvider;
  List<OrderModel> get orders => widget.orders;
  ProductionQueueProvider get queue => widget.queue;
  TemplateProvider get templateProvider => widget.templateProvider;
  String Function(DateTime) get dateFormatter => widget.dateFormatter;
  String Function(OrderModel) get dimensionFormatter =>
      widget.dimensionFormatter;
  Widget Function(
    Map<String, _StageGroupInfo>,
    Map<String, List<TaskModel>>,
  ) get stageBuilder => widget.stageBuilder;
  String get searchQuery => widget.searchQuery;
  _ProductionSort get sort => widget.sort;
  String? get productTypeFilter => widget.productTypeFilter;
  bool get onlyPromised => widget.onlyPromised;

  String? _lastQueueSyncGroupId;
  String? _lastQueueSyncIdsSignature;
  String? _lastStageSequenceSignature;

  String _idsSignature(Iterable<String> ids) {
    final normalized = <String>[];
    final seen = <String>{};
    for (final raw in ids) {
      final id = raw.trim();
      if (id.isEmpty || !seen.add(id)) continue;
      normalized.add(id);
    }
    normalized.sort();
    return normalized.join('|');
  }

  void _scheduleStageSequenceEnsureIfNeeded(Iterable<String> ids) {
    final signature = _idsSignature(ids);
    if (_lastStageSequenceSignature == signature) return;
    _lastStageSequenceSignature = signature;
    final orderIds = ids.toList(growable: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      taskProvider.ensureStageSequencesForOrders(orderIds);
    });
  }

  void _scheduleQueueSyncIfNeeded({
    required String groupId,
    required Iterable<WorkplaceQueueEntry> entries,
  }) {
    final entryList = entries.toList(growable: false);
    final signature = _idsSignature(entryList.map((entry) => entry.queueKey));
    if (_lastQueueSyncGroupId == groupId &&
        _lastQueueSyncIdsSignature == signature) {
      return;
    }
    _lastQueueSyncGroupId = groupId;
    _lastQueueSyncIdsSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      queue.syncWorkplaceEntries(entryList, workplaceId: groupId);
    });
  }

  WorkplaceQueueEntry _queueEntryForOrder(
    OrderModel order,
    _OrderGroupingData grouping,
    String workplaceId,
  ) {
    final normalizedWorkplaceId = workplaceId.trim();
    final group = grouping.stageGroups.values.firstWhere(
      (entry) => entry.stageIds.contains(normalizedWorkplaceId),
      orElse: () => _StageGroupInfo(
        key: normalizedWorkplaceId,
        stageIds: [normalizedWorkplaceId],
        label: normalizedWorkplaceId,
      ),
    );

    // Задачу ищем среди ВСЕХ задач заказа, а не в `tasksByGroup[group.key]`.
    //
    // Тот поиск был дефектом: задачи разложены по своему `task.stageGroupKey`,
    // а ключ группы маршрута — величина другого происхождения. Когда они не
    // совпадали, список задач оказывался пустым при живой задаче, и элемент
    // уходил на фолбэк — то есть под ключ, которого рабочее пространство
    // никогда не пишет. Дальше `missingEntries` не находил такой ключ среди
    // существующих и заводил ВТОРУЮ строку позиции на тот же слот: два
    // экрана — две очереди.
    //
    // Второй дефект того же места: `tasksForGroup.first` подставлял задачу
    // ЧУЖОГО рабочего места из параллельной группы, и в ключ уезжал его
    // stageId.
    TaskModel? task;
    for (final candidate in grouping.tasksByGroup.values.expand((t) => t)) {
      if (candidate.stageId.trim() == normalizedWorkplaceId) {
        task = candidate;
        break;
      }
      if (candidate.capturedByWorkplaceId?.trim() == normalizedWorkplaceId) {
        task ??= candidate;
      }
    }

    final taskStageGroupKey = task?.stageGroupKey.trim() ?? '';
    return WorkplaceQueueEntry.forSlot(
      workplaceId: normalizedWorkplaceId,
      taskId: task?.id,
      orderId: order.id,
      stageGroupKey:
          taskStageGroupKey.isNotEmpty ? taskStageGroupKey : group.key,
    );
  }

  _OrderGroupingData _groupingForOrder(
    OrderModel order,
    List<TaskModel> orderTasks,
  ) {
    return _groupingForOrderData(
      order: order,
      orderTasks: orderTasks,
      plannedSequence:
          taskProvider.stageSequenceForOrder(order.id) ?? const <String>[],
      stageGroupMap: taskProvider.stageGroupMapForOrder(order.id) ??
          const <String, String>{},
      templates: templateProvider.templates,
      labelForStage: (stageId) =>
          _stageLabel(stageId, taskProvider, personnelProvider, order.id),
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
    return query.isNotEmpty || type.isNotEmpty || onlyPromised;
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

    if (onlyPromised && !hasManualDeadline(order)) return false;

    return true;
  }

  bool _isOrderLockedInCurrentWorkplace(
    OrderModel order,
    _OrderGroupingData grouping,
  ) {
    final group = grouping.stageGroups.values.firstWhere(
      (entry) => entry.stageIds.contains(tab.id),
      orElse: () => const _StageGroupInfo(key: '', stageIds: [], label: ''),
    );
    if (group.stageIds.isEmpty) return false;
    final tasksForGroup =
        grouping.tasksByGroup[group.key] ?? const <TaskModel>[];
    return tasksForGroup.any((task) => task.status == TaskStatus.inProgress);
  }

  /// Назначение срока завершения: дата, затем час.
  ///
  /// Два шага, а не один: час нужен не всегда — «к пятнице» и «к пятнице на
  /// 14:00» одинаково законные обещания, и заставлять выбирать минуты ради
  /// первого случая значит мешать. Отказ от выбора времени оставляет день
  /// целиком, ровно как у срока заказчика.
  Future<void> _editPromisedDate(OrderModel order) async {
    final provider = context.read<OrdersProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final current = order.promisedAt ?? order.dueDate;
    final now = DateTime.now();

    // У отмеченного заказа сначала спрашиваем, что делать: менять срок или
    // снять отметку. Без этого шага снять её было нельзя вовсе — выбор даты
    // всегда что-то возвращает, и заказ оставался помеченным навсегда.
    if (order.promisedAt != null) {
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Срок завершения'),
          content: Text(
            'Сейчас назначен ${formatDeadlineDate(order.promisedAt!, manual: true)}.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'clear'),
              child: const Text('Убрать отметку'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'edit'),
              child: const Text('Изменить'),
            ),
          ],
        ),
      );
      if (action == null || !mounted) return;
      if (action == 'clear') {
        try {
          await provider.setOrderPromisedDate(order, null);
          if (!mounted) return;
          messenger.showSnackBar(
            const SnackBar(content: Text('Отметка убрана')),
          );
        } catch (e) {
          if (!mounted) return;
          messenger.showSnackBar(
            SnackBar(content: Text('Не удалось убрать отметку: $e')),
          );
        }
        return;
      }
    }

    final date = await showDatePicker(
      context: context,
      initialDate: current ?? now,
      // Назад — на случай, когда срок назначают задним числом по факту.
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
      helpText: 'Когда заказ будет завершён',
      cancelText: 'Отмена',
      confirmText: 'Далее',
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: current == null
          ? const TimeOfDay(hour: 0, minute: 0)
          : TimeOfDay(hour: current.hour, minute: current.minute),
      helpText: 'Время (необязательно)',
      cancelText: 'Без времени',
      confirmText: 'Сохранить',
    );
    if (!mounted) return;

    final promised = DateTime(
      date.year,
      date.month,
      date.day,
      time?.hour ?? 0,
      time?.minute ?? 0,
    );

    try {
      await provider.setOrderPromisedDate(order, promised);
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Срок завершения назначен')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Не удалось назначить срок: $e')),
      );
    }
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
    _scheduleStageSequenceEnsureIfNeeded(orders.map((order) => order.id));

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
    } else if (tab.isAll) {
      ordered = orders.toList();
      ordered = _sortOrders(ordered);
    } else {
      final visible = orders.where((o) {
        final grouping = groupingByOrder[o.id];
        if (grouping == null || grouping.isCompleted) return false;
        if (!grouping.visibleWorkplaceIds.contains(tab.id)) return false;
        return !queue.isHidden(o.id, groupId: tab.id);
      }).toList();

      if (sort == _ProductionSort.queue && !_hasActiveFilters) {
        _scheduleQueueSyncIfNeeded(
          groupId: tab.id,
          entries: visible.map((order) => _queueEntryForOrder(
                order,
                groupingByOrder[order.id]!,
                tab.id,
              )),
        );
      }

      // Позиции именно этого рабочего места, всегда из базы.
      queue.ensurePositionsLoaded(tab.id);

      // Пока позиции не пришли, список по очереди строить нельзя: без них
      // priorityOfEntry возвращает «бесконечность» для всех заказов, и порядок
      // вырождается в тот, в котором заказы лежат в памяти — у каждого
      // устройства свой. Раньше эту дыру затыкал снимок с диска, и расхождение
      // между планшетами становилось незаметным. Теперь показываем правду.
      if (sort == _ProductionSort.queue &&
          !queue.positionsLoadedFor(tab.id)) {
        return queue.positionsLoadingFor(tab.id)
            ? const Center(child: CircularProgressIndicator())
            : _QueueUnavailable(
                workplaceLabel: tab.label,
                onRetry: () => queue.ensurePositionsLoaded(tab.id),
              );
      }

      if (sort == _ProductionSort.queue) {
        ordered = queue.getSortedByWorkplaceQueue(
          visible,
          (order) => _queueEntryForOrder(
            order,
            groupingByOrder[order.id]!,
            tab.id,
          ),
        );
      } else {
        ordered = _sortOrders(visible);
      }
    }

    ordered = ordered.where(_matchesFilters).toList();

    if (ordered.isEmpty) {
      return const Center(
        child: Text('Нет заказов в этой категории',
            style: TextStyle(fontSize: 13, color: OrderFormColors.placeholder)),
      );
    }

    final canReorder =
        widget.canManageProduction &&
        !tab.isCompleted &&
        !tab.isAll &&
        sort == _ProductionSort.queue &&
        !_hasActiveFilters;

    final Widget listView = tab.isCompleted
        ? ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 48),
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
                rowNumber: index + 1,
              );
            },
          )
        : canReorder
            ? ReorderableListView.builder(
                buildDefaultDragHandles: false,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 48),
                itemCount: ordered.length,
                onReorder: (oldIndex, newIndex) {
                  if (newIndex > oldIndex) newIndex -= 1;
                  if (oldIndex < 0 ||
                      oldIndex >= ordered.length ||
                      newIndex < 0 ||
                      newIndex >= ordered.length) {
                    return;
                  }
                  final movedOrder = ordered[oldIndex];
                  final movedGrouping = groupingByOrder[movedOrder.id];
                  final movedLocked = movedGrouping != null &&
                      _isOrderLockedInCurrentWorkplace(
                        movedOrder,
                        movedGrouping,
                      );
                  if (movedLocked) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Нельзя менять очередь: этот этап уже выполняется.',
                        ),
                      ),
                    );
                    return;
                  }
                  final updated = List.of(ordered);
                  final item = updated.removeAt(oldIndex);
                  updated.insert(newIndex, item);
                  unawaited(() async {
                    try {
                      await queue.applyVisibleTaskReorder(
                        workplaceId: tab.id,
                        orderedKeys: updated
                            .map((order) => WorkplaceQueueItemKey.fromEntry(
                                  _queueEntryForOrder(
                                    order,
                                    groupingByOrder[order.id]!,
                                    tab.id,
                                  ),
                                ))
                            .toList(growable: false),
                      );
                    } catch (e) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Не удалось сохранить очередь: $e'),
                        ),
                      );
                    }
                  }());
                },
                itemBuilder: (context, index) {
                  final order = ordered[index];
                  final grouping = groupingByOrder[order.id]!;
                  final stageRow = stageBuilder(
                    grouping.stageGroups,
                    grouping.tasksByGroup,
                  );
                  final qty = order.product.quantity.toDouble();

                  final queueEntry =
                      _queueEntryForOrder(order, grouping, tab.id);

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
                    rowNumber: index + 1,
                    dragIndex: index,
                    rowKey: ValueKey(queueEntry.queueKey),
                  );
                },
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 48),
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
                    rowNumber: index + 1,
                  );
                },
              );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTableHeader(context),
        Expanded(child: listView),
      ],
    );
  }

  Widget _buildTableHeader(BuildContext context) {
    const headerStyle = TextStyle(
      fontSize: 10.5,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.1,
      color: OrderFormColors.label,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        // Шапка и строки — один сплошной блок: рамка только снизу, без
        // скругления. Раньше шапка была отдельной карточкой в рамке, под ней
        // шёл зазор, а дальше — россыпь карточек-заказов.
        decoration: const BoxDecoration(
          color: OrderFormColors.surface,
          border: Border(
            bottom: BorderSide(color: OrderFormColors.border),
          ),
        ),
        child: const Row(
          children: [
            SizedBox(width: _colNumber, child: Text('№', style: headerStyle)),
            SizedBox(width: _colDate, child: Text('ДАТА', style: headerStyle)),
            SizedBox(
              width: _colTimer,
              child: Text('ОСТАЛОСЬ', style: headerStyle),
            ),
            SizedBox(
              width: _colCustomer,
              child: Text('ЗАКАЗЧИК', style: headerStyle),
            ),
            SizedBox(width: _colQty, child: Text('ТИРАЖ', style: headerStyle)),
            SizedBox(
              width: _colSize,
              child: Text('РАЗМЕР', style: headerStyle),
            ),
            SizedBox(
              width: _colFormNo,
              child: Text('НОМЕР ФОРМЫ', style: headerStyle),
            ),
            SizedBox(
              width: _colProduct,
              child: Text('ПРОДУКТ', style: headerStyle),
            ),
            Expanded(child: Text('ЭТАПЫ', style: headerStyle)),
          ],
        ),
      ),
    );
  }

  /// Номер формы заказа — только цифра, без пометки «старая»/«новая»:
  /// в цеху по этому номеру ищут оснастку, а её возраст роли не играет.
  String _formNumberLabel(OrderModel order) {
    final number = order.newFormNo;
    if (number != null && number > 0) return '$number';
    final code = (order.formCode ?? '').trim();
    if (code.isNotEmpty) return code;
    return '—';
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
    required int rowNumber,
    int? dragIndex,
    Key? rowKey,
  }) {
    final customerText =
        order.customer.isNotEmpty ? order.customer : orderLabel;

    // Строка таблицы, а не карточка. Раньше каждый заказ был отдельной
    // карточкой с рамкой, скруглением и отступом снизу — между заказами
    // набегало 6 px пустоты, и на экран помещалось на треть меньше строк.
    // Теперь строки идут вплотную и разделены линией, как в таблице.
    final content = Container(
      decoration: BoxDecoration(
        color: completed ? OrderFormColors.greenBg : OrderFormColors.surface,
        border: const Border(
          bottom: BorderSide(color: OrderFormColors.border),
        ),
      ),
      child: InkWell(
        onTap: () {
          showDialog(
            context: context,
            barrierDismissible: true,
            builder: (_) => ProductionDetailsScreen(
              order: order,
              // Управлять маршрутом можно только отсюда: из оформления
              // заказа карточка открывается только для просмотра. У менеджера
              // МУПЗ тоже открыт на просмотр — см. canManageProduction.
              allowStageActions: widget.canManageProduction,
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: DefaultTextStyle.merge(
            style: const TextStyle(
              fontSize: 12,
              color: OrderFormColors.muted,
            ),
            child: Row(
              children: [
                // Порядковый номер строки. В режиме очереди это и есть место
                // заказа в очереди рабочего места, поэтому там он выделен.
                SizedBox(
                  width: _colNumber,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: showDragHandle
                        ? Container(
                            constraints: const BoxConstraints(minWidth: 26),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 3),
                            decoration: BoxDecoration(
                              color: OrderFormColors.accentSoft,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                  color: OrderFormColors.accentBorder),
                            ),
                            child: Text(
                              '$rowNumber',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: OrderFormColors.accent,
                              ),
                            ),
                          )
                        : Text(
                            '$rowNumber',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: OrderFormColors.muted,
                            ),
                          ),
                  ),
                ),
                SizedBox(
                  width: _colDate,
                  child: Text(
                    dateFormatter(order.orderDate),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                SizedBox(
                  width: _colTimer,
                  // Срок правится ТОЛЬКО отсюда: в МУПЗ видно очередь целиком,
                  // и только здесь сотрудник понимает, когда закончит. В
                  // остальных модулях назначенный срок показывается, но не
                  // редактируется.
                  child: Tooltip(
                    message: 'Нажмите, чтобы назначить срок завершения',
                    child: InkWell(
                      onTap: () => _editPromisedDate(order),
                      borderRadius: BorderRadius.circular(6),
                      child: OrderDeadlineTimer(order: order, fontSize: 12),
                    ),
                  ),
                ),
                SizedBox(
                  width: _colCustomer,
                  // Все ячейки — в одну строку: высота строки перестаёт
                  // зависеть от длины имени, и таблица идёт ровной сеткой.
                  // Полное имя остаётся во всплывающей подсказке и в карточке
                  // заказа, которая открывается по клику.
                  child: Tooltip(
                    message: customerText,
                    waitDuration: const Duration(milliseconds: 600),
                    child: Text(
                      customerText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: OrderFormColors.text,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: _colQty,
                  child: Text(
                    qty % 1 == 0 ? qty.toInt().toString() : qty.toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: OrderFormColors.text,
                    ),
                  ),
                ),
                SizedBox(
                  width: _colSize,
                  child: Text(
                    dimensionFormatter(order),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                SizedBox(
                  width: _colFormNo,
                  child: Text(
                    _formNumberLabel(order),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: OrderFormColors.text,
                    ),
                  ),
                ),
                SizedBox(
                  width: _colProduct,
                  child: Text(
                    order.product.type,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Этапы занимают весь остаток строки: колонки «Номер заказа»
                // и «Действия» убраны, а тянуть заказ можно за любое место.
                Expanded(child: stageRow),
              ],
            ),
          ),
        ),
      ),
    );

    final key = rowKey ?? ValueKey(order.id);
    if (showDragHandle && dragIndex != null) {
      // Тянуть можно за любое место строки, а не только за иконку с точками.
      //
      // Мышью и пальцем это разные жесты, поэтому распознаватель выбираем по
      // платформе — ровно так же, как делает сам ReorderableListView в
      // buildDefaultDragHandles:
      //   * десктоп — перенос начинается сразу по движению зажатой кнопки.
      //     Отложенный распознаватель здесь не работает вовсе: он отменяется,
      //     если курсор сдвинулся раньше, чем истекла задержка, а мышью тянут
      //     одним движением;
      //   * тач — только после удержания, иначе вертикальный свайп таскал бы
      //     карточку вместо прокрутки списка.
      //
      // Короткий тап в обоих случаях остаётся за InkWell и открывает карточку:
      // распознаватель переноса забирает жест только после движения.
      final platform = Theme.of(context).platform;
      final dragOnMove = platform == TargetPlatform.windows ||
          platform == TargetPlatform.linux ||
          platform == TargetPlatform.macOS;
      if (dragOnMove) {
        return ReorderableDragStartListener(
          key: key,
          index: dragIndex,
          child: content,
        );
      }
      return ReorderableDelayedDragStartListener(
        key: key,
        index: dragIndex,
        child: content,
      );
    }
    return KeyedSubtree(key: key, child: content);
  }
}
/// Состояние «очередь не загружена»: позиции рабочего места не пришли из базы.
///
/// Показывается вместо списка, отсортированного по очереди. Причина — в том,
/// что без позиций сортировка вырождается в порядок заказов в памяти, а он у
/// каждого устройства свой: именно так соседние планшеты показывали разную
/// очередь, и оба выглядели правдоподобно.
class _QueueUnavailable extends StatelessWidget {
  const _QueueUnavailable({
    required this.workplaceLabel,
    required this.onRetry,
  });

  final String workplaceLabel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off,
                size: 40, color: OrderFormColors.placeholder),
            const SizedBox(height: 12),
            Text(
              'Очередь «$workplaceLabel» не загружена',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: OrderFormColors.text,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Нет связи с базой. Показывать порядок наугад нельзя — '
              'он разойдётся с другими устройствами.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: OrderFormColors.muted),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Повторить'),
            ),
          ],
        ),
      ),
    );
  }
}
