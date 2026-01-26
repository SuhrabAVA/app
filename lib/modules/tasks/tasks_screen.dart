import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../orders/order_model.dart';
import '../orders/id_format.dart';
import '../orders/orders_provider.dart';
import '../personnel/employee_model.dart';
import '../personnel/personnel_provider.dart';
import '../personnel/workplace_model.dart';
import '../analytics/analytics_provider.dart';
import '../production/production_queue_provider.dart';
import '../production_planning/template_provider.dart';
import '../production_planning/template_model.dart';
import '../production_planning/planned_stage_model.dart';
import 'task_model.dart';
import 'task_provider.dart';
import '../common/pdf_view_screen.dart';
import '../../services/storage_service.dart';
// Additional helpers for time formatting and aggregated timers

class TasksScreen extends StatefulWidget {
  final String employeeId;
  final bool showListOnly;
  final bool hideListPanel;
  final bool compactList;

  const TasksScreen({
    super.key,
    required this.employeeId,
    this.showListOnly = false,
    this.hideListPanel = false,
    this.compactList = false,
  });

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

// === Execution mode per stage/assignee =======================================
enum ExecutionMode { solo, separate, joint }

ExecutionMode? _parseExecutionModeLabel(String raw) {
  final t = raw.toLowerCase();
  if (t.contains('joint') || t.contains('помощ')) {
    return ExecutionMode.joint;
  }
  if (t.contains('separ') || t.contains('отдель')) {
    return ExecutionMode.separate;
  }
  if (t.contains('solo') ||
      t.contains('один') ||
      t.contains('одиноч') ||
      t.contains('совмест')) {
    return ExecutionMode.joint;
  }
  return null;
}

ExecutionMode? _stageExecutionMode(TaskModel task) {
  final stageModeComment = task.comments
      .where((c) => c.type == 'exec_mode_stage')
      .toList()
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  if (stageModeComment.isNotEmpty) {
    for (final comment in stageModeComment.reversed) {
      final parsed = _parseExecutionModeLabel(comment.text);
      if (parsed != null) return parsed;
    }
  }

  // Backward compatibility: infer from per-user exec_mode comments.
  final perUser = task.comments.where((c) => c.type == 'exec_mode');
  if (perUser.isNotEmpty) {
    bool anyJoint = false;
    bool anySeparate = false;
    for (final comment in perUser) {
      final parsed = _parseExecutionModeLabel(comment.text);
      if (parsed == ExecutionMode.joint) anyJoint = true;
      if (parsed == ExecutionMode.separate) anySeparate = true;
    }
    if (anyJoint && !anySeparate) return ExecutionMode.joint;
    if (anySeparate && !anyJoint) return ExecutionMode.separate;
  }

  return null;
}

ExecutionMode _execModeForUser(TaskModel task, String userId) {
  final stageMode = _stageExecutionMode(task);
  if (stageMode != null) {
    if (stageMode == ExecutionMode.joint) {
      return ExecutionMode.joint;
    }
    if (stageMode == ExecutionMode.solo) {
      return ExecutionMode.joint;
    }
    // separate stage
    return ExecutionMode.separate;
  }

  final cm =
      task.comments.where((c) => c.type == 'exec_mode' && c.userId == userId);
  if (cm.isNotEmpty) {
    final t = cm.last.text.toLowerCase();
    if (t.contains('separ') || t.contains('отдель')) {
      return ExecutionMode.separate;
    }
    return ExecutionMode.joint;
  }
  // By default treat as separate unless explicitly marked as joint via exec_mode.
  return ExecutionMode.separate;
}

String _executionModeCode(ExecutionMode mode) {
  switch (mode) {
    case ExecutionMode.solo:
      return 'joint';
    case ExecutionMode.separate:
      return 'separate';
    case ExecutionMode.joint:
      return 'joint';
  }
}

ExecutionMode _workplaceDefaultMode(WorkplaceModel stage) {
  return stage.executionMode == WorkplaceExecutionMode.separate
      ? ExecutionMode.separate
      : ExecutionMode.joint;
}

bool _needsExecModeRecord(
    TaskModel task, String userId, ExecutionMode desiredMode) {
  final records = task.comments
      .where((c) => c.type == 'exec_mode' && c.userId == userId)
      .toList();
  if (records.isEmpty) return true;
  final last = records.last;
  final parsed = _parseExecutionModeLabel(last.text);
  return parsed != desiredMode;
}

String _timeTypeLabel(TaskTimeType type) {
  switch (type) {
    case TaskTimeType.production:
      return 'Производство';
    case TaskTimeType.pause:
      return 'Пауза';
    case TaskTimeType.problem:
      return 'Проблема';
    case TaskTimeType.shiftChange:
      return 'Пересмена';
    case TaskTimeType.setup:
      return 'Наладка';
  }
}

List<TaskTimeEvent> _taskTimeEvents(TaskModel task) {
  final events = <TaskTimeEvent>[];
  for (final comment in task.comments) {
    if (comment.type != 'time_event') continue;
    final parsed = TaskTimeEvent.fromPayload(
        comment.text, comment.id, comment.timestamp, comment.userId);
    if (parsed != null) events.add(parsed);
  }
  events.sort((a, b) => a.startTime.compareTo(b.startTime));
  return events;
}

List<TaskTimeEvent> _timeEventsForUser(TaskModel task, String userId) {
  return _taskTimeEvents(task)
      .where((e) => e.subjectUserId == userId)
      .toList();
}

TaskTimeEvent? _openEventForUser(TaskModel task, String userId) {
  final events = _timeEventsForUser(task, userId)
      .where((e) => e.endTime == null)
      .toList();
  if (events.isEmpty) return null;
  events.sort((a, b) => a.startTime.compareTo(b.startTime));
  return events.last;
}

Map<TaskTimeType, Duration> _timeTotalsForUser(TaskModel task, String userId) {
  final totals = <TaskTimeType, Duration>{
    for (final type in TaskTimeType.values) type: Duration.zero,
  };
  final now = DateTime.now().toUtc();
  for (final event in _timeEventsForUser(task, userId)) {
    final end = event.endTime ?? now;
    final diff = end.difference(event.startTime);
    totals[event.type] = (totals[event.type] ?? Duration.zero) + diff;
  }
  return totals;
}

Duration _totalTimeForUser(TaskModel task, String userId) {
  final totals = _timeTotalsForUser(task, userId);
  return totals.values.fold(Duration.zero, (acc, d) => acc + d);
}

enum UserRunState { idle, active, paused, finished, problem }

UserRunState _userRunState(TaskModel task, String userId) {
  final timeEvents = _timeEventsForUser(task, userId);
  if (timeEvents.isNotEmpty) {
    final open = _openEventForUser(task, userId);
    if (open != null) {
      switch (open.type) {
        case TaskTimeType.production:
        case TaskTimeType.setup:
          return UserRunState.active;
        case TaskTimeType.pause:
        case TaskTimeType.shiftChange:
          return UserRunState.paused;
        case TaskTimeType.problem:
          return UserRunState.problem;
      }
    }
    final doneEvents =
        task.comments.where((c) => c.type == 'user_done' && c.userId == userId);
    if (doneEvents.isNotEmpty) {
      doneEvents.toList().sort((a, b) => a.timestamp.compareTo(b.timestamp));
      final lastDone = doneEvents.last.timestamp;
      final lastEventTs = timeEvents
          .map((e) => (e.endTime ?? e.startTime).millisecondsSinceEpoch)
          .fold<int>(0, (a, b) => a > b ? a : b);
      if (lastDone >= lastEventTs) {
        return UserRunState.finished;
      }
    }
    return UserRunState.idle;
  }

  final events = task.comments
      .where((c) =>
          c.userId == userId &&
          (c.type == 'start' ||
              c.type == 'pause' ||
              c.type == 'resume' ||
              c.type == 'user_done' ||
              c.type == 'problem'))
      .toList()
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  if (events.isEmpty) return UserRunState.idle;
  final last = events.last;
  switch (last.type) {
    case 'start':
    case 'resume':
      return UserRunState.active;
    case 'pause':
      return UserRunState.paused;
    case 'user_done':
      return UserRunState.finished;
    case 'problem':
      return UserRunState.problem;
    default:
      return UserRunState.idle;
  }
}

List<TaskModel> _relatedTasks(TaskProvider provider, TaskModel pivot) {
  return provider.tasks
      .where((t) => t.orderId == pivot.orderId && t.stageId == pivot.stageId)
      .toList();
}

int _activeExecutorsCountForStage(TaskProvider provider, TaskModel pivot) {
  final related = _relatedTasks(provider, pivot);
  int count = 0;
  for (final t in related) {
    if (t.status == TaskStatus.inProgress) {
      final a = t.assignees.isEmpty
          ? (t.status == TaskStatus.inProgress ? 1 : 0)
          : t.assignees
              .where((uid) => _userRunState(t, uid) == UserRunState.active)
              .length;
      count += a;
    }
  }
  return count;
}

List<String> _helperIds(TaskModel task) {
  if (task.assignees.isEmpty) return const [];
  final ownerId = task.assignees.first;
  final jointUsers = task.assignees
      .where((id) => _execModeForUser(task, id) == ExecutionMode.joint)
      .toList();
  return jointUsers.where((id) => id != ownerId).toList();
}

List<String> _participantsSnapshot(TaskModel task, String userId) {
  final participants = List<String>.from(task.assignees);
  if (!participants.contains(userId)) {
    participants.add(userId);
  }
  return participants;
}

Duration _userElapsed(TaskModel task, String userId) {
  final timeEvents = _timeEventsForUser(task, userId);
  if (timeEvents.isNotEmpty) {
    return _totalTimeForUser(task, userId);
  }

  final events = task.comments
      .where((c) =>
          c.userId == userId &&
          (c.type == 'start' ||
              c.type == 'resume' ||
              c.type == 'pause' ||
              c.type == 'user_done' ||
              c.type == 'problem'))
      .toList()
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  int acc = 0;
  int? open;
  for (final e in events) {
    if (e.type == 'start' || e.type == 'resume') {
      open = e.timestamp;
    } else if (open != null &&
        (e.type == 'pause' || e.type == 'user_done' || e.type == 'problem')) {
      acc += e.timestamp - open;
      open = null;
    }
  }
  if (open != null) {
    acc += DateTime.now().millisecondsSinceEpoch - open;
  }
  return Duration(milliseconds: acc);
}

bool _anyUserActive(TaskModel task, {String? exceptUserId}) {
  for (final uid in task.assignees) {
    if (exceptUserId != null && uid == exceptUserId) continue;
    if (_userRunState(task, uid) == UserRunState.active) return true;
  }
  if (task.assignees.isEmpty) {
    return task.status == TaskStatus.inProgress;
  }
  return false;
}

bool _containsFlexo(String text) {
  final lower = text.toLowerCase();
  return lower.contains('флекс') || lower.contains('flexo');
}

bool _containsBobbin(String text) {
  final lower = text.toLowerCase();
  return lower.contains('бобин') ||
      lower.contains('бабин') ||
      lower.contains('bobbin');
}

String _workplaceName(PersonnelProvider personnel, String stageId,
    {TaskProvider? tasks, String? orderId}) {
  try {
    final wp = personnel.workplaces.firstWhere((w) => w.id == stageId);
    if (wp.name.isNotEmpty) return wp.name;
  } catch (_) {}

  if (tasks != null) {
    final resolvedName = tasks.stageNameForOrder(orderId ?? '', stageId);
    if (resolvedName != null && resolvedName.isNotEmpty) return resolvedName;
  }

  return stageId;
}

String _stageLabelForOrder(
    PersonnelProvider personnel,
    TemplateProvider templates,
    OrdersProvider orders,
    TaskProvider tasks,
    String orderId,
    String stageId) {
  OrderModel? order;
  try {
    order = orders.orders.firstWhere((o) => o.id == orderId);
  } catch (_) {}
  final templateId = order?.stageTemplateId;
  if (templateId == null || templateId.isEmpty) {
    return _workplaceName(personnel, stageId, tasks: tasks, orderId: orderId);
  }

  PlannedStage? planned;
  for (final tpl in templates.templates) {
    if (tpl.id != templateId) continue;
    for (final stage in tpl.stages) {
      if (stage.allStageIds.contains(stageId)) {
        planned = stage;
        break;
      }
    }
  }

  if (planned == null) {
    return _workplaceName(personnel, stageId, tasks: tasks, orderId: orderId);
  }

  final labels = <String>{};
  for (final id in planned.allStageIds) {
    labels.add(_workplaceName(personnel, id, tasks: tasks, orderId: orderId));
  }
  return labels.join(' / ');
}

Map<String, String> _stageGroupMapForOrder(
  OrderModel order,
  TemplateProvider templates,
) {
  final templateId = order.stageTemplateId;
  if (templateId == null || templateId.isEmpty) return const {};
  final tpl = templates.templates
      .firstWhere(
        (t) => t.id == templateId,
        orElse: () =>
            TemplateModel(id: '', name: '', stages: const <PlannedStage>[]),
      );
  if (tpl.id.isEmpty) return const {};

  final map = <String, String>{};
  for (final stage in tpl.stages) {
    final ids = stage.allStageIds.where((id) => id.trim().isNotEmpty).toList();
    if (ids.isEmpty) continue;
    final sortedIds = List<String>.from(ids)..sort();
    final key = sortedIds.join('|');
    for (final id in sortedIds) {
      map[id] = key;
    }
  }
  return map;
}

String? _workplaceUnit(PersonnelProvider personnel, String stageId) {
  final wp = personnel.workplaceById(stageId);
  final text = wp?.unit?.trim();
  if (text != null && text.isNotEmpty) return text;
  return null;
}

bool _isFlexoStageId(PersonnelProvider personnel, String stageId) {
  final probes = <String>{stageId, _workplaceName(personnel, stageId)};
  for (final probe in probes) {
    if (_containsFlexo(probe)) return true;
  }
  return false;
}

bool _isBobbinStageId(PersonnelProvider personnel, String stageId) {
  final probes = <String>{stageId, _workplaceName(personnel, stageId)};
  for (final probe in probes) {
    if (_containsBobbin(probe)) return true;
  }
  return false;
}

void _ensureFlexoOrdering(List<String> stageIds, PersonnelProvider personnel) {
  if (stageIds.length <= 1) return;

  final flexoIndex =
      stageIds.indexWhere((id) => _isFlexoStageId(personnel, id));
  if (flexoIndex == -1) return;

  final bobbinIndex =
      stageIds.indexWhere((id) => _isBobbinStageId(personnel, id));

  final adjusted = List<String>.from(stageIds);
  final flexoId = adjusted.removeAt(flexoIndex);

  if (bobbinIndex == -1) {
    adjusted.insert(0, flexoId);
    stageIds
      ..clear()
      ..addAll(adjusted);
    return;
  }

  var bobIndex = bobbinIndex;
  if (bobbinIndex > flexoIndex) {
    bobIndex -= 1;
  }
  if (bobIndex < 0) {
    bobIndex = 0;
  } else if (bobIndex >= adjusted.length) {
    bobIndex = adjusted.length - 1;
  }

  final bobbinId = adjusted.removeAt(bobIndex);
  adjusted.insert(0, bobbinId);
  final insertIndex = adjusted.isEmpty ? 0 : 1;
  final safeIndex = insertIndex < 0
      ? 0
      : (insertIndex > adjusted.length ? adjusted.length : insertIndex);
  adjusted.insert(safeIndex, flexoId);

  stageIds
    ..clear()
    ..addAll(adjusted);
}

/// Разрешить старт только для самого первого незавершённого этапа заказа
typedef StageGroupingResolver = String Function(String orderId, String stageId);

bool _isFirstPendingStage(TaskProvider tasks, PersonnelProvider personnel,
    TaskModel task,
    {StageGroupingResolver? groupResolver}) {
  String _groupKey(String stageId) =>
      groupResolver?.call(task.orderId, stageId) ?? stageId;

  // Все задачи этого заказа
  final all = tasks.tasks.where((t) => t.orderId == task.orderId).toList();
  if (all.isEmpty) return true;

  // Сгруппировать по этапу; фиксируем и незавершённые, и уже завершённые
  // альтернативы, чтобы не блокировать последующие этапы, когда одна из
  // альтернатив завершена.
  final stages = <String, Map<String, bool>>{}; // stageId -> {pending, completed}
  for (final t in all) {
    final pending = t.status != TaskStatus.completed;
    final completed = t.status == TaskStatus.completed;
    final key = _groupKey(t.stageId);
    final current = stages[key] ?? {'pending': false, 'completed': false};
    stages[key] = {
      'pending': current['pending'] == true || pending,
      'completed': current['completed'] == true || completed,
    };
  }

  // Отфильтровать только pending этапы
  final pendingStageIds = stages.entries
      .where((e) => e.value['pending'] == true && e.value['completed'] != true)
      .map((e) => e.key)
      .toList();
  if (pendingStageIds.isEmpty) return true;

  final orderedStages = tasks.stageSequenceForOrder(task.orderId) ?? const [];
  if (orderedStages.isNotEmpty) {
    final orderedKeys = <String>[];
    for (final id in orderedStages) {
      final k = _groupKey(id);
      if (!orderedKeys.contains(k)) orderedKeys.add(k);
    }
    final indexMap = <String, int>{};
    for (var i = 0; i < orderedKeys.length; i++) {
      indexMap.putIfAbsent(orderedKeys[i], () => i);
    }
    pendingStageIds.sort((a, b) {
      final ia = indexMap[a];
      final ib = indexMap[b];
      if (ia != null && ib != null) return ia.compareTo(ib);
      if (ia != null) return -1;
      if (ib != null) return 1;
      return a.compareTo(b);
    });
  } else {
    // Отсортировать по названию рабочего места (fallback к id)
    int byName(String a, String b) {
      String name(String id) {
        try {
          final w = personnel.workplaces.firstWhere((w) => w.id == id);
          return (w.name.isNotEmpty ? w.name : id).toLowerCase();
        } catch (_) {
          return id.toLowerCase();
        }
      }

      return name(a).compareTo(name(b));
    }

    pendingStageIds.sort(byName);
    _ensureFlexoOrdering(pendingStageIds, personnel);
  }

  // Первый незавершённый этап
  final firstPendingStageId = pendingStageIds.first;

  // Разрешаем старт, если наш task относится к самому первому незавершённому этапу
  return _groupKey(task.stageId) == firstPendingStageId;
}

class _StageComment {
  final TaskComment comment;
  final String stageId;
  final String taskId;

  const _StageComment({
    required this.comment,
    required this.stageId,
    required this.taskId,
  });
}

class _QuantityInput {
  final int quantity;
  final String displayText;

  const _QuantityInput({required this.quantity, required this.displayText});
}

class _TaskSelectionState extends ChangeNotifier {
  String? workplaceId;
  TaskModel? task;
  TaskStatus status;

  _TaskSelectionState({
    this.workplaceId,
    this.task,
    this.status = TaskStatus.waiting,
  });
}

final Map<String, _TaskSelectionState> _selectionCache = {};

class _TasksScreenState extends State<TasksScreen>
    with AutomaticKeepAliveClientMixin<TasksScreen> {
  @override
  bool get wantKeepAlive => true;
  // Compatibility shim: legacy takenByAnother flag removed
  bool get takenByAnother => false;

  final TextEditingController _chatController = TextEditingController();
  late final _TaskSelectionState _selection;
  String? get _selectedWorkplaceId => _selection.workplaceId;
  set _selectedWorkplaceId(String? value) {
    final normalized = value?.trim();
    if (_selection.workplaceId == normalized) return;
    _selection.workplaceId = normalized;
    _selection.notifyListeners();
  }
  TaskModel? get _selectedTask => _selection.task;
  set _selectedTask(TaskModel? value) {
    if (identical(_selection.task, value)) return;
    _selection.task = value;
    _selection.notifyListeners();
  }
  bool _detailsExpanded = true;
  final Map<String, String?> _formImageCache = {};
  final Map<String, Future<String?>> _formImagePending = {};
  final Map<String, Map<String, _StageComment>> _orderCommentsCache = {};
  String get _widKey => 'ws-${widget.employeeId}-wid';
  String get _tidKey => 'ws-${widget.employeeId}-tid';
  static const Map<TaskStatus, String> _statusLabels = {
    TaskStatus.waiting: 'В ожидании',
    TaskStatus.inProgress: 'В работе',
    TaskStatus.paused: 'На паузе',
    TaskStatus.completed: 'Завершенные',
  };
  TaskStatus get _selectedStatus => _selection.status;
  set _selectedStatus(TaskStatus value) {
    if (_selection.status == value) return;
    _selection.status = value;
    _selection.notifyListeners();
  }

  @override
  void initState() {
    super.initState();
    _selection =
        _selectionCache.putIfAbsent(widget.employeeId, () => _TaskSelectionState());
    _selection.addListener(_onSelectionChanged);
  }

  void _onSelectionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _selection.removeListener(_onSelectionChanged);
    _chatController.dispose();
    super.dispose();
  }

  /// Aggregated setup duration across all tasks belonging to the same order and
  /// stage. This sums up all overlapping periods between 'setup_start' and
  /// 'setup_done' across the current task and any cloned tasks (separate
  /// executors) for this stage. Without this aggregation the timer may
  /// display seemingly random values when multiple users participate.
  Duration _setupElapsedAggAll(TaskModel task) {
    final tp = context.read<TaskProvider>();
    // find all tasks with the same order and stage
    final related = tp.tasks
        .where((t) =>
            t.orderId == task.orderId &&
            t.stageId == task.stageId &&
            t.comments.isNotEmpty)
        .toList();

    // collect all setup start/done comments across related tasks
    final List<TaskComment> events = [];
    for (final t in related) {
      for (final c in t.comments) {
        if (c.type == 'setup_start' || c.type == 'setup_done') {
          events.add(c);
        }
      }
    }
    if (events.isEmpty) return Duration.zero;

    // sort by timestamp
    events.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    int active = 0;
    int? activeStart;
    int totalMs = 0;

    int normTs(int ts) {
      // normalise seconds to milliseconds if necessary
      if (ts < 2000000000000) return ts * 1000;
      return ts;
    }

    for (final e in events) {
      if (e.type == 'setup_start') {
        if (active == 0) {
          activeStart = normTs(e.timestamp);
        }
        active++;
      } else if (e.type == 'setup_done') {
        if (active > 0 && activeStart != null) {
          final end = normTs(e.timestamp);
          if (end > activeStart) {
            totalMs += end - activeStart;
          }
          activeStart = null;
        }
        if (active > 0) active--;
      }
    }

    if (active > 0 && activeStart != null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now > activeStart) {
        totalMs += now - activeStart;
      }
    }
    return Duration(milliseconds: totalMs);
  }

  /// Helper to format a timestamp (milliseconds since epoch) into a
  /// readable "dd.MM HH:mm:ss" string. Falls back gracefully if value is null.
  String _formatTimestamp(int? ts) {
    if (ts == null) return '';
    try {
      DateTime dt;
      // normalise seconds to milliseconds if necessary
      if (ts < 2000000000000) {
        dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
      } else {
        dt = DateTime.fromMillisecondsSinceEpoch(ts);
      }
      final d = dt;
      String two(int n) => n.toString().padLeft(2, '0');
      return '${two(d.day)}.${two(d.month)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
    } catch (_) {
      return '';
    }
  }

  String _employeeDisplayName(PersonnelProvider personnel, String userId) {
    if (userId.isEmpty) return '';
    try {
      final emp = personnel.employees.firstWhere((e) => e.id == userId);
      final full = '${emp.firstName} ${emp.lastName}'.trim();
      return full.isNotEmpty ? full : userId;
    } catch (_) {
      return userId;
    }
  }

  OrderModel? _orderById(String orderId) {
    try {
      return context.read<OrdersProvider>().orders
          .firstWhere((o) => o.id == orderId);
    } catch (_) {
      return null;
    }
  }

  List<String> _stageGroupMembers(String orderId, String stageId) {
    final order = _orderById(orderId);
    final templateId = order?.stageTemplateId;
    if (order == null || templateId == null || templateId.isEmpty) {
      return [stageId];
    }

    final templateProvider =
        Provider.of<TemplateProvider?>(context, listen: false);
    final templates = templateProvider?.templates ?? const [];
    for (final tpl in templates) {
      if (tpl.id != templateId) continue;
      for (final stage in tpl.stages) {
        if (stage.allStageIds.contains(stageId)) {
          final ids = [...stage.allStageIds]..sort();
          return ids;
        }
      }
    }

    return [stageId];
  }

  String _stageGroupKey(String orderId, String stageId) =>
      _stageGroupMembers(orderId, stageId).join('|');

  bool _isStageGroupLocked(TaskProvider provider, TaskModel task) {
    final groupMembers = _stageGroupMembers(task.orderId, task.stageId);
    // Блокируем только альтернативные группы (2+ различных этапа).
    final hasAlternatives = groupMembers.toSet().length > 1;
    if (!hasAlternatives) return false;

    final related = provider.tasks.where((t) =>
        t.orderId == task.orderId && groupMembers.contains(t.stageId));

    final anyActive = related.any(
        (t) => t.id != task.id && t.status == TaskStatus.inProgress);
    final anyDone =
        related.any((t) => t.id != task.id && t.status == TaskStatus.completed);

    if (task.status == TaskStatus.completed) return false;
    if (task.status == TaskStatus.inProgress) return anyDone;

    return anyActive || anyDone;
  }

  String _formatQuantityDisplay(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '0';
    final numeric = RegExp(r'^[0-9]+([.,][0-9]+)?$');
    if (!numeric.hasMatch(trimmed)) return trimmed;
    final normalised = trimmed.replaceAll(',', '.');
    final value = double.tryParse(normalised);
    if (value == null) return trimmed;
    if ((value - value.round()).abs() < 0.0001) {
      return '${value.round()} шт.';
    }
    return '${value.toStringAsFixed(2)} шт.';
  }

  String _describeComment(TaskComment comment) {
    switch (comment.type) {
      case 'start':
        return 'Начал(а) этап';
      case 'pause':
        return comment.text.isEmpty ? 'Пауза' : 'Пауза: ${comment.text}';
      case 'resume':
        return 'Возобновил(а) этап';
      case 'user_done':
        return 'Завершил(а) этап';
      case 'problem':
        return comment.text.isEmpty
            ? 'Сообщил(а) о проблеме'
            : 'Проблема: ${comment.text}';
      case 'setup_start':
        return 'Начал(а) наладку';
      case 'setup_done':
        return 'Завершил(а) наладку';
      case 'quantity_done':
        return 'Выполнил(а): ${_formatQuantityDisplay(comment.text)}';
      case 'quantity_team_total':
        return 'Команда выполнила: ${_formatQuantityDisplay(comment.text)}';
      case 'quantity_share':
        return 'Доля участника: ${_formatQuantityDisplay(comment.text)}';
      case 'finish_note':
        return comment.text.isEmpty
            ? 'Комментарий к завершению'
            : 'Комментарий к завершению: ${comment.text}';
      case 'joined':
        return 'Присоединился(лась) к этапу';
      case 'exec_mode':
      case 'exec_mode_stage':
        final parsed = _parseExecutionModeLabel(comment.text);
        if (parsed == ExecutionMode.separate) {
          return 'Режим: отдельный исполнитель';
        }
        return 'Режим: одиночная или совместная работа';
      case 'shift_pause':
        return comment.text.isNotEmpty
            ? comment.text
            : 'Пересмена: этап приостановлен';
      case 'shift_resume':
        return comment.text.isNotEmpty
            ? comment.text
            : 'Пересмена: работа возобновлена';
      default:
        return comment.text;
    }
  }

  /// Handles joining an already started task. Presents a modal to choose between
  /// separate execution (individual performer) or helper (joint). If the user
  /// chooses separate, a 'start' comment is written immediately to reflect
  /// that the performer has begun. Helpers get a simple 'joined' comment.
  Future<void> _joinTask(
      TaskModel task, TaskProvider provider, String userId) async {
    final alreadyAssigned = task.assignees.contains(userId);
    ExecutionMode? stageMode = _stageExecutionMode(task);
    final personnel = context.read<PersonnelProvider>();
    final stage = personnel.workplaces.firstWhere(
      (w) => w.id == task.stageId,
      orElse: () =>
          WorkplaceModel(id: task.stageId, name: task.stageId, positionIds: const []),
    );
    final defaultMode = _workplaceDefaultMode(stage);
    final bool isOwner = task.assignees.isNotEmpty && task.assignees.first == userId;

    final resolvedStageMode = stageMode ?? defaultMode;

    if (resolvedStageMode == ExecutionMode.joint &&
        task.assignees.isNotEmpty &&
        !isOwner) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Добавлять помощников может только основной исполнитель.')));
      }
      return;
    }

    if (stageMode == null) {
      stageMode = defaultMode;
      await provider.addComment(
        taskId: task.id,
        type: 'exec_mode_stage',
        text: _executionModeCode(stageMode),
        userId: userId,
      );
    }

    if (!alreadyAssigned) {
      final newAssignees = List<String>.from(task.assignees);
      newAssignees.add(userId);
      await provider.updateAssignees(task.id, newAssignees);
    }

    if (stageMode != null &&
        _needsExecModeRecord(task, userId, stageMode)) {
      await provider.addComment(
        taskId: task.id,
        type: 'exec_mode',
        text: _executionModeCode(stageMode),
        userId: userId,
      );
    }

    if (stageMode == ExecutionMode.joint) {
      // helper: note the join but do not mark as started
      await provider.addCommentAutoUser(
        taskId: task.id,
        type: 'joined',
        text: 'Присоединился(лась) к этапу',
        userIdOverride: userId,
      );
    } else {
      // separate performer immediately starts; write a 'start' comment
      await provider.addCommentAutoUser(
        taskId: task.id,
        type: 'start',
        text: 'Начал(а) этап',
        userIdOverride: userId,
      );
      await provider.recordTimeEvent(
        task: task,
        type: TaskTimeType.production,
        initiatedBy: userId,
        subjectUserId: userId,
        workplaceId: task.stageId,
        participantsSnapshot: _participantsSnapshot(task, userId),
        executionMode: _executionModeCode(stageMode),
      );
    }
  }

  void _persistWorkplace(String? id) {
    final ps = PageStorage.of(context);
    if (ps != null) ps.writeState(context, id, identifier: _widKey);
  }

  void _persistTask(String? id) {
    final ps = PageStorage.of(context);
    if (ps != null) ps.writeState(context, id, identifier: _tidKey);
  }

  TaskStatus _sectionForTask(TaskModel task) {
    if (task.status == TaskStatus.problem) {
      return TaskStatus.inProgress;
    }
    if (_statusLabels.containsKey(task.status)) {
      return task.status;
    }
    return TaskStatus.waiting;
  }

  String? _resolveTemplateName(
      String? templateId, List<TemplateModel> templates) {
    if (templateId == null || templateId.isEmpty) return null;
    for (final tpl in templates) {
      if (tpl.id == templateId) return tpl.name;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final personnel = context.watch<PersonnelProvider>();

    // Restore saved workplace/task for this employee from PageStorage
    final ps = PageStorage.of(context);
    final String? savedWid =
        ps?.readState(context, identifier: _widKey) as String?;
    final String? savedTid =
        ps?.readState(context, identifier: _tidKey) as String?;

    final ordersProvider = context.watch<OrdersProvider>();
    final taskProvider = context.watch<TaskProvider>();
    final templateProvider = context.watch<TemplateProvider>();
    final queue = context.watch<ProductionQueueProvider>();

    final orderIds = ordersProvider.orders.map((o) => o.id).toList(growable: false);

    final media = MediaQuery.of(context);
    final bool isTablet =
        media.size.shortestSide >= 600 && media.size.shortestSide < 1100;
    final bool isCompactTablet = isTablet && media.size.shortestSide <= 850;
    final bool isTablet1280x800 = isTablet &&
        ((media.size.width == 1280 && media.size.height == 800) ||
            (media.size.width == 800 && media.size.height == 1280));
    final bool isTablet1000x700 = isTablet &&
        ((media.size.width == 1000 && media.size.height == 700) ||
            (media.size.width == 700 && media.size.height == 1000));

    // Для компактных экранов 1280x800 дополнительно уменьшаем масштаб,
    // чтобы панели «Список заданий», «Рабочее место», «Управление
    // заданием» и «Детали производственного задания» помещались без
    // горизонтальной прокрутки. Более крупные экраны по-прежнему
    // получают лёгкое увеличение.
    final double layoutScale = isTablet1280x800
        ? 0.78 // планшеты 1280x800 — уменьшаем элементы под макет
        : (isTablet1000x700
            ? 0.72 // планшеты 1000x700 — уменьшаем элементы под макет
            : (isCompactTablet
                ? 0.88 // компактные планшеты — ещё аккуратнее базового масштаба
                : (isTablet
                    ? 1.0 // обычные планшеты — без увеличения
                    : 1.08))); // десктопы/веб — умеренное увеличение

    // Поддерживаем читаемость текста, но без лишнего укрупнения на
    // маленьких планшетах.
    final double textScaleFactor = isTablet1280x800
        ? media.textScaleFactor * 0.95
        : (isTablet1000x700
            ? media.textScaleFactor * 0.9
            : math.max(
                media.textScaleFactor,
                isCompactTablet
                    ? 1.0
                    : (isTablet
                        ? 1.05
                        : 1.12),
              ));

    final double scale = layoutScale;

    double scaled(double value) => value * layoutScale;
    final double compactTightness = isTablet1280x800
        ? 0.8
        : (isTablet1000x700
            ? 0.72
            : (isCompactTablet
                ? 0.9
                : 1.0));
    final double outerPadding = scaled(10 * compactTightness);
    final double columnGap = scaled(isCompactTablet ? 8 : 10);
    final double cardPadding = scaled(widget.compactList
        ? 6
        : (isCompactTablet
            ? 10
            : 12));
    final double cardRadius = scaled(12);
    final double sectionSpacing =
        scaled(widget.compactList ? 6 : (isCompactTablet ? 8 : 10));
    final double smallSpacing = scaled(4);
    final double largeSpacing =
        scaled(widget.compactList ? 10 : (isCompactTablet ? 14 : 18));
    final double chipSpacing = scaled(isCompactTablet ? 4 : 6);

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

    final filteredWorkplaces = personnel.workplaces
        .where(
            (w) => w.positionIds.any((p) => employee.positionIds.contains(p)))
        .toList();
    final workplaces = filteredWorkplaces.isEmpty
        ? personnel.workplaces
        : filteredWorkplaces;

    if (_selectedWorkplaceId == null && workplaces.isNotEmpty) {
      _selection.workplaceId = savedWid ?? _selectedWorkplaceId;
      _selection.workplaceId = _selectedWorkplaceId ?? workplaces.first.id;
      _persistWorkplace(_selectedWorkplaceId);
      _selection.notifyListeners();
    }

    OrderModel? findOrder(String id) {
      // Try to find by order id first
      for (final o in ordersProvider.orders) {
        if (o.id == id) return o;
      }
      // Some tasks may store assignmentId instead of orderId; try to match assignmentId
      for (final o in ordersProvider.orders) {
        if (o.assignmentId != null && o.assignmentId == id) return o;
      }
      return null;
    }

    final stageGroupByOrder = <String, Map<String, String>>{};
    for (final order in ordersProvider.orders) {
      final map = _stageGroupMapForOrder(order, templateProvider);
      if (map.isNotEmpty) {
        stageGroupByOrder[order.id] = map;
      }
    }

    String taskGroupKey(TaskModel task) {
      final lookup = stageGroupByOrder[task.orderId];
      final groupKey = lookup?[task.stageId] ?? task.stageId;
      return '${task.orderId}::$groupKey';
    }

    final tasksByGroup = <String, List<TaskModel>>{};
    for (final task in taskProvider.tasks) {
      final key = taskGroupKey(task);
      tasksByGroup.putIfAbsent(key, () => []).add(task);
    }

    final tasksForWorkplace = taskProvider.tasks
        .where((t) => t.stageId == _selectedWorkplaceId)
        .where((task) {
          final groupKey = taskGroupKey(task);
          final groupTasks = tasksByGroup[groupKey] ?? const <TaskModel>[];
          final groupHasActive =
              groupTasks.any((t) => t.status != TaskStatus.waiting);
          if (groupHasActive && task.status == TaskStatus.waiting) {
            return false;
          }
          return true;
        })
        .toList();

    if (_selectedTask == null && savedTid != null) {
      try {
        _selectedTask = tasksForWorkplace.firstWhere((t) => t.id == savedTid);
        _selectedStatus = _sectionForTask(_selectedTask!);
      } catch (_) {}
    } else if (_selectedTask != null &&
        !tasksForWorkplace.any((t) => t.id == _selectedTask!.id)) {
      _selectedTask = null;
      _persistTask(null);
    }

    if (_selectedTask != null) {
      final desiredSection = _sectionForTask(_selectedTask!);
      if (desiredSection != _selectedStatus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() {
            _selectedStatus = desiredSection;
          });
        });
      }
    }

    final queueGroupId = _selectedWorkplaceId?.trim().isNotEmpty == true
        ? _selectedWorkplaceId!
        : '';
    final stageTasksAll = _selectedWorkplaceId == null
        ? const <TaskModel>[]
        : taskProvider.tasks.where((t) => t.stageId == _selectedWorkplaceId).toList();
    final stageOrderIds =
        stageTasksAll.map((task) => task.orderId).toSet().toList();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      queue.syncOrders(
        _selectedWorkplaceId == null ? orderIds : stageOrderIds,
        groupId: queueGroupId,
      );
    });

    final sectionedTasks = tasksForWorkplace
        .where((t) => _sectionForTask(t) == _selectedStatus)
        .toList();
    sectionedTasks.sort((a, b) =>
        queue
            .priorityOf(a.orderId, groupId: queueGroupId)
            .compareTo(queue.priorityOf(b.orderId, groupId: queueGroupId)));
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

    Widget buildLeftPanel({required bool scrollable}) {
      final String workplaceLabel = _selectedWorkplaceId == null
          ? ''
          : 'Задания для рабочего места: '
              '${workplaces.firstWhere(
                (w) => w.id == _selectedWorkplaceId,
                orElse: () => WorkplaceModel(
                  id: '',
                  name: '',
                  positionIds: const [],
                ),
              ).name}';

      Widget buildWorkplaceSelector() {
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: scaled(isCompactTablet ? 220 : 260)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '🏷️ Рабочее место',
                style: TextStyle(
                  fontSize: scaled(12),
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: scaled(4)),
              DropdownButton<String>(
                value: _selectedWorkplaceId,
                isDense: true,
                isExpanded: true,
                style: TextStyle(fontSize: scaled(12.5), color: Colors.black87),
                itemHeight: math.max(
                  scaled(48),
                  kMinInteractiveDimension,
                ),
                items: [
                  for (final w in workplaces)
                    DropdownMenuItem(
                      value: w.id,
                      child: Text(
                        w.name,
                        style: TextStyle(fontSize: scaled(12.5)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                selectedItemBuilder: (context) => [
                  for (final w in workplaces)
                    Text(
                      w.name,
                      style: TextStyle(fontSize: scaled(12.5), color: Colors.black87),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
                onChanged: (val) {
                  setState(() {
                    _selectedWorkplaceId = val;
                    _persistWorkplace(val);
                    _selectedTask = null;
                  });
                },
              ),
            ],
          ),
        );
      }

      Widget content = Column(
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
                      '🗂️ Список заданий',
                      style: TextStyle(
                        fontSize: scaled(widget.compactList ? 14 : 15),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: smallSpacing * 0.5),
                    Text(
                      workplaceLabel,
                      style: TextStyle(
                        color: Colors.grey[700],
                        fontSize: scaled(12),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: scaled(12)),
              buildWorkplaceSelector(),
            ],
          ),
          SizedBox(height: sectionSpacing * 0.6),
          Wrap(
            spacing: chipSpacing,
            runSpacing: chipSpacing,
            children: [
              for (final entry in _statusLabels.entries)
                ChoiceChip(
                  label: Text(
                    entry.value,
                    style: TextStyle(fontSize: scaled(10.5), fontWeight: FontWeight.w600),
                  ),
                  selected: _selectedStatus == entry.key,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: isTablet
                      ? const VisualDensity(horizontal: -2, vertical: -2)
                      : const VisualDensity(horizontal: -1, vertical: -1),
                  labelPadding: EdgeInsets.symmetric(
                    horizontal: scaled(5),
                    vertical: scaled(2.5),
                  ),
                  onSelected: (selected) {
                    if (!selected) return;
                    setState(() {
                      _selectedStatus = entry.key;
                      if (_selectedTask != null &&
                          _sectionForTask(_selectedTask!) != _selectedStatus) {
                        _selectedTask = null;
                        _persistTask(null);
                      }
                    });
                  },
                ),
            ],
          ),
          SizedBox(height: sectionSpacing),
          if (sectionedTasks.isEmpty)
            const Center(
              child: Text(
                'Нет заданий в этой категории',
                textAlign: TextAlign.center,
              ),
            )
          else
            ListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (final task in sectionedTasks)
                  _TaskCard(
                    task: task,
                    order: findOrder(task.orderId),
                    readyForStage: task.status == TaskStatus.waiting &&
                        _isFirstPendingStage(
                          taskProvider,
                          personnel,
                          task,
                          groupResolver: _stageGroupKey,
                        ),
                    selected: _selectedTask?.id == task.id,
                    scale: scale,
                    compact: isCompactTablet || widget.compactList,
                    showStageHint: task.status == TaskStatus.waiting,
                    onTap: () {
                      _persistTask(task.id);
                      setState(() {
                        _selectedTask = task;
                        _selectedStatus = _sectionForTask(task);
                      });
                      DefaultTabController.of(context)?.animateTo(1);
                    },
                  ),
              ],
            ),
        ],
      );

      if (!scrollable) return content;

      return LayoutBuilder(
        builder: (context, constraints) {
          final double minHeight =
              constraints.hasBoundedHeight ? constraints.maxHeight : 0;

          return SingleChildScrollView(
            padding: EdgeInsets.zero,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minHeight),
              child: content,
            ),
          );
        },
      );
    }

    Widget buildSummaryPanel() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (currentTask != null && selectedWorkplace != null && selectedOrder != null)
            _buildTaskHeaderPanel(
              selectedOrder,
              selectedWorkplace,
              currentTask,
              scale,
            ),
          if (currentTask != null) SizedBox(height: scaled(6)),
          if (currentTask != null) _buildTimerStatusPanel(currentTask, scale),
          if (currentTask != null) SizedBox(height: scaled(6)),
          if (currentTask != null) _buildHistoryPanel(currentTask, scale),
          if (currentTask != null) SizedBox(height: scaled(6)),
          if (currentTask != null) _buildPerformersPanel(currentTask, scale, isTablet),
          if (currentTask != null && selectedOrder != null)
            SizedBox(height: scaled(6)),
          if (currentTask != null && selectedOrder != null)
            _buildResultPanel(selectedOrder, currentTask, scale),
        ],
      );
    }

    Widget buildDetailsPanel() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (currentTask != null && selectedWorkplace != null && selectedOrder != null)
            _buildDetailsPanel(
              selectedOrder,
              selectedWorkplace,
              templateProvider.templates,
              scale,
            ),
          if (currentTask != null && selectedWorkplace != null)
            SizedBox(height: scaled(6)),
          if (currentTask != null && selectedWorkplace != null)
            _buildControlPanel(
              currentTask,
              selectedWorkplace,
              taskProvider,
              scale,
              isTablet,
            ),
          if (currentTask != null) SizedBox(height: scaled(6)),
          if (currentTask != null) _buildCommentsPanel(currentTask, scale),
        ],
      );
    }

    Widget buildRightPanel({required bool scrollable}) {
      final Widget content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          buildSummaryPanel(),
          if (currentTask != null) SizedBox(height: scaled(6)),
          buildDetailsPanel(),
        ],
      );

      if (!scrollable) return content;

      return SingleChildScrollView(
        child: content,
      );
    }

    final PreferredSizeWidget? appBar = widget.showListOnly
        ? null
        : AppBar(
            title: const SizedBox.shrink(),
            toolbarHeight: scaled(44),
            titleSpacing: 0,
            automaticallyImplyLeading: false,
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            elevation: 0.5,
          );

    final scaffold = Scaffold(
      key: PageStorageKey('TasksScreen-${widget.employeeId}'),
      backgroundColor: Colors.grey[100],
      appBar: appBar,
      body: SafeArea(
        top: appBar == null,
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final bool isNarrow = constraints.maxWidth < 1000;
            final bool showList = !widget.hideListPanel;
            final bool showDetails = !widget.showListOnly;

            final Widget leftPanel = Container(
              padding: EdgeInsets.all(cardPadding),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(cardRadius),
                border: Border.all(color: const Color(0xFFE6E7EC)),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 8,
                    offset: Offset(0, 3),
                  )
                ],
              ),
              child: buildLeftPanel(scrollable: true),
            );

            final Widget rightPanel = buildRightPanel(scrollable: !isNarrow);

            if (widget.showListOnly && showList) {
              return SingleChildScrollView(
                padding: EdgeInsets.all(outerPadding),
                child: leftPanel,
              );
            }

            if (showList && showDetails) {
              if (!isNarrow) {
                return Padding(
                  padding: EdgeInsets.all(outerPadding),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 1,
                        child: leftPanel,
                      ),
                      SizedBox(width: columnGap),
                      Expanded(
                        flex: 2,
                        child: rightPanel,
                      ),
                    ],
                  ),
                );
              }

              return SingleChildScrollView(
                padding: EdgeInsets.all(outerPadding),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    leftPanel,
                    SizedBox(height: scaled(12)),
                    rightPanel,
                  ],
                ),
              );
            }

            if (showList) {
              return SingleChildScrollView(
                padding: EdgeInsets.all(outerPadding),
                child: leftPanel,
              );
            }

            final Widget summaryPanel = buildSummaryPanel();
            final Widget detailsPanel = buildDetailsPanel();

            if (!isNarrow) {
              return SingleChildScrollView(
                padding: EdgeInsets.all(outerPadding),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 1,
                      child: summaryPanel,
                    ),
                    SizedBox(width: columnGap),
                    Expanded(
                      flex: 2,
                      child: detailsPanel,
                    ),
                  ],
                ),
              );
            }

            return SingleChildScrollView(
              padding: EdgeInsets.all(outerPadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  summaryPanel,
                  SizedBox(height: scaled(12)),
                  detailsPanel,
                ],
              ),
            );
          },
        ),
      ),
    );

    if (!isTablet) return scaffold;

    return MediaQuery(
      data: media.copyWith(
        textScaleFactor: media.textScaleFactor * textScaleFactor,
      ),
      child: Theme(
        data: Theme.of(context).copyWith(
          visualDensity: const VisualDensity(horizontal: -1, vertical: -1),
        ),
        child: scaffold,
      ),
    );
  }

  Widget _sectionCard(String title, Widget child, double scale) {
    double scaled(double value) => value * scale;
    return Container(
      padding: EdgeInsets.all(scaled(9)),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(scaled(10)),
        border: Border.all(color: const Color(0xFFE6E7EC)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: scaled(12.5),
            ),
          ),
          SizedBox(height: scaled(3)),
          child,
        ],
      ),
    );
  }

  Widget _buildTaskHeaderPanel(OrderModel order, WorkplaceModel stage,
      TaskModel task, double scale) {
    final personnel = context.read<PersonnelProvider>();
    final orderTitle = order.product.type.isNotEmpty
        ? order.product.type
        : orderDisplayId(order);
    final status = _statusText(task.status);
    final names = task.assignees
        .map((id) => _employeeDisplayName(personnel, id))
        .where((n) => n.isNotEmpty)
        .toList();
    final helpers = _helperIds(task)
        .map((id) => _employeeDisplayName(personnel, id))
        .where((n) => n.isNotEmpty)
        .toList();
    final executorLabel = names.isEmpty ? '—' : names.join(', ');
    final helperLabel = helpers.isEmpty ? '—' : helpers.join(', ');
    final workplaceLabel =
        stage.name.isNotEmpty ? stage.name : _workplaceName(personnel, stage.id);

    return _sectionCard(
      '📌 Задание',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(orderTitle,
              style: TextStyle(
                  fontSize: scale * 15, fontWeight: FontWeight.w600)),
          SizedBox(height: scale * 4),
          Text('Статус: $status',
              style: TextStyle(fontSize: scale * 12)),
          Text('Рабочее место: $workplaceLabel',
              style: TextStyle(fontSize: scale * 12)),
          Text('Исполнитель(и): $executorLabel',
              style: TextStyle(fontSize: scale * 12)),
          Text('Помощник(и): $helperLabel',
              style: TextStyle(fontSize: scale * 12)),
        ],
      ),
      scale,
    );
  }

  Widget _buildTimerStatusPanel(TaskModel task, double scale) {
    final String modeLabel = () {
      final open = _openEventForUser(task, widget.employeeId);
      if (open != null) return _timeTypeLabel(open.type);
      return task.status == TaskStatus.waiting ? 'Ожидание' : _statusText(task.status);
    }();
    return _sectionCard(
      '⏱️ Таймер и статус',
      StreamBuilder<DateTime>(
        stream: Stream<DateTime>.periodic(
            const Duration(seconds: 1), (_) => DateTime.now()),
        builder: (context, _) {
          final totals = _timeTotalsForUser(task, widget.employeeId);
          final total = totals.values.fold(Duration.zero, (a, b) => a + b);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Текущий режим: $modeLabel',
                  style: TextStyle(fontSize: scale * 12)),
              SizedBox(height: scale * 4),
              Text('Всего: ${_formatDuration(total)}',
                  style: TextStyle(fontSize: scale * 12)),
              SizedBox(height: scale * 4),
              Wrap(
                spacing: scale * 10,
                runSpacing: scale * 4,
                children: [
                  for (final type in TaskTimeType.values)
                    Text(
                      '${_timeTypeLabel(type)}: ${_formatDuration(totals[type] ?? Duration.zero)}',
                      style: TextStyle(fontSize: scale * 11.5),
                    ),
                ],
              ),
            ],
          );
        },
      ),
      scale,
    );
  }

  Widget _buildPerformersPanel(TaskModel task, double scale, bool isTablet) {
    final personnel = context.read<PersonnelProvider>();
    final allAssignees = task.assignees;
    final performerTiles = <Widget>[];
    for (final id in allAssignees) {
      final name = _employeeDisplayName(personnel, id);
      final state = _userRunState(task, id);
      String stateLabel = 'Ожидание';
      switch (state) {
        case UserRunState.active:
          stateLabel = 'В работе';
          break;
        case UserRunState.paused:
          stateLabel = 'Пауза';
          break;
        case UserRunState.problem:
          stateLabel = 'Проблема';
          break;
        case UserRunState.finished:
          stateLabel = 'Завершил(а)';
          break;
        case UserRunState.idle:
          stateLabel = 'Ожидание';
          break;
      }
      performerTiles.add(
        Text('$name — $stateLabel', style: TextStyle(fontSize: scale * 12.5)),
      );
    }

    return _sectionCard(
      '👥 Исполнители',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AssignedEmployeesRow(
              task: task,
              scale: scale,
              compact: isTablet,
              currentUserId: widget.employeeId),
          SizedBox(height: scale * 6),
          ...performerTiles,
        ],
      ),
      scale,
    );
  }

  int _parseQuantity(String text) {
    final match = RegExp(r'(\d+)').firstMatch(text);
    if (match == null) return 0;
    return int.tryParse(match.group(1) ?? '') ?? 0;
  }

  int _sumQuantities(TaskModel task) {
    int total = 0;
    for (final comment in task.comments) {
      if (comment.type == 'quantity_done') {
        total += _parseQuantity(comment.text);
      }
    }
    return total;
  }

  String _latestQuantityLabel(TaskModel task) {
    final items = task.comments
        .where((c) => c.type == 'quantity_done')
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (items.isEmpty) return '—';
    return items.last.text;
  }

  Widget _buildResultPanel(OrderModel order, TaskModel task, double scale) {
    final totalQty = _sumQuantities(task);
    final lastQty = _latestQuantityLabel(task);
    return _sectionCard(
      '📊 Производственный результат',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Фактическое количество (заказ): '
              '${order.actualQty?.toStringAsFixed(0) ?? '—'}',
              style: TextStyle(fontSize: scale * 12)),
          Text('Суммарно по исполнителям: ${totalQty > 0 ? totalQty : '—'}',
              style: TextStyle(fontSize: scale * 12)),
          Text('Последняя запись: $lastQty',
              style: TextStyle(fontSize: scale * 12)),
        ],
      ),
      scale,
    );
  }

  Widget _buildCommentsPanel(TaskModel task, double scale) {
    final isAssignee = task.assignees.contains(widget.employeeId) ||
        task.assignees.isEmpty;
    final personnel = context.watch<PersonnelProvider>();
    final taskProvider = context.watch<TaskProvider>();
    final aggregated = _collectOrderComments(taskProvider, task);

    Widget commentList() {
      if (aggregated.isEmpty) {
        return const Text('Нет комментариев',
            style: TextStyle(color: Colors.grey));
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final entry in aggregated)
            Padding(
              padding: EdgeInsets.symmetric(vertical: scale * 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Builder(builder: (_) {
                    IconData icon = Icons.info_outline;
                    Color color = Colors.blueGrey;
                    final c = entry.comment;
                    switch (c.type) {
                      case 'problem':
                        icon = Icons.error_outline;
                        color = Colors.redAccent;
                        break;
                      case 'pause':
                        icon = Icons.pause_circle_outline;
                        color = Colors.orange;
                        break;
                      case 'user_done':
                      case 'quantity_done':
                        icon = Icons.check_circle_outline;
                        color = Colors.green;
                        break;
                      case 'setup_start':
                      case 'setup_done':
                        icon = Icons.build_outlined;
                        color = Colors.indigo;
                        break;
                      case 'joined':
                        icon = Icons.group_add_outlined;
                        color = Colors.teal;
                        break;
                      case 'exec_mode':
                      case 'exec_mode_stage':
                        icon = Icons.settings_input_component_outlined;
                        color = Colors.purple;
                        break;
                      case 'shift_pause':
                        icon = Icons.pause_circle_outline;
                        color = Colors.deepPurple;
                        break;
                      case 'shift_resume':
                        icon = Icons.play_circle_outline;
                        color = Colors.deepPurple;
                        break;
                      default:
                        icon = Icons.info_outline;
                        color = Colors.blueGrey;
                    }
                    return Icon(icon, size: 18, color: color);
                  }),
                  SizedBox(width: scale * 3),
                  Expanded(
                    child: Builder(
                      builder: (_) {
                        final headerParts = <String>[];
                        final c = entry.comment;
                        final ts = _formatTimestamp(c.timestamp);
                        if (ts.isNotEmpty) headerParts.add(ts);
                        final author = _employeeDisplayName(personnel, c.userId);
                        if (author.isNotEmpty) {
                          headerParts.add(author);
                        }
                        final stageName =
                            _workplaceName(personnel, entry.stageId);
                        if (stageName.isNotEmpty) {
                          headerParts.add('Этап: $stageName');
                        }
                        final header = headerParts.join(' • ');
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (header.isNotEmpty)
                              Text(
                                header,
                                style: const TextStyle(
                                    fontSize: 9.5, color: Colors.grey),
                              ),
                            Text(
                              _describeComment(entry.comment),
                              style: const TextStyle(fontSize: 12.5),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    }

    final double inputRadius = scale * 12;
    return _sectionCard(
      '💬 Комментарии',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          commentList(),
          SizedBox(height: scale * 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _chatController,
                  maxLines: 1,
                  readOnly: !isAssignee,
                  decoration: InputDecoration(
                    hintText: 'Написать комментарий…',
                    isDense: true,
                    filled: true,
                    fillColor: const Color(0xFFF4F5F7),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: scale * 10,
                      vertical: scale * 8,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(inputRadius),
                      borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(inputRadius),
                      borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(inputRadius),
                      borderSide: const BorderSide(color: Color(0xFF111827)),
                    ),
                  ),
                ),
              ),
              SizedBox(width: scale * 8),
              InkResponse(
                onTap: isAssignee
                    ? () async {
                        final txt = _chatController.text.trim();
                        if (txt.isEmpty) return;
                        await context.read<TaskProvider>().addCommentAutoUser(
                            taskId: task.id,
                            type: 'msg',
                            text: txt,
                            userIdOverride: widget.employeeId);
                        _chatController.clear();
                      }
                    : null,
                child: Container(
                  width: scale * 40,
                  height: scale * 40,
                  decoration: BoxDecoration(
                    color: isAssignee
                        ? const Color(0xFF111827)
                        : const Color(0xFF9CA3AF),
                    borderRadius: BorderRadius.circular(scale * 12),
                  ),
                  child: const Icon(Icons.send, color: Colors.white, size: 18),
                ),
              ),
            ],
          ),
        ],
      ),
      scale,
    );
  }

  Widget _buildHistoryPanel(TaskModel task, double scale) {
    final personnel = context.read<PersonnelProvider>();
    final events = _taskTimeEvents(task);
    if (events.isEmpty) {
      return _sectionCard(
        '🧾 История событий',
        const Text('История пока пуста'),
        scale,
      );
    }
    return _sectionCard(
      '🧾 История событий',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final event in events)
            Padding(
              padding: EdgeInsets.only(bottom: scale * 4),
              child: Text(
                '${_formatTimestamp(event.startTime.millisecondsSinceEpoch)}'
                ' — ${event.endTime != null ? _formatTimestamp(event.endTime!.millisecondsSinceEpoch) : '…'}'
                ' · ${_timeTypeLabel(event.type)}'
                ' · ${_employeeDisplayName(personnel, event.subjectUserId)}',
                style: TextStyle(fontSize: scale * 12.5),
              ),
            ),
        ],
      ),
      scale,
    );
  }

  Widget _buildDetailsPanel(OrderModel order, WorkplaceModel stage,
      List<TemplateModel> templates, double scale) {
    final product = order.product;
    final templateLabel =
        (order.stageTemplateId != null && order.stageTemplateId!.isNotEmpty)
            ? (_resolveTemplateName(order.stageTemplateId, templates) ??
                (templates.isEmpty ? 'загрузка...' : 'не найден'))
            : null;
    double scaled(double value) => value * scale;
    final double panelPadding = scaled(8);
    final double radius = scaled(10);
    final double mediumSpacing = scaled(6);
    final double smallSpacing = scaled(2);
    final double infoSpacing = scaled(2);
    final double infoItemWidth = scaled(210);
    final orderNumber = orderDisplayId(order);
    final dateFormat = DateFormat('dd.MM.yyyy');

    String formatDate(DateTime? date) {
      if (date == null) return '—';
      try {
        return dateFormat.format(date);
      } catch (_) {
        return date.toIso8601String();
      }
    }

    String formatNum(num? value, {String? unit}) {
      if (value == null) return '—';
      final doubleValue = value.toDouble();
      final bool isInt = (doubleValue - doubleValue.round()).abs() < 0.0001;
      final String formatted = isInt
          ? doubleValue.round().toString()
          : doubleValue.toStringAsFixed(2);
      if (unit == null) return formatted;
      final trimmed = unit.trim();
      return trimmed.isEmpty ? formatted : '$formatted $trimmed';
    }

    String formatQty(num? value) {
      if (value == null) return '—';
      final doubleValue = value.toDouble();
      final bool isInt = (doubleValue - doubleValue.round()).abs() < 0.0001;
      return isInt
          ? '${doubleValue.round()} шт.'
          : '${doubleValue.toStringAsFixed(2)} шт.';
    }

    String formatDimension(double value) {
      if (value <= 0) return '—';
      return formatNum(value, unit: 'мм');
    }

    String formatOptionalDouble(double? value, {String? unit}) {
      if (value == null) return '—';
      return formatNum(value, unit: unit);
    }

    Widget infoLine(String label, String value) {
      final display = value.isNotEmpty ? value : '—';
      return SizedBox(
        width: infoItemWidth,
        child: Padding(
          padding: EdgeInsets.only(bottom: infoSpacing),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$label: ',
                  style: TextStyle(
                    fontSize: scaled(11.5),
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF6B7280),
                  ),
                ),
                TextSpan(
                  text: display,
                  style: TextStyle(
                    fontSize: scaled(11.5),
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF111318),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    Widget infoMultiline(String label, String value) {
      final display = value.isNotEmpty ? value : '—';
      return SizedBox(
        width: double.infinity,
        child: Padding(
          padding: EdgeInsets.only(bottom: infoSpacing),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: scaled(11.5),
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF6B7280),
                ),
              ),
              SizedBox(height: scaled(2)),
              Text(
                display,
                style: TextStyle(
                  fontSize: scaled(11.5),
                  color: const Color(0xFF111318),
                ),
              ),
            ],
          ),
        ),
      );
    }

    Widget section(String title, List<Widget> content) {
      if (content.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: EdgeInsets.only(bottom: mediumSpacing),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: scaled(12),
                color: const Color(0xFF111827),
              ),
            ),
            SizedBox(height: smallSpacing),
            Wrap(
              spacing: scaled(12),
              runSpacing: scaled(2),
              children: content,
            ),
            SizedBox(height: smallSpacing),
            const Divider(height: 1, color: Color(0xFFE5E7EB)),
          ],
        ),
      );
    }

    String statusLabel(OrderModel o) {
      switch (o.statusEnum) {
        case OrderStatus.completed:
          return 'Завершён';
        case OrderStatus.inWork:
          return 'В работе';
        case OrderStatus.newOrder:
        default:
          return 'Новый';
      }
    }

    final List<Widget> generalSection = [];
    if (order.customer.isNotEmpty) {
      generalSection.add(infoLine('👤 Заказчик', order.customer));
    }
    if (order.manager.isNotEmpty) {
      generalSection.add(infoLine('🧑‍💼 Менеджер', order.manager));
    }
    generalSection.add(infoLine('📅 Дата заказа', formatDate(order.orderDate)));
    generalSection.add(infoLine('⏰ Срок', formatDate(order.dueDate)));
    generalSection.add(infoLine('📊 Статус', statusLabel(order)));
    generalSection.add(infoLine('🏭 Этап', stage.name));
    if (order.comments.isNotEmpty) {
      generalSection.add(infoMultiline('💬 Комментарии', order.comments));
    }
    generalSection
        .add(infoLine('📄 Договор', order.contractSigned ? 'Да' : 'Нет'));
    generalSection
        .add(infoLine('💳 Оплата', order.paymentDone ? 'Проведена' : 'Нет'));
    if (order.actualQty != null) {
      generalSection
          .add(infoLine('📦 Готово', formatQty(order.actualQty)));
    }
    if (templateLabel != null) {
      generalSection.add(infoLine('🧭 Шаблон этапов', templateLabel));
    }

    final List<Widget> productSection = [];
    if (product.type.isNotEmpty) {
      productSection.add(infoLine('Наименование', product.type));
    }
    productSection.add(infoLine('Тираж', formatQty(product.quantity)));
    if (product.parameters.isNotEmpty) {
      productSection.add(infoMultiline('Параметры', product.parameters));
    }
    if (product.width > 0) {
      productSection.add(infoLine('Ширина', formatDimension(product.width)));
    }
    if (product.height > 0) {
      productSection.add(infoLine('Высота', formatDimension(product.height)));
    }
    if (product.depth > 0) {
      productSection.add(infoLine('Глубина', formatDimension(product.depth)));
    }
    if (product.widthB != null) {
      productSection.add(infoLine(
          'Ширина B', formatOptionalDouble(product.widthB, unit: 'мм')));
    }
    if (product.blQuantity != null && product.blQuantity!.isNotEmpty) {
      productSection.add(infoLine('Количество', product.blQuantity!));
    }
    if (product.length != null) {
      productSection.add(
          infoLine('Длина L', formatOptionalDouble(product.length, unit: 'м')));
    }
    if (product.roll != null) {
      productSection.add(
          infoLine('Рулон', formatOptionalDouble(product.roll, unit: 'мм')));
    }
    if (product.leftover != null) {
      productSection.add(infoLine(
          'Остаток', formatOptionalDouble(product.leftover, unit: 'шт.')));
    }

    final material = order.material;
    final List<Widget> materialSection = [];
    if (material != null) {
      materialSection.add(infoLine('Наименование', material.name));
      if (material.format != null && material.format!.trim().isNotEmpty) {
        materialSection.add(infoLine('Формат', material.format!.trim()));
      }
      if (material.grammage != null && material.grammage!.trim().isNotEmpty) {
        materialSection.add(infoLine('Грамаж', material.grammage!.trim()));
      }
      materialSection.add(infoLine(
          'Количество',
          formatNum(material.quantity,
              unit: material.unit.isNotEmpty ? material.unit : null)));
      if (material.weight != null && material.weight! > 0) {
        materialSection
            .add(infoLine('Вес', formatNum(material.weight, unit: 'кг')));
      }
    }

    final List<Widget> equipmentSection = [];
    if (order.handle.isNotEmpty) {
      equipmentSection.add(infoLine('Ручки', order.handle));
    }
    if (order.cardboard.isNotEmpty) {
      equipmentSection.add(infoLine('Картон', order.cardboard));
    }
    if (order.additionalParams.isNotEmpty) {
      equipmentSection.add(
          infoMultiline('Доп. параметры', order.additionalParams.join(', ')));
    }
    if (order.makeready > 0) {
      equipmentSection.add(infoLine('Приладка', formatNum(order.makeready)));
    }
    if (order.val > 0) {
      equipmentSection.add(infoLine('Стоимость', formatNum(order.val)));
    }

    final List<Widget> formSection = [];
    formSection
        .add(infoLine('Тип формы', order.isOldForm ? 'Старая' : 'Новая'));
    if (order.formCode != null && order.formCode!.trim().isNotEmpty) {
      formSection.add(infoLine('Код формы', order.formCode!.trim()));
    }
    if (order.formSeries != null && order.formSeries!.trim().isNotEmpty) {
      formSection.add(infoLine('Серия', order.formSeries!.trim()));
    }
    if (order.newFormNo != null) {
      formSection.add(infoLine('Номер формы', order.newFormNo.toString()));
    }

    Widget formSectionWidget() {
      if (formSection.isEmpty) return const SizedBox.shrink();
      final double previewSize = scaled(88);
      final borderRadius = BorderRadius.circular(scaled(8));
      final boxDecoration = BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: borderRadius,
        color: Colors.grey.shade100,
      );
      return Padding(
        padding: EdgeInsets.only(bottom: mediumSpacing),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '🧷 Форма',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: scaled(12),
              ),
            ),
            SizedBox(height: smallSpacing),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: formSection,
                  ),
                ),
                SizedBox(width: scaled(12)),
                FutureBuilder<String?>(
                  future: _getFormImageFuture(order),
                  builder: (context, snapshot) {
                    final url = snapshot.data;
                    final bool waiting =
                        snapshot.connectionState == ConnectionState.waiting &&
                            !snapshot.hasData;
                    Widget child;
                    if (waiting) {
                      child = const Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      );
                    } else if (url == null || url.isEmpty) {
                      child = Center(
                        child: Text('Нет фото',
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: scaled(11),
                            )),
                      );
                    } else {
                      child = GestureDetector(
                        onTap: () => _openFormImage(url),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ClipRRect(
                              borderRadius: borderRadius,
                              child: Image.network(
                                url,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) =>
                                    Center(
                                  child: Icon(Icons.broken_image,
                                      color: Colors.red.shade300,
                                      size: scaled(28)),
                                ),
                              ),
                            ),
                            Positioned(
                              right: 6,
                              bottom: 6,
                              child: Container(
                                padding: EdgeInsets.all(scaled(4)),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius:
                                      BorderRadius.circular(scaled(12)),
                                ),
                                child: Icon(Icons.fullscreen,
                                    size: scaled(14), color: Colors.white),
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                    return Container(
                      width: previewSize,
                      height: previewSize,
                      decoration: boxDecoration,
                      child: child,
                    );
                  },
                ),
              ],
            ),
            SizedBox(height: smallSpacing),
            const Divider(height: 1, color: Color(0xFFE5E7EB)),
          ],
        ),
      );
    }

    final bool hasPdf = order.pdfUrl != null && order.pdfUrl!.isNotEmpty;

    return Container(
      padding: EdgeInsets.all(panelPadding),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: const Color(0xFFE6E7EC)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      orderNumber != '—' ? orderNumber : order.id,
                      style: TextStyle(
                        fontSize: scaled(16),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: smallSpacing),
                    const Text(
                      '📋 Детали производственного задания',
                      style: TextStyle(color: Color(0xFF6B7280)),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => setState(() {
                  _detailsExpanded = !_detailsExpanded;
                }),
                icon: Icon(
                    _detailsExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    color: Colors.black87),
                tooltip:
                    _detailsExpanded ? 'Свернуть детали' : 'Развернуть детали',
              ),
            ],
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(height: mediumSpacing),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (generalSection.isNotEmpty)
                      section('🧾 Основное', generalSection),
                    if (productSection.isNotEmpty)
                      section('📦 Продукт', productSection),
                    if (materialSection.isNotEmpty)
                      section('🧵 Материал', materialSection),
                    if (equipmentSection.isNotEmpty)
                      section('🧩 Комплектация', equipmentSection),
                    if (formSection.isNotEmpty) formSectionWidget(),
                    if (hasPdf)
                      section('📎 Файлы', [
                        SizedBox(
                          width: double.infinity,
                          child: Row(
                            children: [
                              const Icon(Icons.picture_as_pdf_outlined,
                                  size: 16, color: Colors.redAccent),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'PDF: ${order.pdfUrl!}',
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: scaled(13)),
                                ),
                              ),
                              TextButton(
                                onPressed: () async {
                                  final url = await getSignedUrl(order.pdfUrl!);
                                  if (!context.mounted) return;
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => PdfViewScreen(
                                          url: url, title: 'PDF заказа'),
                                    ),
                                  );
                                },
                                child: const Text('Открыть'),
                              ),
                            ],
                          ),
                        ),
                      ]),
                  ],
                ),
                SizedBox(height: mediumSpacing),
                _buildStageList(order, scale),
              ],
            ),
            crossFadeState: _detailsExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }

  /// Список этапов производства с иконками выполнено/ожидание.
  Widget _buildStageList(OrderModel order, double scale) {
    final taskProvider = context.read<TaskProvider>();
    final personnel = context.read<PersonnelProvider>();
    final ordersProvider = context.read<OrdersProvider>();
    final templates = context.read<TemplateProvider>();
    final tasksForOrder =
        taskProvider.tasks.where((t) => t.orderId == order.id).toList();

    double scaled(double value) => value * scale;
    final double chipGap = scaled(6);
    final double verticalSpacing = scaled(4);
    final double dotSize = scaled(6);
    final TextStyle stageTextStyle = TextStyle(fontSize: scaled(11.5));

    final taskStageIds = <String>{};
    for (final t in tasksForOrder) {
      taskStageIds.add(t.stageId);
    }
    if (taskStageIds.isEmpty) return const SizedBox.shrink();

    final sequence =
        taskProvider.stageSequenceForOrder(order.id) ?? const <String>[];

    final orderedGroupKeys = <String>[];
    final groupMembersByKey = <String, List<String>>{};
    final groupRepresentative = <String, String>{};

    String registerStage(String stageId) {
      final members = _stageGroupMembers(order.id, stageId);
      final key = members.join('|');
      groupMembersByKey.putIfAbsent(key, () => members);
      groupRepresentative.putIfAbsent(
        key,
        () => members.isNotEmpty ? members.first : stageId,
      );
      return key;
    }

    if (sequence.isNotEmpty) {
      for (final id in sequence) {
        final key = registerStage(id);
        if (!orderedGroupKeys.contains(key)) {
          orderedGroupKeys.add(key);
        }
      }
      for (final id in taskStageIds) {
        final key = registerStage(id);
        if (!orderedGroupKeys.contains(key)) {
          orderedGroupKeys.add(key);
        }
      }
    } else {
      for (final id in taskStageIds) {
        final key = registerStage(id);
        if (!orderedGroupKeys.contains(key)) {
          orderedGroupKeys.add(key);
        }
      }

      String labelForKey(String key) {
        final repId = groupRepresentative[key] ?? key.split('|').first;
        return _stageLabelForOrder(
                personnel, templates, ordersProvider, taskProvider, order.id, repId)
            .toLowerCase();
      }

      orderedGroupKeys.sort((a, b) => labelForKey(a).compareTo(labelForKey(b)));

      final repToKey = <String, String>{};
      for (final entry in groupRepresentative.entries) {
        repToKey[entry.value] = entry.key;
      }
      final repIds = orderedGroupKeys
          .map((key) => groupRepresentative[key] ?? key.split('|').first)
          .toList();
      _ensureFlexoOrdering(repIds, personnel);
      orderedGroupKeys
        ..clear()
        ..addAll(repIds.map((id) => repToKey[id] ?? id));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('🏁 Этапы производства',
            style:
                TextStyle(fontWeight: FontWeight.bold, fontSize: scaled(13))),
        SizedBox(height: verticalSpacing),
        ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final key in orderedGroupKeys)
                  Builder(
                    builder: (context) {
                      final groupIds =
                          groupMembersByKey[key] ?? key.split('|').toList();
                      final repId = groupRepresentative[key] ?? groupIds.first;
                      final stageTasks = tasksForOrder
                          .where((t) => groupIds.contains(t.stageId))
                          .toList();
                      final completed = stageTasks.isNotEmpty &&
                          stageTasks
                              .every((t) => t.status == TaskStatus.completed);
                      final label = _stageLabelForOrder(personnel, templates,
                          ordersProvider, taskProvider, order.id, repId);
                      return Container(
                        margin: EdgeInsets.only(right: chipGap),
                        padding: EdgeInsets.symmetric(
                          horizontal: scaled(8),
                          vertical: scaled(4),
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(scaled(16)),
                          border: Border.all(
                            color: completed
                                ? Colors.green.shade200
                                : Colors.orange.shade200,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: dotSize,
                              height: dotSize,
                              decoration: BoxDecoration(
                                color: completed ? Colors.green : Colors.orange,
                                shape: BoxShape.circle,
                              ),
                            ),
                            SizedBox(width: scaled(4)),
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: scaled(180),
                              ),
                              child: Text(
                                label,
                                style: stageTextStyle,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  bool _allPerformersFinished(TaskModel task) {
    if (task.assignees.isEmpty) return false;
    final mode = _stageExecutionMode(task);
    if (mode == ExecutionMode.joint || mode == ExecutionMode.solo) {
      final ownerId = task.assignees.first;
      return _userRunState(task, ownerId) == UserRunState.finished;
    }

    final performers = task.assignees.where((id) {
      final execMode = _execModeForUser(task, id);
      return execMode == ExecutionMode.separate;
    }).toList();
    if (performers.isEmpty) return false;

    return performers
        .every((uid) => _userRunState(task, uid) == UserRunState.finished);
  }

  bool _canFinalizeTask(TaskModel task) {
    if (task.status == TaskStatus.completed) return false;
    if (_anyUserActive(task)) return false;
    if (!_allPerformersFinished(task)) return false;
    return true;
  }

  Future<void> _finalizeTask(TaskModel task) async {
    final tp = context.read<TaskProvider>();
    final latest = tp.tasks.firstWhere(
      (t) => t.id == task.id,
      orElse: () => task,
    );
    final secs = _elapsed(latest).inSeconds;
    await tp.updateStatus(task.id, TaskStatus.completed,
        spentSeconds: secs, startedAt: null);

    if (!mounted) return;
    final note = await _askFinishNote();
    if (note != null && note.isNotEmpty) {
      await tp.addCommentAutoUser(
          taskId: task.id,
          type: 'finish_note',
          text: note,
          userIdOverride: widget.employeeId);
    }
  }

  Widget _buildControlPanel(TaskModel task, WorkplaceModel stage,
      TaskProvider provider, double scale, bool isTablet) {
    // === Derived state & permissions ===
    final int activeCount = _activeExecutorsCountForStage(provider, task);
    final bool shiftPaused = _isShiftPausedForStage(provider, task);
    final dynamic _rawCap = (stage as dynamic).maxConcurrentWorkers;
    final int capacity = (_rawCap is num ? _rawCap.toInt() : 1);
    final int effCap = capacity <= 0 ? 1 : capacity;
    final ExecutionMode? explicitStageMode = _stageExecutionMode(task);
    final ExecutionMode stageMode =
        explicitStageMode ?? _workplaceDefaultMode(stage);
    final ExecutionMode myExecMode = _execModeForUser(task, widget.employeeId);
    final bool groupLocked = _isStageGroupLocked(provider, task);
    // Consider a user an assignee only if they are explicitly assigned AND executing in
    // separate mode. Helpers (joint execution) should not gain full control over the task.
    final bool isAssignee = task.assignees.isEmpty ||
        (task.assignees.contains(widget.employeeId) &&
            (myExecMode == ExecutionMode.separate ||
                (stageMode == ExecutionMode.joint &&
                    task.assignees.isNotEmpty &&
                    task.assignees.first == widget.employeeId)));

    // Старт возможен, если задача ждёт/на паузе/с проблемой
    double scaled(double value) => value * scale;
    final double panelPadding = scaled(8);
    final double gapSmall = scaled(4);
    final double gapMedium = scaled(10);
    final double buttonSpacing = scaled(6);
    final double mediumSpacing = scaled(12);
    final double radius = scaled(12);

    // Старт возможен, если задача ждёт/на паузе/с проблемой
    // ИЛИ уже в работе, но есть свободная вместимость по рабочему месту.
    // Старт возможен, если задача ждёт/на паузе/с проблемой,
    // или уже в работе, но есть свободная вместимость по месту;
    // при этом соблюдаем последовательность этапов.

    bool _slotAvailable() {
      final tp = context.read<TaskProvider>();
      final int activeNow = _activeExecutorsCountForStage(tp, task);
      return activeNow < effCap;
    }

    final bool alreadyAssigned = task.assignees.contains(widget.employeeId);
    final bool isFirstAssignee = task.assignees.isEmpty;
    final bool canAutoAssign = !alreadyAssigned &&
        !isFirstAssignee &&
        _slotAvailable() &&
        stageMode == ExecutionMode.separate;
    final bool stageModeAllowsJoin =
        stageMode != ExecutionMode.joint || alreadyAssigned || isFirstAssignee;
    final bool canStart = (((isFirstAssignee ||
                alreadyAssigned ||
                canAutoAssign)) &&
            (task.status == TaskStatus.waiting ||
                task.status == TaskStatus.paused ||
                task.status == TaskStatus.problem ||
                (task.status == TaskStatus.inProgress && _slotAvailable()))) &&
        _isFirstPendingStage(context.read<TaskProvider>(),
            context.read<PersonnelProvider>(), task,
            groupResolver: _stageGroupKey) &&
        stageModeAllowsJoin &&
        !shiftPaused &&
        !groupLocked;

    // Пауза/Завершить/Проблема доступны только своим исполнителям
    final bool canPause =
        task.status == TaskStatus.inProgress && isAssignee && !shiftPaused;
    final bool canFinish = (task.status == TaskStatus.inProgress ||
            task.status == TaskStatus.paused ||
            task.status == TaskStatus.problem) &&
        isAssignee &&
        !shiftPaused;
    final bool canProblem =
        task.status == TaskStatus.inProgress && isAssignee && !shiftPaused;
    final bool canFinalizeTask = _canFinalizeTask(task);
    final Widget panel = Container(
      padding: EdgeInsets.all(panelPadding),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 4,
            offset: Offset(0, 2),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('🧭 Управление заданием',
              style:
                  TextStyle(fontSize: scaled(14), fontWeight: FontWeight.bold)),
          SizedBox(height: gapSmall),
          Column(
            children: [
              if (_hasMachineForStage(stage))
                Row(
                  children: [
                    ElevatedButton.icon(
                      onPressed:
                          !_isSetupCompletedForUser(task, widget.employeeId)
                              ? () => _startSetup(task, provider)
                              : null,
                      style: ElevatedButton.styleFrom(
                        padding: EdgeInsets.symmetric(
                          horizontal: scaled(12),
                          vertical: scaled(10),
                        ),
                        minimumSize: Size(scaled(90), scaled(36)),
                        visualDensity: isTablet
                            ? const VisualDensity(horizontal: -1, vertical: -1)
                            : null,
                      ),
                      icon: const Icon(Icons.build),
                      label: const Text('Наладка'),
                    ),
                    SizedBox(width: buttonSpacing),
                    ElevatedButton(
                      onPressed:
                          _isSetupCompletedForUser(task, widget.employeeId)
                              ? null
                              : () => _finishSetup(task, provider),
                      style: ElevatedButton.styleFrom(
                        padding: EdgeInsets.symmetric(
                          horizontal: scaled(12),
                          vertical: scaled(10),
                        ),
                        minimumSize: Size(scaled(90), scaled(36)),
                        visualDensity: isTablet
                            ? const VisualDensity(horizontal: -1, vertical: -1)
                            : null,
                      ),
                      child: const Text('Завершить наладку'),
                    ),
                    SizedBox(width: gapMedium),
                    StreamBuilder<DateTime>(
                      stream: Stream<DateTime>.periodic(
                          const Duration(seconds: 1), (_) => DateTime.now()),
                      builder: (context, _) {
                        // Use aggregated setup time across all related tasks to avoid
                        // inconsistent timing when multiple users are involved.
                        // Use per-task setup elapsed time to avoid aggregating
                        // across unrelated tasks, which can lead to huge jumps.
                        // Используем максимальное время настройки по каждой из
                        // связанных задач (объединяя периоды настройки внутри
                        // каждой) и берём максимум. Это устраняет двойной
                        // учёт и длительные промежутки между настройками.
                        final d = _setupElapsedStageMaxAgg(task);
                        String two(int n) => n.toString().padLeft(2, '0');
                        final s =
                            '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
                        return Text('Время настройки: $s',
                            style: TextStyle(fontSize: scaled(13)));
                      },
                    ),
                  ],
                ),
              SizedBox(height: gapSmall),
              // ==== Управление исполнением ===
              Builder(
                builder: (context) {
                  final ExecutionMode stageExecMode = stageMode;
                  final separateUsers = task.assignees
                      .where((id) {
                        final mode = _execModeForUser(task, id);
                        return mode == ExecutionMode.separate;
                      })
                      .toList();
                  final jointUsers = task.assignees
                      .where((id) =>
                          _execModeForUser(task, id) != ExecutionMode.separate)
                      .toList();

                  Widget buildControlsFor(String? label,
                      {List<String>? jointGroup, String? userId}) {
                    final tp = context.read<TaskProvider>();
                    final activeCount = _activeExecutorsCountForStage(tp, task);
                    final personnel = context.read<PersonnelProvider>();
                    final stage =
                        personnel.workplaces.firstWhere(
                          (w) => w.id == task.stageId,
                          orElse: () => WorkplaceModel(
                              id: '', name: '', positionIds: const []),
                        );
                    final rawCap = (stage as dynamic).maxConcurrentWorkers;
                    final effCap = (rawCap is num ? rawCap.toInt() : 1);

                    UserRunState state;
                    if (jointGroup != null) {
                      if (jointGroup.any((u) =>
                          _userRunState(task, u) == UserRunState.active)) {
                        state = UserRunState.active;
                      } else if (jointGroup.every((u) =>
                              _userRunState(task, u) ==
                              UserRunState.finished) &&
                          jointGroup.isNotEmpty) {
                        state = UserRunState.finished;
                      } else if (jointGroup.any((u) =>
                          _userRunState(task, u) == UserRunState.paused)) {
                        state = UserRunState.paused;
                      } else if (jointGroup.any((u) =>
                          _userRunState(task, u) == UserRunState.problem)) {
                        state = UserRunState.problem;
                      } else {
                        state = UserRunState.idle;
                      }
                    } else {
                      state = _userRunState(task, userId!);
                    }

                    // Determine whether this row belongs to the current user.
                    bool isMyRow;
                    String currentRowUserId;
                    if (jointGroup != null) {
                      currentRowUserId = widget.employeeId;
                      // In joint mode only the first user (who started) can control
                      isMyRow = jointGroup.isNotEmpty &&
                          jointGroup.first == widget.employeeId;
                    } else {
                      currentRowUserId = userId!;
                      isMyRow = userId == widget.employeeId;
                    }
                    final UserRunState stateRowUser =
                        _userRunState(task, currentRowUserId);
                    // Disable buttons for other users' rows
                    // Кнопка "Начать" доступна для своей строки, если
                    // пользователь может стартовать, и он либо ещё не
                    // запускал этап (idle), либо находится на паузе/в проблеме
                    // (разрешаем возобновление), либо уже завершил личную
                    // смену статуса, но этап ещё не закрыт общей кнопкой
                    // "Завершить" снизу.
                    final bool canStartButtonRow = isMyRow &&
                        canStart &&
                        (stateRowUser == UserRunState.idle ||
                            stateRowUser == UserRunState.paused ||
                            stateRowUser == UserRunState.problem ||
                            stateRowUser == UserRunState.finished);
                    final bool canPauseRow = isMyRow &&
                        canPause &&
                        stateRowUser == UserRunState.active;
                    // allow pausing also if user resumed
                    final bool canFinishRow = isMyRow &&
                        canFinish &&
                        (stateRowUser != UserRunState.idle &&
                            stateRowUser != UserRunState.finished);
                    final bool canProblemRow = isMyRow &&
                        canProblem &&
                        stateRowUser == UserRunState.active;
                    final bool canShiftControl = shiftPaused
                        ? true
                        : (isMyRow &&
                            (stateRowUser == UserRunState.active ||
                                stateRowUser == UserRunState.paused ||
                                stateRowUser == UserRunState.problem));

                    Future<void> recordTimeEventForUser(TaskTimeType type,
                        {String? note}) async {
                      final participants =
                          _participantsSnapshot(task, widget.employeeId);
                      final execMode = stageExecMode ??
                          _execModeForUser(task, widget.employeeId);
                      await tp.recordTimeEvent(
                        task: task,
                        type: type,
                        initiatedBy: widget.employeeId,
                        subjectUserId: currentRowUserId,
                        workplaceId: task.stageId,
                        participantsSnapshot: participants,
                        executionMode: _executionModeCode(execMode),
                        note: note,
                      );

                      if (jointGroup != null && isMyRow) {
                        final helpers = jointGroup
                            .where((id) => id != task.assignees.first)
                            .toList();
                        for (final helperId in helpers) {
                          await tp.recordTimeEvent(
                            task: task,
                            type: type,
                            initiatedBy: widget.employeeId,
                            subjectUserId: helperId,
                            workplaceId: task.stageId,
                            participantsSnapshot: participants,
                            executionMode: _executionModeCode(execMode),
                            helperId: helperId,
                            note: note,
                          );
                        }
                      }
                    }

                    Future<void> closeTimeEventForUser({String? note}) async {
                      await tp.closeOpenTimeEvent(
                        task: task,
                        initiatedBy: widget.employeeId,
                        subjectUserId: currentRowUserId,
                        note: note,
                      );
                      if (jointGroup != null && isMyRow) {
                        final helpers = jointGroup
                            .where((id) => id != task.assignees.first)
                            .toList();
                        for (final helperId in helpers) {
                          await tp.closeOpenTimeEvent(
                            task: task,
                            initiatedBy: widget.employeeId,
                            subjectUserId: helperId,
                            note: note,
                          );
                        }
                      }
                    }

                    Future<void> onStart() async {
                      // Sequential stage guard
                      if (!_isFirstPendingStage(context.read<TaskProvider>(),
                          context.read<PersonnelProvider>(), task,
                          groupResolver: _stageGroupKey)) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                              content: Text(
                                  'Сначала выполните предыдущий этап заказа')));
                        }
                        return;
                      }

                      if (_isStageGroupLocked(tp, task)) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                              content: Text('Уже выполняется альтернативный этап')));
                        }
                        return;
                      }

                      ExecutionMode? selectedMode = stageExecMode;
                      final alreadyAssigned =
                          task.assignees.contains(widget.employeeId);
                      if (explicitStageMode == null) {
                        await context.read<TaskProvider>().addComment(
                              taskId: task.id,
                              type: 'exec_mode_stage',
                              text: _executionModeCode(stageExecMode),
                              userId: widget.employeeId,
                            );
                      }

                      if (!alreadyAssigned) {
                        final newAssignees = List<String>.from(task.assignees)
                          ..add(widget.employeeId);
                        await context
                            .read<TaskProvider>()
                            .updateAssignees(task.id, newAssignees);
                      }

                      if (selectedMode != null &&
                          _needsExecModeRecord(
                              task, widget.employeeId, selectedMode)) {
                        await context.read<TaskProvider>().addComment(
                              taskId: task.id,
                              type: 'exec_mode',
                              text: _executionModeCode(selectedMode),
                              userId: widget.employeeId,
                            );
                      }
                      // Обновляем статус задачи. Не сбрасываем startedAt, если этап уже
                      // находится в работе – используем существующее значение. В
                      // состоянии паузы или проблемы возобновляем работу с тем же
                      // startedAt, чтобы таймер продолжал считаться корректно.
                      // Всегда обновляем статус: переводим этап в работу и
                      // сохраняем начальное время. Если этап ещё не начинался,
                      // фиксируем текущий момент; иначе используем существующий
                      // startedAt, чтобы не обнулять таймер.
                      final startedAtTs = task.startedAt ??
                          DateTime.now().millisecondsSinceEpoch;
                      await context.read<TaskProvider>().updateStatus(
                            task.id,
                            TaskStatus.inProgress,
                            startedAt: startedAtTs,
                          );
                      await context.read<TaskProvider>().addCommentAutoUser(
                          taskId: task.id,
                          type: 'start',
                          text: 'Начал(а) этап',
                          userIdOverride: widget.employeeId);
                      await recordTimeEventForUser(TaskTimeType.production);
                    }

                    Future<void> onPause() async {
                      final comment = await _askComment('Причина паузы');
                      if (comment == null) return;
                      await context.read<TaskProvider>().addCommentAutoUser(
                          taskId: task.id,
                          type: 'pause',
                          text: comment,
                          userIdOverride: widget.employeeId);
                      await recordTimeEventForUser(TaskTimeType.pause,
                          note: comment);
                      if (!_anyUserActive(task,
                          exceptUserId: widget.employeeId)) {
                        await context.read<TaskProvider>().updateStatus(
                            task.id, TaskStatus.paused,
                            startedAt: null);
                      }
                    }

                    Future<void> onFinish() async {
                      final unitLabel = _workplaceUnit(personnel, task.stageId);
                      final qtyInput =
                          await _askQuantity(context, unit: unitLabel);
                      if (qtyInput == null) return;
                      final qtyText = qtyInput.displayText;
                      final taskProvider = context.read<TaskProvider>();
                      if (jointGroup != null) {
                        final helperIds = jointGroup
                            .where((id) => id != widget.employeeId)
                            .toList();
                        for (final id in helperIds) {
                          await taskProvider.addComment(
                              taskId: task.id,
                              type: 'quantity_done',
                              text: qtyText,
                              userId: id);
                          await taskProvider.addComment(
                              taskId: task.id,
                              type: 'user_done',
                              text: 'done',
                              userId: id);
                        }
                        await taskProvider.addCommentAutoUser(
                            taskId: task.id,
                            type: 'quantity_done',
                            text: qtyText,
                            userIdOverride: widget.employeeId);
                        await taskProvider.addCommentAutoUser(
                            taskId: task.id,
                            type: 'user_done',
                            text: 'done',
                            userIdOverride: widget.employeeId);
                      } else {
                        // SEPARATE: write personal qty, require ALL separate-mode assignees to finish
                        await taskProvider.addCommentAutoUser(
                            taskId: task.id,
                            type: 'quantity_done',
                            text: qtyText,
                            userIdOverride: widget.employeeId);
                        await taskProvider.addCommentAutoUser(
                            taskId: task.id,
                            type: 'user_done',
                            text: 'done',
                            userIdOverride: widget.employeeId);

                        // Collect only assignees in 'separate' mode
                        final latestTask = taskProvider.tasks.firstWhere(
                          (t) => t.id == task.id,
                          orElse: () => task,
                        );
                        final separateIds = latestTask.assignees
                            .where((id) {
                              final mode = _execModeForUser(latestTask, id);
                              return mode == ExecutionMode.separate;
                            })
                            .toList();
                        // Ensure current user is included (in case he wasn't listed yet)
                        if (!separateIds.contains(widget.employeeId)) {
                          separateIds.add(widget.employeeId);
                        }

                        bool allDone = true;
                        for (final id in separateIds) {
                          final has = latestTask.comments.any(
                              (c) => c.type == 'user_done' && c.userId == id);
                          if (!has) {
                            allDone = false;
                            break;
                          }
                        }
                        if (allDone) {
                          // ждём финального подтверждения кнопкой внизу панели
                        } else {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text(
                                        'Ожидаем завершения остальных исполнителей (отдельный режим)…')));
                          }
                        }
                      }

                      await closeTimeEventForUser(note: 'finish');
                      final latestTask = taskProvider.tasks.firstWhere(
                        (t) => t.id == task.id,
                        orElse: () => task,
                      );
                      if (!_anyUserActive(latestTask)) {
                        final _secs = _elapsed(latestTask).inSeconds;
                        await taskProvider.updateStatus(task.id, TaskStatus.paused,
                            spentSeconds: _secs, startedAt: null);
                      }
                    }

                    Future<void> onProblem() async {
                      final comment = await _askComment('Причина проблемы');
                      if (comment == null) return;
                      await context.read<TaskProvider>().addCommentAutoUser(
                          taskId: task.id,
                          type: 'problem',
                          text: comment,
                          userIdOverride: widget.employeeId);
                      await recordTimeEventForUser(TaskTimeType.problem,
                          note: comment);
                      if (!_anyUserActive(task,
                          exceptUserId: widget.employeeId)) {
                        await context
                            .read<TaskProvider>()
                            .updateStatus(task.id, TaskStatus.problem);
                      }
                    }

                    Future<void> onShift() async {
                      final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: Text(shiftPaused
                                  ? 'Продолжить после пересмены?'
                                  : 'Пересмена'),
                              content: Text(shiftPaused
                                  ? 'Подтвердите возобновление работы на этапе.'
                                  : 'Этап будет остановлен до следующего сотрудника. Продолжить?'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(ctx).pop(false),
                                  child: const Text('Отмена'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.of(ctx).pop(true),
                                  child: const Text('Подтвердить'),
                                ),
                              ],
                            ),
                          ) ??
                          false;
                      if (!confirmed) return;

                      final taskProvider = context.read<TaskProvider>();
                      final analytics = context.read<AnalyticsProvider>();

                      if (!shiftPaused) {
                        final related = _relatedTasks(taskProvider, task);
                        for (final rel in related) {
                          if (rel.status == TaskStatus.inProgress) {
                            await taskProvider.updateStatus(
                                rel.id, TaskStatus.paused,
                                startedAt: null);
                          }
                        }
                        await recordTimeEventForUser(TaskTimeType.shiftChange);
                        await taskProvider.addCommentAutoUser(
                            taskId: task.id,
                            type: 'shift_pause',
                            text: 'Пересмена: этап приостановлен',
                            userIdOverride: widget.employeeId);
                        await analytics.logEvent(
                          orderId: task.orderId,
                          stageId: task.stageId,
                          userId: widget.employeeId,
                          action: 'shift_pause',
                          category: 'production',
                          details: 'Этап остановлен для пересмены',
                        );
                      } else {
                        await onStart();
                        final latest = taskProvider.tasks.firstWhere(
                          (t) => t.id == task.id,
                          orElse: () => task,
                        );
                        if (latest.status == TaskStatus.inProgress) {
                          await taskProvider.addCommentAutoUser(
                              taskId: task.id,
                              type: 'shift_resume',
                              text: 'Пересмена: работа возобновлена',
                              userIdOverride: widget.employeeId);
                          await analytics.logEvent(
                            orderId: task.orderId,
                            stageId: task.stageId,
                            userId: widget.employeeId,
                            action: 'shift_resume',
                            category: 'production',
                            details: 'Работа возобновлена после пересмены',
                          );
                        }
                      }
                    }

                    String timeText() {
                      final d = (jointGroup != null)
                          ? _elapsed(task)
                          : _userElapsed(task, userId!);
                      String two(int n) => n.toString().padLeft(2, '0');
                      final s =
                          '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
                      return s;
                    }

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Wrap(
                                spacing: buttonSpacing,
                                runSpacing: buttonSpacing,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  if (label != null)
                                    Padding(
                                        padding:
                                            const EdgeInsets.only(right: 8),
                                        child: Text(label,
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w600))),
                                  ElevatedButton(
                                      onPressed:
                                          canStartButtonRow ? onStart : null,
                                      child: const Text('▶ Начать')),
                                  ElevatedButton(
                                      onPressed: canPauseRow ? onPause : null,
                                      child: const Text('⏸ Пауза')),
                                  ElevatedButton(
                                      onPressed: canFinishRow ? onFinish : null,
                                      child:
                                          const Text('✓ Завершить участие')),
                                  ElevatedButton(
                                      onPressed:
                                          canProblemRow ? onProblem : null,
                                      child: const Text('⚠ Проблема')),
                                  SizedBox(width: gapMedium),
                                  // Обновляем отображение времени для каждой строки каждую секунду
                                  StreamBuilder<DateTime>(
                                    stream: Stream<DateTime>.periodic(
                                        const Duration(seconds: 1),
                                        (_) => DateTime.now()),
                                    builder: (context, _) {
                                      return Text('Время: ' + timeText());
                                    },
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(width: buttonSpacing),
                            ElevatedButton.icon(
                              onPressed: canShiftControl ? onShift : null,
                              icon: const Icon(Icons.autorenew),
                              label: Text(shiftPaused
                                  ? 'Продолжить пересмену'
                                  : 'Пересмена'),
                            ),
                          ],
                        ),
                      ],
                    );
                  }

                  final personnel = context.read<PersonnelProvider>();
                  final nameFor = (String uid) {
                    final emp = personnel.employees.firstWhere(
                      (e) => e.id == uid,
                      orElse: () => EmployeeModel(
                          id: uid,
                          firstName: 'Сотр.',
                          lastName:
                              uid.substring(0, uid.length > 4 ? 4 : uid.length),
                          patronymic: '',
                          iin: '',
                          photoUrl: null,
                          positionIds: const [],
                          isFired: false,
                          comments: '',
                          login: '',
                          password: ''),
                    );
                    return '${emp.firstName} ${emp.lastName}'.trim();
                  };

                  final rows = <Widget>[];
                  if (separateUsers.isNotEmpty) {
                    for (final uid in separateUsers) {
                      rows.add(buildControlsFor('Исполнитель: ' + nameFor(uid),
                          userId: uid));
                      rows.add(SizedBox(height: scaled(8)));
                    }
                  }
                  if (jointUsers.isNotEmpty) {
                    final labels = jointUsers.map(nameFor).toList();
                    final label = labels.isEmpty
                        ? 'Одиночная или совместная работа'
                        : 'Помощники: ' + labels.join(', ');
                    if (separateUsers.isEmpty) {
                      rows.add(buildControlsFor(label, jointGroup: jointUsers));
                    } else {
                      rows.add(Padding(
                        padding: EdgeInsets.symmetric(vertical: scaled(4)),
                        child: Text(label,
                            style: TextStyle(
                                fontStyle: FontStyle.italic,
                                color: Colors.grey,
                                fontSize: scaled(13))),
                      ));
                    }
                  } else if (task.assignees.isEmpty) {
                    rows.add(buildControlsFor('Одиночная или совместная работа',
                        jointGroup: jointUsers));
                  }
                  if (!task.assignees.contains(widget.employeeId) && canStart) {
                    rows.add(buildControlsFor('Вы', userId: widget.employeeId));
                  }
              return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: rows);
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
              if (task.assignees.isNotEmpty)
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green.shade600,
                    ),
                    onPressed:
                        canFinalizeTask ? () => _finalizeTask(task) : null,
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('Завершить задание'),
                  ),
                ),
            ],
          ),
        ],
      ),
    );

    // Determine if this user can join a task already started by others. A join button
    // should appear only when the task has at least one assignee (someone started
    // the stage) and the current user is not yet in the assignees list. Helpers and
    // unassigned users should not have control buttons or the ability to add
    // comments until they join. The join button is disabled when the stage’s
    // capacity (maxConcurrentWorkers) has been reached. Joining presents a choice
    // between separate execution (individual performer) and helper (joint).
    final bool _joinEligible = task.assignees.isNotEmpty &&
        !task.assignees.contains(widget.employeeId) &&
        stageMode == ExecutionMode.separate;
    final bool _joinCapacityAvailable = activeCount < effCap;
    if (_joinEligible) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          panel,
          SizedBox(height: mediumSpacing),
          ElevatedButton.icon(
            onPressed: _joinCapacityAvailable
                ? () => _joinTask(task, provider, widget.employeeId)
                : null,
            icon: const Icon(Icons.group_add),
            label: Text(_joinCapacityAvailable
                ? 'Присоединиться к заказу'
                : 'Нет свободных мест'),
          ),
        ],
      );
    }
    return panel;
  }

  Duration _elapsed(TaskModel task) {
    final timeEvents = _timeEventsForUser(task, widget.employeeId);
    if (timeEvents.isNotEmpty) {
      return _totalTimeForUser(task, widget.employeeId);
    }

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

  // Нормализация: если timestamp в секундах — переводим в миллисекунды.
  int _normTs(int ts) {
    // Значения меньше ~2 млрд считаем заданными в секундах (UNIX time),
    // всё остальное — уже миллисекунды. Отдельно обрабатываем редкий случай
    // микросекунд, чтобы не завышать длительности настройки.
    if (ts > 10000000000000) {
      // микросекунды -> миллисекунды
      return ts ~/ 1000;
    }
    if (ts < 2000000000) {
      return ts * 1000;
    }
    return ts;
  }

  /// Суммарное время настройки по всем исполнителям.
  /// Объединяет перекрывающиеся промежутки между 'setup_start' и 'setup_done'.
  Duration _setupElapsedAgg(TaskModel task) {
    final list = List<TaskComment>.from(task.comments)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    int active = 0;
    int? activeStart;
    int totalMs = 0;

    for (final c in list) {
      if (c.type == 'setup_start') {
        if (active == 0) activeStart = _normTs(c.timestamp);
        active++;
      } else if (c.type == 'setup_done') {
        if (active > 0 && activeStart != null) {
          final end = _normTs(c.timestamp);
          if (end > activeStart) totalMs += end - activeStart;
          activeStart = null;
        }
        if (active > 0) active--;
      }
    }

    if (active > 0 && activeStart != null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now > activeStart) totalMs += now - activeStart;
    }

    return Duration(milliseconds: totalMs);
  }

  /// Суммарное время настройки по каждому пользователю. Для каждого userId
  /// вычисляем пары setup_start/setup_done, складываем их длительность и
  /// затем суммируем по всем пользователям. При объединении учитываем
  /// дублирующиеся события (одинаковый timestamp и тип) из разных задач,
  /// чтобы не удваивать время настройки. Это устраняет двойной учёт
  /// перекрывающихся настроек разных исполнителей и одинаковых комментариев.
  Duration _setupElapsedPerUser(TaskModel task) {
    // Собираем события настройки по всем связанным задачам (по заказу и этапу).
    final tp = context.read<TaskProvider>();
    final related = tp.tasks
        .where((t) => t.orderId == task.orderId && t.stageId == task.stageId)
        .toList();
    // key: userId -> list of comments
    final Map<String, List<TaskComment>> eventsByUser = {};
    // Используем set для дедупликации событий по времени и типу
    final Set<String> seen = {};
    for (final t in related) {
      for (final c in t.comments) {
        if (c.type == 'setup_start' || c.type == 'setup_done') {
          final key = '${c.userId}-${c.timestamp}-${c.type}';
          if (seen.contains(key)) continue;
          seen.add(key);
          eventsByUser.putIfAbsent(c.userId, () => []).add(c);
        }
      }
    }
    int totalMs = 0;
    eventsByUser.forEach((uid, events) {
      events.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      int? open;
      int userTotal = 0;
      for (final e in events) {
        if (e.type == 'setup_start') {
          open = _normTs(e.timestamp);
        } else if (e.type == 'setup_done') {
          if (open != null) {
            final end = _normTs(e.timestamp);
            if (end > open) userTotal += end - open;
            open = null;
          }
        }
      }
      if (open != null) {
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now > open) userTotal += now - open;
      }
      totalMs += userTotal;
    });
    return Duration(milliseconds: totalMs);
  }

  /// Суммарное время настройки по всему этапу (для всех исполнителей).
  /// Берём самые ранние и последние события настройки среди всех
  /// связанных задач (по заказу и этапу). Это время показывает общий
  /// промежуток между началом первой настройки и завершением последней
  /// настройки, исключая двойной учёт. Если завершение отсутствует,
  /// считаем до текущего момента.
  Duration _setupElapsedStage(TaskModel task) {
    final tp = context.read<TaskProvider>();
    final related = tp.tasks
        .where((t) => t.orderId == task.orderId && t.stageId == task.stageId)
        .toList();
    int? earliestStart;
    int? latestDone;
    final Set<String> seenStart = {};
    final Set<String> seenDone = {};
    for (final t in related) {
      for (final c in t.comments) {
        if (c.type == 'setup_start') {
          final key = '${c.timestamp}-${c.type}';
          if (seenStart.add(key)) {
            final ts = _normTs(c.timestamp);
            if (earliestStart == null || ts < earliestStart!) {
              earliestStart = ts;
            }
          }
        } else if (c.type == 'setup_done') {
          final key = '${c.timestamp}-${c.type}';
          if (seenDone.add(key)) {
            final ts = _normTs(c.timestamp);
            if (latestDone == null || ts > latestDone!) {
              latestDone = ts;
            }
          }
        }
      }
    }
    if (earliestStart == null) return Duration.zero;
    if (latestDone == null || latestDone! < earliestStart!) {
      final now = DateTime.now().millisecondsSinceEpoch;
      return Duration(milliseconds: now - earliestStart!);
    }
    return Duration(milliseconds: latestDone! - earliestStart!);
  }

  /// Суммарное время настройки по максимуму среди всех клонов задач на этапе.
  /// Для каждой связанной задачи (по заказу и этапу) считаем объединённое время
  /// настройки этой задачи (с учётом перекрытий) и выбираем максимальное
  /// значение. Это позволяет корректно отображать общее время настройки,
  /// не суммируя одинаковые события и не растягивая время на длительные
  /// периоды между разными настройками.
  Duration _setupElapsedStageMaxAgg(TaskModel task) {
    final tp = context.read<TaskProvider>();
    final related = tp.tasks
        .where((t) => t.orderId == task.orderId && t.stageId == task.stageId)
        .toList();
    Duration maxDur = Duration.zero;
    for (final t in related) {
      // Получаем объединённую длительность настройки для каждой задачи
      final d = _setupElapsedAgg(t);
      if (d > maxDur) maxDur = d;
    }
    return maxDur;
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
    // Проверяем вместимость рабочего места перед началом настройки
    final stage = context.read<PersonnelProvider>().workplaces.firstWhere(
          (w) => w.id == task.stageId,
          orElse: () => WorkplaceModel(id: '', name: '', positionIds: const []),
        );
    final int active = _activeExecutorsCountForStage(provider, task);
    final int cap = ((stage as dynamic).maxConcurrentWorkers is num)
        ? ((stage as dynamic).maxConcurrentWorkers as num).toInt()
        : 1;
    final int effCap = cap <= 0 ? 1 : cap;
    final bool isAssignee = task.assignees.contains(widget.employeeId);
    if (active >= effCap && !isAssignee) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Нет свободных мест на рабочем месте')),
        );
      }
      return;
    }

    await provider.addCommentAutoUser(
      taskId: task.id,
      type: 'setup_start',
      text: 'Начал(а) настройку станка',
      userIdOverride: widget.employeeId,
    );
    final participants = _participantsSnapshot(task, widget.employeeId);
    final execMode = _stageExecutionMode(task);
    await provider.recordTimeEvent(
      task: task,
      type: TaskTimeType.setup,
      initiatedBy: widget.employeeId,
      subjectUserId: widget.employeeId,
      workplaceId: task.stageId,
      participantsSnapshot: participants,
      executionMode: execMode != null ? _executionModeCode(execMode) : null,
    );
    final helpers = _helperIds(task);
    if (helpers.isNotEmpty && task.assignees.first == widget.employeeId) {
      for (final helperId in helpers) {
        await provider.recordTimeEvent(
          task: task,
          type: TaskTimeType.setup,
          initiatedBy: widget.employeeId,
          subjectUserId: helperId,
          workplaceId: task.stageId,
          participantsSnapshot: participants,
          executionMode: execMode != null ? _executionModeCode(execMode) : null,
          helperId: helperId,
        );
      }
    }
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
    await provider.addCommentAutoUser(
      taskId: task.id,
      type: 'setup_done',
      text: 'Завершил(а) настройку станка',
      userIdOverride: widget.employeeId,
    );
    await provider.closeOpenTimeEvent(
      task: task,
      initiatedBy: widget.employeeId,
      subjectUserId: widget.employeeId,
      note: 'setup_done',
    );
    final helpers = _helperIds(task);
    if (helpers.isNotEmpty && task.assignees.first == widget.employeeId) {
      for (final helperId in helpers) {
        await provider.closeOpenTimeEvent(
          task: task,
          initiatedBy: widget.employeeId,
          subjectUserId: helperId,
          note: 'setup_done',
        );
      }
    }
  }

  Future<String?> _askFinishNote() async {
    if (!mounted) return null;
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
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
          onSubmitted: (_) => Navigator.of(ctx).pop(controller.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Сохранить'),
          ),
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

    await provider.addCommentAutoUser(
        taskId: task.id,
        type: 'pause',
        text: comment,
        userIdOverride: widget.employeeId);
    await provider.recordTimeEvent(
      task: task,
      type: TaskTimeType.pause,
      initiatedBy: widget.employeeId,
      subjectUserId: widget.employeeId,
      workplaceId: task.stageId,
      participantsSnapshot: _participantsSnapshot(task, widget.employeeId),
      note: comment,
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

    await provider.addCommentAutoUser(
        taskId: task.id,
        type: 'problem',
        text: comment,
        userIdOverride: widget.employeeId);
    await provider.recordTimeEvent(
      task: task,
      type: TaskTimeType.problem,
      initiatedBy: widget.employeeId,
      subjectUserId: widget.employeeId,
      workplaceId: task.stageId,
      participantsSnapshot: _participantsSnapshot(task, widget.employeeId),
      note: comment,
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

  List<_StageComment> _collectOrderComments(
      TaskProvider provider, TaskModel pivot) {
    final cache =
        _orderCommentsCache.putIfAbsent(pivot.orderId, () => <String, _StageComment>{});
    final related =
        provider.tasks.where((t) => t.orderId == pivot.orderId).toList();
    for (final task in related) {
      for (final comment in task.comments) {
        if (comment.type == 'time_event') continue;
        final key =
            '${task.id}-${comment.id}-${comment.timestamp}-${comment.type}-${comment.userId}-${comment.text}';
        cache[key] =
            _StageComment(comment: comment, stageId: task.stageId, taskId: task.id);
      }
    }
    final result = cache.values.toList();
    result.sort((a, b) {
      final tsDiff = a.comment.timestamp.compareTo(b.comment.timestamp);
      if (tsDiff != 0) return tsDiff;
      final stageDiff = a.stageId.compareTo(b.stageId);
      if (stageDiff != 0) return stageDiff;
      return a.taskId.compareTo(b.taskId);
    });
    return result;
  }

  bool _isShiftPausedForStage(TaskProvider provider, TaskModel pivot) {
    final related = _relatedTasks(provider, pivot);
    final timeEvents = <TaskTimeEvent>[];
    for (final t in related) {
      timeEvents.addAll(_taskTimeEvents(t));
    }
    final openShift = timeEvents
        .where((e) => e.type == TaskTimeType.shiftChange && e.endTime == null)
        .toList();
    if (openShift.isNotEmpty) return true;

    final events = <TaskComment>[];
    for (final t in related) {
      for (final c in t.comments) {
        if (c.type == 'shift_pause' || c.type == 'shift_resume') {
          events.add(c);
        }
      }
    }
    if (events.isEmpty) return false;
    events.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return events.last.type == 'shift_pause';
  }

  Future<String?> _fetchAndCacheFormImage(OrderModel order) async {
    final key = order.id;
    try {
      Map<String, dynamic>? row;
      final client = Supabase.instance.client;
      final code = order.formCode?.trim();
      if (code != null && code.isNotEmpty) {
        final res = await client
            .from('forms')
            .select('image_url')
            .eq('code', code)
            .maybeSingle();
        if (res != null && res is Map) {
          row = Map<String, dynamic>.from(res);
        }
      }
      final hasImage =
          row != null && (row['image_url'] ?? '').toString().trim().isNotEmpty;
      if (!hasImage &&
          order.formSeries != null &&
          order.formSeries!.trim().isNotEmpty &&
          order.newFormNo != null) {
        final res = await client
            .from('forms')
            .select('image_url')
            .eq('series', order.formSeries!.trim())
            .eq('number', order.newFormNo!)
            .maybeSingle();
        if (res != null && res is Map) {
          row = Map<String, dynamic>.from(res);
        }
      }
      final raw = row?['image_url'];
      final url = (raw is String && raw.trim().isNotEmpty) ? raw.trim() : null;
      _formImageCache[key] = url;
      return url;
    } catch (e) {
      debugPrint('❌ load form image error: $e');
      _formImageCache[key] = null;
      return null;
    } finally {
      _formImagePending.remove(key);
    }
  }

  Future<String?> _getFormImageFuture(OrderModel order) {
    final key = order.id;
    if (_formImageCache.containsKey(key)) {
      return Future.value(_formImageCache[key]);
    }
    if (_formImagePending.containsKey(key)) {
      return _formImagePending[key]!;
    }
    final future = _fetchAndCacheFormImage(order);
    _formImagePending[key] = future;
    return future;
  }

  Future<void> _openFormImage(String url) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Фото формы')),
          body: Center(
            child: InteractiveViewer(
              child: Image.network(
                url,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) => const Icon(
                  Icons.broken_image,
                  size: 96,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

}

class _TaskCard extends StatelessWidget {
  final TaskModel task;
  final OrderModel? order;
  final bool selected;
  final bool readyForStage;
  final bool showStageHint;
  final VoidCallback onTap;
  final bool compact;
  final double scale;

  const _TaskCard({
    required this.task,
    required this.order,
    required this.onTap,
    this.selected = false,
    this.readyForStage = false,
    this.showStageHint = false,
    this.compact = false,
    this.scale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(task.status);
    final name = order?.product.type ?? '';
    final displayId = () {
      if (order == null) return task.orderId;
      final formatted = orderDisplayId(order!);
      if (formatted != '—') return formatted;
      return order!.id;
    }();
    final displayTitle = (order != null && order!.customer.isNotEmpty)
        ? order!.customer
        : (name.isNotEmpty ? name : displayId);
    double scaled(double value) => value * scale;
    final EdgeInsets contentPadding = EdgeInsets.symmetric(
      horizontal: scaled(compact ? 10 : 12),
      vertical: scaled(compact ? 6 : 8),
    );
    final double titleSize = scaled(compact ? 13 : 14.5);
    final double subtitleSize = scaled(compact ? 11.5 : 12.5);
    final double statusSize = scaled(11.5);
    final String? stageHint = showStageHint
        ? (readyForStage
            ? 'Можно начинать: предыдущий этап завершён'
            : 'Ожидает завершения предыдущего этапа')
        : null;
    final Color readyColor = Colors.green.shade600;
    final Color stageHintColor =
        readyForStage ? readyColor : Colors.grey.shade600;

    return Card(
      margin: EdgeInsets.symmetric(vertical: scaled(compact ? 3 : 5)),
      elevation: 0.5,
      shadowColor: const Color(0x14000000),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(scaled(12)),
        side: BorderSide(
          color: selected
              ? const Color(0xFF1D4ED8)
              : (readyForStage ? readyColor : const Color(0xFFE2E4EA)),
        ),
      ),
      color: readyForStage ? readyColor.withOpacity(0.05) : Colors.white,
      child: ListTile(
        onTap: onTap,
        dense: compact,
        visualDensity: compact
            ? const VisualDensity(horizontal: -2, vertical: -2)
            : (scale < 1
                ? const VisualDensity(horizontal: -1, vertical: -1)
                : null),
        isThreeLine: stageHint != null && name.isNotEmpty,
        contentPadding: contentPadding,
        title: Text(
          displayTitle,
          style: TextStyle(
            fontSize: titleSize,
            fontWeight: FontWeight.w600,
            color: Colors.black87,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: (name.isNotEmpty || stageHint != null)
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (name.isNotEmpty)
                    Text(
                      name,
                      style: TextStyle(
                        fontSize: subtitleSize,
                        color: Colors.grey[600],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (stageHint != null)
                    Padding(
                      padding: EdgeInsets.only(top: name.isNotEmpty ? 2 : 0),
                      child: Text(
                        stageHint,
                        style: TextStyle(
                          fontSize: subtitleSize - 0.5,
                          color: stageHintColor,
                          fontWeight:
                              readyForStage ? FontWeight.w600 : FontWeight.w500,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              )
            : null,
        trailing: Container(
          padding: EdgeInsets.symmetric(
            horizontal: scaled(10),
            vertical: scaled(compact ? 3 : 4),
          ),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(scaled(12)),
          ),
          child: Text(
            _statusText(task.status),
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: statusSize,
            ),
          ),
        ),
      ),
    );
  }
}

class _AssignedEmployeesRow extends StatelessWidget {
  final TaskModel task;
  final double scale;
  final bool compact;
  final String currentUserId;
  const _AssignedEmployeesRow(
      {required this.task,
      required this.scale,
      this.compact = false,
      required this.currentUserId});

  @override
  Widget build(BuildContext context) {
    final personnel = context.watch<PersonnelProvider>();
    final taskProvider = context.read<TaskProvider>();
    final stage = personnel.workplaces.firstWhere(
      (w) => w.id == task.stageId,
      orElse: () =>
          WorkplaceModel(id: task.stageId, name: task.stageId, positionIds: const []),
    );
    final ExecutionMode? explicitStageMode = _stageExecutionMode(task);
    final stageMode = explicitStageMode ?? _workplaceDefaultMode(stage);
    final bool isOwner =
        task.assignees.isNotEmpty && task.assignees.first == currentUserId;
    final dynamic rawCap = (stage as dynamic).maxConcurrentWorkers;
    final int cap = (rawCap is num ? rawCap.toInt() : 1);
    final int effCap = cap <= 0 ? 1 : cap;
    final bool canAddHelper =
        isOwner && stageMode == ExecutionMode.joint && effCap > 1;

    double scaled(double value) => value * scale;
    final double spacing = scaled(compact ? 6 : 8);
    final double chipSpacing = scaled(4);
    final TextStyle labelStyle = TextStyle(fontSize: scaled(14));

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

    Future<void> _addHelper() async {
      if (!isOwner) return;

      if (stageMode != ExecutionMode.joint) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Помощники доступны только в режиме "Одиночная или совместная работа".')));
        return;
      }

      final available = personnel.employees
          .where((e) => !task.assignees.contains(e.id))
          .toList();
      if (available.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Нет свободных сотрудников для помощи.')));
        return;
      }

      String? selectedId;
      String password = '';
      bool wrongPass = false;
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setStateDialog) => AlertDialog(
            title: const Text('Добавить помощника'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  value: available.any((e) => e.id == selectedId)
                      ? selectedId
                      : null,
                  items: [
                    for (final e in available)
                      DropdownMenuItem(
                        value: e.id,
                        child: Text('${e.lastName} ${e.firstName}'),
                      ),
                  ],
                  onChanged: (val) => setStateDialog(() {
                    selectedId = val;
                    wrongPass = false;
                  }),
                ),
                const SizedBox(height: 8),
                TextField(
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: 'Пароль',
                    errorText: wrongPass ? 'Неверный пароль' : null,
                  ),
                  onChanged: (val) => password = val,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Отмена'),
              ),
              TextButton(
                onPressed: () {
                  if (selectedId == null) return;
                  final emp = personnel.employees.firstWhere(
                    (e) => e.id == selectedId,
                    orElse: () => EmployeeModel(
                      id: '',
                      lastName: '',
                      firstName: '',
                      patronymic: '',
                      iin: '',
                      photoUrl: null,
                      positionIds: const [],
                      isFired: false,
                      comments: '',
                      login: '',
                      password: '',
                    ),
                  );
                  if (emp.password == password) {
                    Navigator.pop(ctx);
                  } else {
                    setStateDialog(() => wrongPass = true);
                  }
                },
                child: const Text('Добавить'),
              ),
            ],
          ),
        ),
      );

      if (selectedId != null) {
        final int active = _activeExecutorsCountForStage(taskProvider, task);
        if (active + 1 > effCap) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Нет свободных мест на рабочем месте')),
          );
          return;
        }

        if (explicitStageMode == null) {
          await taskProvider.addComment(
            taskId: task.id,
            type: 'exec_mode_stage',
            text: _executionModeCode(ExecutionMode.joint),
            userId: currentUserId,
          );
        }

        final newAssignees = List<String>.from(task.assignees)
          ..add(selectedId!);
        await taskProvider.updateAssignees(task.id, newAssignees);

        if (_needsExecModeRecord(task, selectedId!, ExecutionMode.joint)) {
          await taskProvider.addComment(
            taskId: task.id,
            type: 'exec_mode',
            text: _executionModeCode(ExecutionMode.joint),
            userId: selectedId!,
          );
        }

        await taskProvider.addCommentAutoUser(
          taskId: task.id,
          type: 'joined',
          text: 'Присоединился(лась) к этапу',
          userIdOverride: selectedId!,
        );
      }
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Исполнители:', style: labelStyle),
        SizedBox(width: spacing),
        StreamBuilder<DateTime>(
          stream: Stream<DateTime>.periodic(
              const Duration(seconds: 1), (_) => DateTime.now()),
          builder: (context, _) {
            int seconds = task.spentSeconds;
            if (task.status == TaskStatus.inProgress &&
                task.startedAt != null) {
              seconds +=
                  (DateTime.now().millisecondsSinceEpoch - task.startedAt!) ~/
                      1000;
            }
            final d = Duration(seconds: seconds);
            String two(int n) => n.toString().padLeft(2, '0');
            final s =
                '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
            return Text('⏱ ' + s,
                style: TextStyle(
                  color: Colors.grey,
                  fontSize: scaled(13),
                ));
          },
        ),
        SizedBox(width: scaled(4)),
        Flexible(
          fit: FlexFit.loose,
          child: Wrap(
            spacing: chipSpacing,
            runSpacing: chipSpacing / 2,
            children: [
              for (final name in names)
                Chip(
                  label: Text(name, style: TextStyle(fontSize: scaled(12))),
                  visualDensity: compact
                      ? const VisualDensity(horizontal: -2, vertical: -2)
                      : VisualDensity.standard,
                ),
            ],
          ),
        ),
        if (canAddHelper)
          Padding(
            padding: EdgeInsets.only(left: scaled(6)),
            child: IconButton(
              visualDensity:
                  const VisualDensity(horizontal: -2, vertical: -2),
              icon: const Icon(Icons.add_circle_outline),
              tooltip: 'Добавить помощника',
              onPressed: _addHelper,
            ),
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

Future<_QuantityInput?> _askQuantity(BuildContext context, {String? unit}) async {
  final controller = TextEditingController();
  final unitLabel = (unit ?? '').trim();
  final v = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Количество выполнено'),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          hintText: unitLabel.isNotEmpty
              ? 'Введите количество в ${unitLabel}'
              : 'Введите количество экземпляров',
          border: const OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
        ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('OK')),
      ],
    ),
  );
  if (v == null || v.isEmpty) return null;
  final n = int.tryParse(v);
  if (n == null) return null;
  final display = unitLabel.isNotEmpty ? '$n $unitLabel' : n.toString();
  return _QuantityInput(quantity: n, displayText: display);
}

Duration _setupElapsed(TaskModel task, String userId) {
  final starts = task.comments
      .where((c) => c.type == 'setup_start' && c.userId == userId)
      .toList();
  if (starts.isEmpty) return Duration.zero;
  final start = DateTime.fromMillisecondsSinceEpoch(
      starts.map((c) => c.timestamp).reduce((a, b) => a > b ? a : b));
  final dones = task.comments
      .where((c) => c.type == 'setup_done' && c.userId == userId)
      .toList();
  final end = dones.isEmpty
      ? DateTime.now()
      : DateTime.fromMillisecondsSinceEpoch(
          dones.map((c) => c.timestamp).reduce((a, b) => a > b ? a : b));
  return end.difference(start);
}

Duration _setupElapsedTotal(TaskModel task) {
  final starts = task.comments.where((c) => c.type == 'setup_start').toList();
  if (starts.isEmpty) return Duration.zero;
  final startTs =
      starts.map((c) => c.timestamp).reduce((a, b) => a > b ? a : b);
  final start = DateTime.fromMillisecondsSinceEpoch(startTs);
  final doneList = task.comments.where((c) => c.type == 'setup_done').toList();
  final end = doneList.isEmpty
      ? DateTime.now()
      : DateTime.fromMillisecondsSinceEpoch(
          doneList.map((c) => c.timestamp).reduce((a, b) => a > b ? a : b));
  return end.difference(start);
}
