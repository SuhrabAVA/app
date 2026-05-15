import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../orders/order_model.dart';
import '../orders/order_details_card.dart';
import '../orders/orders_repository.dart';
import '../orders/id_format.dart';
import '../orders/orders_provider.dart';
import '../orders/material_model.dart';
import '../personnel/employee_model.dart';
import '../personnel/personnel_provider.dart';
import '../personnel/workplace_model.dart';
import '../analytics/analytics_provider.dart';
import '../production/production_queue_provider.dart';
import '../production_planning/template_provider.dart';
import '../production_planning/template_model.dart';
import '../production_planning/planned_stage_model.dart';
import '../warehouse/tmc_model.dart';
import '../warehouse/warehouse_provider.dart';
import 'task_model.dart';
import 'task_completion_rules.dart';
import 'task_provider.dart';
import 'task_visibility.dart';
import 'stage_sequence_utils.dart' as stage_sequence;
import '../common/pdf_view_screen.dart';
import '../../services/storage_service.dart';
import '../../services/attachment_service.dart';
// Additional helpers for time formatting and aggregated timers
const String kCardboardCuttingStageId =
    stage_sequence.kCardboardCuttingStageId;

const Set<String> _meterUnitAliases = <String>{
  'м',
  'метр',
  'метры',
  'm',
  'meter',
  'meters',
};

String _normalizeTaskQuantityUnit(String? unit) =>
    (unit ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

bool isTaskMeterUnit(String? unit) =>
    _meterUnitAliases.contains(_normalizeTaskQuantityUnit(unit));

double? _taskPaperLengthNumber(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  if (value is String) {
    final normalized = value.trim().replaceAll(',', '.');
    if (normalized.isEmpty) return null;
    final parsed = double.tryParse(normalized);
    if (parsed != null) return parsed;
    return double.tryParse(normalized.replaceAll(RegExp(r'[^0-9.\-]'), ''));
  }
  return null;
}

double? _taskPaperLengthFromMap(Map<String, dynamic>? map) {
  if (map == null) return null;
  for (final key in const <String>['lengthL', 'length_l', 'length', 'L']) {
    final parsed = _taskPaperLengthNumber(map[key]);
    if (parsed != null && parsed > 0) return parsed;
  }
  final paper = map['paper'];
  if (paper is Map) {
    final parsed = _taskPaperLengthFromMap(Map<String, dynamic>.from(paper));
    if (parsed != null && parsed > 0) return parsed;
  }
  return null;
}

double? _taskPaperLengthFromMaterial(MaterialModel material) {
  final extraLength = _taskPaperLengthFromMap(material.extra);
  if (extraLength != null && extraLength > 0) return extraLength;
  if (material.quantity > 0) return material.quantity;
  return null;
}

double taskPaperLengthTotalForOrder(OrderModel? order) {
  if (order == null) return 0;

  final materialTotal = order.paperMaterials.fold<double>(0, (sum, material) {
    final length = _taskPaperLengthFromMaterial(material);
    return length == null || length <= 0 ? sum : sum + length;
  });
  if (materialTotal > 0) return materialTotal;

  final productMap = order.product.toMap();
  final productLength = _taskPaperLengthFromMap(productMap);
  if (productLength != null && productLength > 0) return productLength;

  final directLength = order.product.length;
  if (directLength != null && directLength > 0) return directLength;

  return 0;
}

double? initialTaskMeterQuantityForOrder({
  required String? unit,
  required OrderModel? order,
}) {
  if (!isTaskMeterUnit(unit)) return null;
  final total = taskPaperLengthTotalForOrder(order);
  return total > 0 ? total : null;
}

String formatTaskInitialQuantity(double value) {
  if (value % 1 == 0) return value.toStringAsFixed(0);
  return value
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

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

Duration _timeForUser(
    TaskModel task, String userId, Set<TaskTimeType> types) {
  final now = DateTime.now().toUtc();
  Duration total = Duration.zero;
  for (final event in _timeEventsForUser(task, userId)) {
    if (!types.contains(event.type)) continue;
    final end = event.endTime ?? now;
    total += end.difference(event.startTime);
  }
  return total;
}

Duration _totalTimeForUser(TaskModel task, String userId) {
  return _timeForUser(
      task, userId, {TaskTimeType.production, TaskTimeType.setup});
}

Duration _totalStageTime(TaskModel task) {
  final events = _taskTimeEvents(task)
      .where((event) =>
          event.type == TaskTimeType.production || event.type == TaskTimeType.setup)
      .toList();
  if (events.isEmpty) return Duration(seconds: task.spentSeconds);

  final now = DateTime.now().toUtc();
  final intervals = events
      .map((event) => MapEntry(event.startTime, event.endTime ?? now))
      .toList()
    ..sort((a, b) => a.key.compareTo(b.key));

  Duration total = Duration.zero;
  DateTime? openStart;
  DateTime? openEnd;
  for (final interval in intervals) {
    if (openStart == null) {
      openStart = interval.key;
      openEnd = interval.value;
      continue;
    }
    if (interval.key.isAfter(openEnd!)) {
      total += openEnd.difference(openStart);
      openStart = interval.key;
      openEnd = interval.value;
      continue;
    }
    if (interval.value.isAfter(openEnd)) {
      openEnd = interval.value;
    }
  }
  if (openStart != null && openEnd != null) {
    total += openEnd.difference(openStart);
  }
  return total;
}

Duration _setupElapsedFromTimeEvents(TaskModel task) {
  final events = _taskTimeEvents(task)
      .where((event) => event.type == TaskTimeType.setup)
      .toList();
  if (events.isEmpty) return Duration.zero;
  final now = DateTime.now().toUtc();
  final intervals = events
      .map((e) =>
          MapEntry(e.startTime, e.endTime ?? now))
      .toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  Duration total = Duration.zero;
  DateTime? openStart;
  DateTime? openEnd;
  for (final interval in intervals) {
    if (openStart == null) {
      openStart = interval.key;
      openEnd = interval.value;
      continue;
    }
    if (interval.key.isAfter(openEnd!)) {
      total += openEnd.difference(openStart);
      openStart = interval.key;
      openEnd = interval.value;
    } else if (interval.value.isAfter(openEnd)) {
      openEnd = interval.value;
    }
  }
  if (openStart != null && openEnd != null) {
    total += openEnd.difference(openStart);
  }
  return total;
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
      final lastStartTs = timeEvents
          .map((e) => e.startTime.millisecondsSinceEpoch)
          .fold<int>(0, (a, b) => a > b ? a : b);
      if (lastDone >= lastStartTs) {
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

bool _hasUserParticipatedInStage(TaskModel task, String userId) {
  if (_timeEventsForUser(task, userId).isNotEmpty) return true;

  return task.comments.any((c) {
    if (c.userId != userId) return false;
    return c.type == 'start' ||
        c.type == 'resume' ||
        c.type == 'pause' ||
        c.type == 'problem' ||
        c.type == 'user_done' ||
        c.type == 'setup_start' ||
        c.type == 'setup_done';
  });
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

bool _isEffectivelyCompleted(TaskModel task) {
  return isTaskFinallyCompleted(task);
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
    TemplateProvider _templates,
    OrdersProvider _orders,
    TaskProvider tasks,
    String orderId,
    String stageId) {
  final savedGroupMap = tasks.stageGroupMapForOrder(orderId);
  if (savedGroupMap != null && savedGroupMap.containsKey(stageId.trim())) {
    final savedName = tasks.stageNameForOrder(orderId, stageId)?.trim();
    if (savedName != null && savedName.isNotEmpty) return savedName;
    return _workplaceName(personnel, stageId, tasks: tasks, orderId: orderId);
  }

  // Stage labels/grouping come from TaskProvider, which loads the shared
  // saved queue mapper and applies template data only as old-data fallback.
  return _workplaceName(personnel, stageId, tasks: tasks, orderId: orderId);
}

Map<String, String> _stageGroupMapForOrder(
  OrderModel order,
  TemplateProvider _templates, {
  TaskProvider? tasks,
}) {
  final saved = tasks?.stageGroupMapForOrder(order.id);
  if (saved != null && saved.isNotEmpty) return saved;

  // Do not derive factual grouping directly from stageTemplateId here.
  // TaskProvider has already applied the shared queue priority and returns a
  // template-derived map only for legacy orders without a saved queue.
  return const <String, String>{};
}

String? _workplaceUnit(PersonnelProvider personnel, String stageId) {
  final wp = personnel.workplaceById(stageId);
  final text = wp?.unit?.trim();
  if (text != null && text.isNotEmpty) return text;
  return null;
}

String _stageDisplayName(PersonnelProvider personnel, String stageId) {
  final wp = personnel.workplaceById(stageId);
  final name = wp?.name.trim();
  if (name != null && name.isNotEmpty) return name;
  return stageId;
}

/// Разрешить старт только для самого первого незавершённого этапа заказа
bool _canRunOutOfStageSequence(TaskModel task) =>
    task.stageId.trim() == kCardboardCuttingStageId;

bool _hasStartedForStageSequence(TaskModel task) {
  if (task.status == TaskStatus.inProgress ||
      task.status == TaskStatus.completed ||
      task.status == TaskStatus.problem) {
    return true;
  }

  final hasStartComment = task.comments.any(
    (c) =>
        c.type == 'start' ||
        c.type == 'resume' ||
        c.type == 'user_done' ||
        c.type == 'problem',
  );
  if (hasStartComment) return true;

  return _taskTimeEvents(task).any(
    (event) => event.type == TaskTimeType.production,
  );
}

bool _isFirstPendingStage(TaskProvider tasks, PersonnelProvider personnel,
    TaskModel task,
    {stage_sequence.StageGroupingResolver? groupResolver}) {
  if (_canRunOutOfStageSequence(task)) return true;

  final all = tasks.tasks.where((t) => t.orderId == task.orderId).toList();
  if (all.isEmpty) return true;

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

  return stage_sequence.isFirstPendingStageInOrder(
    orderId: task.orderId,
    currentStageId: task.stageId,
    stageStates: all.map(
      (t) => stage_sequence.PendingStageState(
        stageId: t.stageId,
        stageName: _stageDisplayName(personnel, t.stageId),
        stageGroupKey: t.stageGroupKey,
        completed: _isEffectivelyCompleted(t),
        problem: t.status == TaskStatus.problem ||
            t.comments.any((c) => c.type == 'problem'),
        started: _hasStartedForStageSequence(t),
      ),
    ),
    orderedStages: tasks.stageSequenceForOrder(task.orderId) ?? const [],
    groupResolver: groupResolver,
    fallbackStageComparator: byName,
    currentStageName: _stageDisplayName(personnel, task.stageId),
    currentStageGroupKey: task.stageGroupKey,
  );
}

bool _hasWorkplaceQueueActivity(TaskModel task) {
  if (task.status != TaskStatus.waiting) return true;
  return task.comments.any(
    (c) => c.type == 'start' || c.type == 'resume' || c.type == 'user_done',
  );
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
  final double quantity;
  final String displayText;
  final bool openPaperEditor;
  final int? packsCount;
  final int? unitsPerPack;

  const _QuantityInput({
    required this.quantity,
    required this.displayText,
    this.openPaperEditor = false,
    this.packsCount,
    this.unitsPerPack,
  });
}

class _TaskSelectionState extends ChangeNotifier {
  String? workplaceId;
  TaskModel? task;
  TaskStatus status;

  _TaskSelectionState({
    this.workplaceId,
    this.task,
    this.status = TaskStatus.inProgress,
  });
}

final Map<String, _TaskSelectionState> _selectionCache = {};

class _CommentDraft {
  final String text;
  final List<AttachmentDraft> attachments;

  const _CommentDraft({required this.text, this.attachments = const []});
}

class _InkUsageDialogResult {
  final List<Map<String, dynamic>> paints;
  final bool openPaperEditor;

  const _InkUsageDialogResult({
    required this.paints,
    this.openPaperEditor = false,
  });
}

class FlexPaintWriteoffRow {
  final Map<String, dynamic> sourceRow;
  final String source;
  final String queueId;
  final String orderId;
  final String orderLabel;
  final String paintId;
  final String paintName;
  final double plannedAmount;
  final String unit;
  String actualUsedText;
  bool writeOffNow;
  String status;

  FlexPaintWriteoffRow({
    required this.sourceRow,
    required this.source,
    required this.queueId,
    required this.orderId,
    required this.orderLabel,
    required this.paintId,
    required this.paintName,
    required this.plannedAmount,
    required this.unit,
    required this.actualUsedText,
    this.writeOffNow = false,
    String? status,
  }) : status = status ?? '' {
    refreshStatus();
  }

  bool get isPendingSource {
    final normalized = source.trim().toLowerCase();
    return normalized == 'pending' ||
        normalized == 'pending_queue' ||
        normalized == 'queued' ||
        normalized == 'writeoff_queue';
  }

  void refreshStatus() {
    status = writeOffNow
        ? 'будет списано'
        : (isPendingSource ? 'ожидает списания' : 'не списывать сейчас');
  }
}

class _TasksScreenState extends State<TasksScreen>
    with AutomaticKeepAliveClientMixin<TasksScreen> {
  static const Duration _formImageCacheTtl = Duration(seconds: 10);

  @override
  bool get wantKeepAlive => true;
  // Compatibility shim: legacy takenByAnother flag removed
  bool get takenByAnother => false;

  final TextEditingController _chatController = TextEditingController();
  final ScrollController _commentsScrollController = ScrollController();
  final List<AttachmentDraft> _pendingCommentAttachments = <AttachmentDraft>[];
  late final _TaskSelectionState _selection;
  bool _selectionUpdateScheduled = false;
  String? _lastQueueSyncGroupId;
  String? _lastQueueSyncIdsSignature;
  String? _lastLaunchedOrderIdsSignature;
  bool _taskRefreshAfterLaunchScheduled = false;
  final Set<String> _startingTaskIds = <String>{};
  final Set<String> _startingSetupTaskIds = <String>{};
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
  final Map<String, _FormImageCacheEntry> _formImageCache = {};
  final Map<String, Future<String?>> _formImagePending = {};
  final Map<String, List<Map<String, dynamic>>> _orderPaintsCache = {};
  final Map<String, Future<List<Map<String, dynamic>>>> _orderPaintsPending = {};
  final Map<String, List<Map<String, dynamic>>> _orderFilesCache = {};
  final Map<String, Future<List<Map<String, dynamic>>>> _orderFilesPending = {};
  final Map<String, Map<String, _StageComment>> _orderCommentsCache = {};
  String? _lastCommentsTaskId;
  String _lastCommentsSignature = '';
  int _lastCommentsCount = 0;
  String get _widKey => 'ws-${widget.employeeId}-wid';
  String get _tidKey => 'ws-${widget.employeeId}-tid';
  static const Map<TaskStatus, String> _statusLabels = {
    TaskStatus.inProgress: 'Задания',
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
    _commentsScrollController.dispose();
    _chatController.dispose();
    super.dispose();
  }

  void _scheduleSelectionUpdate(VoidCallback update) {
    if (_selectionUpdateScheduled) return;
    _selectionUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _selectionUpdateScheduled = false;
      if (!mounted) return;
      update();
    });
  }

  String _commentsSignature(List<_StageComment> comments) => comments
      .map((entry) {
        final c = entry.comment;
        return '${entry.taskId}-${c.id}-${c.timestamp}-${c.type}-${c.userId}-${c.text}';
      })
      .join('|');

  void _maybeAutoScrollComments(String taskId, List<_StageComment> comments) {
    final signature = _commentsSignature(comments);
    final count = comments.length;

    if (_lastCommentsTaskId != taskId) {
      _lastCommentsTaskId = taskId;
      _lastCommentsSignature = signature;
      _lastCommentsCount = count;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_commentsScrollController.hasClients) return;
        _commentsScrollController.jumpTo(
          _commentsScrollController.position.maxScrollExtent,
        );
      });
      return;
    }

    if (signature == _lastCommentsSignature) return;

    final hasNewComments = count > _lastCommentsCount;
    _lastCommentsSignature = signature;
    _lastCommentsCount = count;

    if (!hasNewComments) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_commentsScrollController.hasClients) return;
      _commentsScrollController.animateTo(
        _commentsScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  void _scheduleTaskRefreshForLaunchedOrders({
    required Iterable<OrderModel> orders,
    required TaskProvider taskProvider,
  }) {
    final launchedOrderIds = orders
        .where((order) =>
            order.assignmentCreated ||
            order.statusEnum == OrderStatus.in_production)
        .map((order) => order.id.trim())
        .where((id) => id.isNotEmpty)
        .toList()
      ..sort();
    final signature = launchedOrderIds.join('|');
    if (_lastLaunchedOrderIdsSignature == signature) return;

    _lastLaunchedOrderIdsSignature = signature;
    if (signature.isEmpty || _taskRefreshAfterLaunchScheduled) return;

    _taskRefreshAfterLaunchScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _taskRefreshAfterLaunchScheduled = false;
        return;
      }
      try {
        await taskProvider.refresh();
      } finally {
        _taskRefreshAfterLaunchScheduled = false;
      }
    });
  }

  String _queueIdsSignature(Iterable<String> ids) {
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

  void _scheduleQueueSyncIfNeeded({
    required ProductionQueueProvider queue,
    required String groupId,
    required Iterable<String> ids,
  }) {
    final nextSignature = _queueIdsSignature(ids);
    if (_lastQueueSyncGroupId == groupId &&
        _lastQueueSyncIdsSignature == nextSignature) {
      return;
    }
    _lastQueueSyncGroupId = groupId;
    _lastQueueSyncIdsSignature = nextSignature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      queue.syncOrders(ids, groupId: groupId);
    });
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

  double? _initialMeterQuantityForTask(TaskModel task, String? unit) {
    return initialTaskMeterQuantityForOrder(
      unit: unit,
      order: _orderById(task.orderId),
    );
  }

  String _queueOrderIdForTask(TaskModel task, OrdersProvider ordersProvider) {
    final rawOrderId = task.orderId.trim();
    if (rawOrderId.isEmpty) return rawOrderId;

    final direct = ordersProvider.orders.any((order) => order.id == rawOrderId);
    if (direct) return rawOrderId;

    for (final order in ordersProvider.orders) {
      final assignmentId = order.assignmentId?.trim() ?? '';
      if (assignmentId.isNotEmpty && assignmentId == rawOrderId) {
        return order.id;
      }
    }
    return rawOrderId;
  }

  String _orderLabelForTask(TaskModel task, OrdersProvider ordersProvider) {
    final queueOrderId = _queueOrderIdForTask(task, ordersProvider);
    final order = ordersProvider.orders.cast<OrderModel?>().firstWhere(
          (candidate) => candidate?.id == queueOrderId,
          orElse: () => null,
        );
    final assignmentId = order?.assignmentId?.trim() ?? '';
    if (assignmentId.isNotEmpty) return assignmentId;
    return queueOrderId;
  }

  TaskModel? _activeTaskForEmployee(TaskProvider taskProvider) {
    final candidates = taskProvider.tasks.where((task) {
      if (!task.assignees.contains(widget.employeeId)) return false;
      if (_isEffectivelyCompleted(task)) return false;
      final state = _userRunState(task, widget.employeeId);
      return state == UserRunState.active;
    }).toList(growable: false);

    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final aStarted = a.startedAt ?? 0;
      final bStarted = b.startedAt ?? 0;
      return bStarted.compareTo(aStarted);
    });
    return candidates.first;
  }

  List<TmcModel> _workspacePaperItems() {
    final warehouse = context.read<WarehouseProvider>();
    bool isPaperType(TmcModel item) {
      final raw = item.type.toLowerCase().trim();
      return raw.contains('paper') || raw.contains('бумаг');
    }

    final papers = warehouse.allTmc.where(isPaperType).toList();
    papers.sort(
      (a, b) {
        final byName =
            a.description.toLowerCase().compareTo(b.description.toLowerCase());
        if (byName != 0) return byName;
        final byFormat =
            (a.format ?? '').toLowerCase().compareTo((b.format ?? '').toLowerCase());
        if (byFormat != 0) return byFormat;
        return (a.grammage ?? '')
            .toLowerCase()
            .compareTo((b.grammage ?? '').toLowerCase());
      },
    );
    return papers;
  }

  Future<List<TmcModel>> _workspacePaperItemsFresh() async {
    final warehouse = context.read<WarehouseProvider>();
    // На первом открытии диалога склад может быть ещё не загружен:
    // выполняем принудительное обновление, чтобы избежать ложного
    // "бумага не найдена" и корректно открыть выбор с первого раза.
    await warehouse.fetchTmc();
    return _workspacePaperItems();
  }

  bool _matchPaperSearch(TmcModel paper, String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return true;
    final searchableParts = [
      paper.description,
      paper.format ?? '',
      paper.grammage ?? '',
      paper.id,
    ];
    final searchable = searchableParts.join(' ').toLowerCase();
    final exactTokens = <String>{};
    final tokenRegex = RegExp(r'[a-zа-яё0-9]+(?:[.,][a-zа-яё0-9]+)?');
    for (final part in searchableParts) {
      for (final match in tokenRegex.allMatches(part.toLowerCase())) {
        exactTokens.add(match.group(0)!.replaceAll(',', '.'));
      }
    }
    final numericTokenRegex = RegExp(r'^\d+(?:[.,]\d+)?$');
    final tokens = normalized
        .split(RegExp(r'[\s,;]+'))
        .where((token) => token.isNotEmpty);
    for (final token in tokens) {
      if (numericTokenRegex.hasMatch(token)) {
        if (!exactTokens.contains(token.replaceAll(',', '.'))) return false;
        continue;
      }
      if (!searchable.contains(token)) return false;
    }
    return true;
  }

  String _paperFormatText(String? format) {
    final value = (format ?? '').trim();
    return value.isEmpty ? '—' : value;
  }

  String _paperGrammageText(String? grammage) {
    final value = (grammage ?? '').trim();
    return value.isEmpty ? '—' : value;
  }

  String? _validatePaperRow({
    required MaterialModel selected,
    required String editedFormat,
    required String editedGrammage,
    required double qty,
    required List<TmcModel> papers,
  }) {
    final selectedId = (selected.id ?? '').trim();
    final matchedById = selectedId.isEmpty
        ? null
        : papers.cast<TmcModel?>().firstWhere(
              (paper) => paper?.id == selectedId,
              orElse: () => null,
            );
    final matchedByName = papers.cast<TmcModel?>().firstWhere(
          (paper) => paper?.description.trim().toLowerCase() ==
              selected.name.trim().toLowerCase(),
          orElse: () => null,
        );
    final matchedPaper = matchedById ?? matchedByName;
    if (matchedPaper == null) {
      return 'Выбранная бумага «${selected.name}» отсутствует на складе.';
    }

    final normalizedEditedFormat = editedFormat.trim();
    final normalizedEditedGrammage = editedGrammage.trim();
    final paperFormat = (matchedPaper.format ?? '').trim();
    final paperGrammage = (matchedPaper.grammage ?? '').trim();

    if (paperFormat.isNotEmpty &&
        normalizedEditedFormat.toLowerCase() != paperFormat.toLowerCase()) {
      return 'Формат для «${matchedPaper.description}» должен быть "$paperFormat".';
    }
    if (paperGrammage.isNotEmpty &&
        normalizedEditedGrammage.toLowerCase() != paperGrammage.toLowerCase()) {
      return 'Грамаж для «${matchedPaper.description}» должен быть "$paperGrammage".';
    }
    if (qty > matchedPaper.quantity) {
      return 'Недостаточно бумаги «${matchedPaper.description}»: '
          'доступно ${matchedPaper.quantity.toStringAsFixed(2)} ${matchedPaper.unit}.';
    }

    return null;
  }

  Future<TmcModel?> _pickPaperForSlot({
    required BuildContext context,
    required List<TmcModel> papers,
  }) async {
    var search = '';
    return showDialog<TmcModel>(
      context: context,
      builder: (pickerContext) {
        return StatefulBuilder(
          builder: (pickerContext, setPickerState) {
            final filtered = papers.where((paper) {
              // В рабочем пространстве разрешаем повторно выбирать ту же бумагу
              // в разных слотах (например, как дополнительную бумагу того же типа).
              // Поэтому intentionally НЕ исключаем уже выбранные id.
              return _matchPaperSearch(paper, search);
            }).toList(growable: false);
            return AlertDialog(
              title: const Text('Выбор бумаги'),
              content: SizedBox(
                width: 540,
                height: 420,
                child: Column(
                  children: [
                    TextFormField(
                      key: ValueKey(search.isEmpty),
                      initialValue: search,
                      decoration: InputDecoration(
                        labelText: 'Поиск бумаги',
                        hintText: 'Наименование, формат, грамаж',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: search.isEmpty
                            ? null
                            : IconButton(
                                onPressed: () {
                                  setPickerState(() {
                                    search = '';
                                  });
                                },
                                icon: const Icon(Icons.clear),
                              ),
                      ),
                      onChanged: (value) =>
                          setPickerState(() => search = value),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: filtered.isEmpty
                          ? const Center(
                              child: Text('Ничего не найдено.'),
                            )
                          : ListView.separated(
                              itemCount: filtered.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, index) {
                                final paper = filtered[index];
                                return ListTile(
                                  title: Text(paper.description),
                                  subtitle: Text(
                                    'Формат: ${_paperFormatText(paper.format)} • '
                                    'Грамаж: ${_paperGrammageText(paper.grammage)}',
                                  ),
                                  onTap: () =>
                                      Navigator.of(pickerContext).pop(paper),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(pickerContext).pop(),
                  child: const Text('Отмена'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _buildWorkspacePaperChangeComment({
    required List<MaterialModel> before,
    required List<MaterialModel> after,
    required String reason,
    double? beforePrimaryWidthB,
    String? beforePrimaryBlQuantity,
    double? afterPrimaryWidthB,
    String? afterPrimaryBlQuantity,
  }) {
    String paperLabel(MaterialModel material) {
      final format = (material.format ?? '').trim();
      final grammage = (material.grammage ?? '').trim();
      final shortMeta = <String>[
        if (format.isNotEmpty) 'Ф $format',
        if (grammage.isNotEmpty) 'Гр $grammage',
      ].join(' / ');
      final parts = <String>[
        material.name.trim().isEmpty ? 'Без названия' : material.name.trim(),
        if (shortMeta.isNotEmpty) shortMeta,
      ];
      return parts.join(', ');
    }

    String paperMetrics(
      MaterialModel material, {
      double? fallbackWidthB,
      String? fallbackBlQuantity,
    }) {
      double? asDouble(dynamic raw) {
        if (raw is num) return raw.toDouble();
        return double.tryParse((raw ?? '').toString().replaceAll(',', '.'));
      }

      final parsedWidthB = asDouble(material.extra?['widthB']) ?? 0;
      final widthB = parsedWidthB > 0 ? parsedWidthB : (fallbackWidthB ?? 0);
      final blQuantity = (material.extra?['blQuantity'] ?? fallbackBlQuantity ?? '')
          .toString()
          .trim();
      final widthText = widthB <= 0
          ? '—'
          : (widthB % 1 == 0 ? widthB.toStringAsFixed(0) : widthB.toStringAsFixed(2));
      final quantityText = blQuantity.isEmpty ? '—' : blQuantity;
      return 'Ш $widthText, К $quantityText, L ${material.quantity.toStringAsFixed(2)} м';
    }

    final lines = <String>[
      'Изменение бумаги из рабочего пространства.',
    ];
    final maxLen = before.length > after.length ? before.length : after.length;
    for (var i = 0; i < maxLen; i++) {
      final oldMaterial = i < before.length ? before[i] : null;
      final newMaterial = i < after.length ? after[i] : null;
      final slot = i + 1;
      if (oldMaterial != null && newMaterial != null) {
        final delta = newMaterial.quantity - oldMaterial.quantity;
        final deltaPrefix = delta >= 0 ? '+' : '';
        lines.add(
          'Бумага №$slot Было: ${paperLabel(oldMaterial)} '
          '${paperMetrics(oldMaterial, fallbackWidthB: i == 0 ? beforePrimaryWidthB : null, fallbackBlQuantity: i == 0 ? beforePrimaryBlQuantity : null)}. '
          'Стало: ${paperLabel(newMaterial)} '
          '${paperMetrics(newMaterial, fallbackWidthB: i == 0 ? afterPrimaryWidthB : null, fallbackBlQuantity: i == 0 ? afterPrimaryBlQuantity : null)}. '
          'Δ $deltaPrefix${delta.toStringAsFixed(2)} м.',
        );
      } else if (oldMaterial == null && newMaterial != null) {
        lines.add(
          'Бумага №$slot Добавлена: ${paperLabel(newMaterial)} '
          '${paperMetrics(newMaterial, fallbackWidthB: i == 0 ? afterPrimaryWidthB : null, fallbackBlQuantity: i == 0 ? afterPrimaryBlQuantity : null)}.',
        );
      } else if (oldMaterial != null && newMaterial == null) {
        lines.add(
          'Бумага №$slot Удалена: ${paperLabel(oldMaterial)} '
          '${paperMetrics(oldMaterial, fallbackWidthB: i == 0 ? beforePrimaryWidthB : null, fallbackBlQuantity: i == 0 ? beforePrimaryBlQuantity : null)}.',
        );
      }
    }
    lines.add('Причина: ${reason.trim()}');
    return lines.join('\n');
  }

  Future<void> _addWorkspacePaperChangeComment({
    required String orderId,
    required String text,
  }) async {
    final taskProvider = context.read<TaskProvider>();
    final candidates = taskProvider.tasks.where((task) => task.orderId == orderId).toList();
    if (candidates.isEmpty) return;
    candidates.sort((a, b) {
      final aPriority = (a.stageId == _selectedWorkplaceId ? 0 : 1) +
          (_isEffectivelyCompleted(a) ? 10 : 0);
      final bPriority = (b.stageId == _selectedWorkplaceId ? 0 : 1) +
          (_isEffectivelyCompleted(b) ? 10 : 0);
      if (aPriority != bPriority) return aPriority.compareTo(bPriority);
      return a.id.compareTo(b.id);
    });
    await taskProvider.addCommentAutoUser(
      taskId: candidates.first.id,
      type: 'paper_change',
      text: text,
      userIdOverride: widget.employeeId,
    );
  }

  Future<void> _openPaperEditDialog(OrderModel baseOrder) async {
    final latest = _orderById(baseOrder.id) ?? baseOrder;
    final currentMaterials = latest.paperMaterials.isNotEmpty
        ? List<MaterialModel>.from(latest.paperMaterials)
        : <MaterialModel>[
            if (latest.material != null) latest.material!,
          ];
    final papers = await _workspacePaperItemsFresh();
    if (!mounted) return;
    if (papers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('На складе не найдено доступной бумаги.')),
      );
      return;
    }

    final selected = currentMaterials.isNotEmpty
        ? currentMaterials.toList()
        : <MaterialModel>[
            MaterialModel(
              id: papers.first.id,
              name: papers.first.description,
              quantity: 0,
              unit: papers.first.unit.isNotEmpty ? papers.first.unit : 'м',
              format: papers.first.format,
              grammage: papers.first.grammage,
              weight: papers.first.weight,
            ),
          ];

    double? paperLengthFromExtra(MaterialModel item) {
      final raw = item.extra?['lengthL'];
      if (raw is num) return raw.toDouble();
      if (raw is String) {
        final normalized = raw.trim().replaceAll(',', '.');
        if (normalized.isEmpty) return null;
        return double.tryParse(normalized);
      }
      return null;
    }

    double initialPaperQty(MaterialModel item, int index) {
      final fromCurrent = item.quantity > 0 ? item.quantity : 0.0;
      final fromExtra = paperLengthFromExtra(item) ?? 0.0;
      final orderLength = (latest.product.length ?? 0).toDouble();

      if (index == 0 && orderLength > 0) return orderLength;
      if (fromExtra > 0) return fromExtra;
      if (fromCurrent > 0) return fromCurrent;
      if (orderLength > 0) return orderLength;
      return 0.0;
    }

    final qtyControllers = <TextEditingController>[
      for (var i = 0; i < selected.length; i++)
        () {
          final qty = initialPaperQty(selected[i], i);
          return TextEditingController(
            text: qty > 0 ? qty.toStringAsFixed(2) : '',
          );
        }(),
    ];
    final formatControllers = <TextEditingController>[
      for (final item in selected)
        TextEditingController(text: _paperFormatText(item.format)),
    ];
    final grammageControllers = <TextEditingController>[
      for (final item in selected)
        TextEditingController(text: _paperGrammageText(item.grammage)),
    ];
    double? paperWidthBFromExtra(MaterialModel item) {
      final raw = item.extra?['widthB'];
      if (raw is num) return raw.toDouble();
      if (raw is String) {
        final normalized = raw.trim().replaceAll(',', '.');
        if (normalized.isEmpty) return null;
        return double.tryParse(normalized);
      }
      return null;
    }

    String? paperBlQuantityFromExtra(MaterialModel item) {
      final value = item.extra?['blQuantity'];
      final text = value?.toString().trim() ?? '';
      return text.isEmpty ? null : text;
    }

    String _formatEditableDouble(double value) {
      if (value <= 0) return '';
      return value % 1 == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(2);
    }

    final reasonController = TextEditingController();
    final widthBControllers = <TextEditingController>[
      for (var i = 0; i < selected.length; i++)
        () {
          final widthB = i == 0
              ? (latest.product.widthB ?? 0)
              : (paperWidthBFromExtra(selected[i]) ?? 0);
          return TextEditingController(text: _formatEditableDouble(widthB));
        }(),
    ];
    final blQuantityControllers = <TextEditingController>[
      for (var i = 0; i < selected.length; i++)
        TextEditingController(
          text: i == 0
              ? (latest.product.blQuantity?.trim() ?? '')
              : (paperBlQuantityFromExtra(selected[i]) ?? ''),
        ),
    ];
    final formKey = GlobalKey<FormState>();
    String? errorText;
    bool saving = false;

    Future<void> addSlot(StateSetter setDialogState) async {
      final pick = papers.first;
      setDialogState(() {
        selected.add(MaterialModel(
          id: pick.id,
          name: pick.description,
          quantity: 0,
          unit: pick.unit.isNotEmpty ? pick.unit : 'м',
          format: pick.format,
          grammage: pick.grammage,
          weight: pick.weight,
        ));
        qtyControllers.add(TextEditingController());
        formatControllers.add(
          TextEditingController(text: _paperFormatText(pick.format)),
        );
        grammageControllers.add(
          TextEditingController(text: _paperGrammageText(pick.grammage)),
        );
        widthBControllers.add(TextEditingController());
        blQuantityControllers.add(TextEditingController());
      });
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              title: const Text('Изменение бумаги в заказе'),
              content: SizedBox(
                width: 560,
                child: SingleChildScrollView(
                  child: Form(
                    key: formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < selected.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: 2,
                                  child: InkWell(
                                    onTap: saving
                                        ? null
                                        : () async {
                                            final paper =
                                                await _pickPaperForSlot(
                                              context: dialogContext,
                                              papers: papers,
                                            );
                                            if (paper == null) return;
                                            setDialogState(() {
                                              selected[i] =
                                                  selected[i].copyWith(
                                                id: paper.id,
                                                name: paper.description,
                                                unit: paper.unit.isNotEmpty
                                                    ? paper.unit
                                                    : 'м',
                                                format: paper.format,
                                                grammage: paper.grammage,
                                                weight: paper.weight,
                                              );
                                              formatControllers[i].text =
                                                  _paperFormatText(paper.format);
                                              grammageControllers[i].text =
                                                  _paperGrammageText(
                                                    paper.grammage,
                                                  );
                                            });
                                          },
                                    child: InputDecorator(
                                      decoration: InputDecoration(
                                        labelText: 'Бумага №${i + 1}',
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              (selected[i].name).trim().isEmpty
                                                  ? 'Выберите бумагу'
                                                  : selected[i].name,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          const Icon(Icons.arrow_drop_down),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: TextFormField(
                                    controller: formatControllers[i],
                                    decoration: const InputDecoration(
                                      labelText: 'Формат',
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: TextFormField(
                                    controller: grammageControllers[i],
                                    decoration: const InputDecoration(
                                      labelText: 'Грамаж',
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: TextFormField(
                                    controller: widthBControllers[i],
                                    keyboardType: const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                    decoration: const InputDecoration(
                                      labelText: 'Ширина b',
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: TextFormField(
                                    controller: blQuantityControllers[i],
                                    decoration: const InputDecoration(
                                      labelText: 'Количество бумаги',
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: TextFormField(
                                    controller: qtyControllers[i],
                                    keyboardType: const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                    decoration: const InputDecoration(
                                      labelText: 'Длина L (м)',
                                    ),
                                    validator: (value) {
                                      final normalized =
                                          (value ?? '').trim().replaceAll(',', '.');
                                      final qty = double.tryParse(normalized);
                                      if (qty == null || qty <= 0) {
                                        return 'Введите > 0';
                                      }
                                      return null;
                                    },
                                  ),
                                ),
                                if (i > 0)
                                  IconButton(
                                    tooltip: 'Удалить бумагу',
                                    onPressed: () {
                                      final removedQtyController =
                                          qtyControllers[i];
                                      final removedFormatController =
                                          formatControllers[i];
                                      final removedGrammageController =
                                          grammageControllers[i];
                                      final removedWidthBController =
                                          widthBControllers[i];
                                      final removedBlQuantityController =
                                          blQuantityControllers[i];
                                      setDialogState(() {
                                        selected.removeAt(i);
                                        qtyControllers.removeAt(i);
                                        formatControllers.removeAt(i);
                                        grammageControllers.removeAt(i);
                                        widthBControllers.removeAt(i);
                                        blQuantityControllers.removeAt(i);
                                      });
                                      WidgetsBinding.instance
                                          .addPostFrameCallback((_) {
                                        removedQtyController.dispose();
                                        removedFormatController.dispose();
                                        removedGrammageController.dispose();
                                        removedWidthBController.dispose();
                                        removedBlQuantityController.dispose();
                                      });
                                    },
                                    icon: const Icon(Icons.delete_outline),
                                  ),
                              ],
                            ),
                          ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: saving
                                ? null
                                : () => addSlot(setDialogState),
                            icon: const Icon(Icons.add),
                            label: const Text('Добавить бумагу'),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: reasonController,
                          maxLines: 3,
                          decoration: const InputDecoration(
                            labelText: 'Причина изменения',
                            hintText: 'Без причины сохранить нельзя',
                          ),
                          validator: (value) => (value ?? '').trim().isEmpty
                              ? 'Укажите причину изменения'
                              : null,
                        ),
                        if (errorText != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            errorText!,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.of(dialogContext).pop(),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: saving
                      ? null
                      : () async {
                          if (!formKey.currentState!.validate()) return;
                          setDialogState(() {
                            saving = true;
                            errorText = null;
                          });
                          final nextMaterials = <MaterialModel>[];
                          double? nextLengthL;
                          double? primaryWidthB;
                          String? primaryBlQuantity;
                          for (var i = 0; i < selected.length; i++) {
                            final qty = double.parse(
                              qtyControllers[i].text.trim().replaceAll(',', '.'),
                            );
                            final editedFormat =
                                formatControllers[i].text.trim();
                            final editedGrammage =
                                grammageControllers[i].text.trim();
                            final rowValidationError = _validatePaperRow(
                              selected: selected[i],
                              editedFormat: editedFormat,
                              editedGrammage: editedGrammage,
                              qty: qty,
                              papers: papers,
                            );
                            if (rowValidationError != null) {
                              setDialogState(() {
                                saving = false;
                                errorText = rowValidationError;
                              });
                              return;
                            }
                            final parsedWidthB = double.tryParse(
                              widthBControllers[i].text.trim().replaceAll(',', '.'),
                            );
                            final parsedBlQuantity =
                                blQuantityControllers[i].text.trim();
                            final nextExtra = Map<String, dynamic>.from(
                              selected[i].extra ?? const {},
                            );
                            if (parsedWidthB == null || parsedWidthB <= 0) {
                              nextExtra.remove('widthB');
                            } else {
                              nextExtra['widthB'] = parsedWidthB;
                            }
                            if (parsedBlQuantity.isEmpty) {
                              nextExtra.remove('blQuantity');
                            } else {
                              nextExtra['blQuantity'] = parsedBlQuantity;
                            }
                            if (qty <= 0) {
                              nextExtra.remove('lengthL');
                            } else {
                              nextExtra['lengthL'] = qty;
                            }
                            nextLengthL ??= qty;
                            if (i == 0) {
                              primaryWidthB = parsedWidthB;
                              primaryBlQuantity = parsedBlQuantity.isEmpty
                                  ? null
                                  : parsedBlQuantity;
                            }
                            nextMaterials.add(
                              selected[i].copyWith(
                                quantity: qty,
                                format: editedFormat,
                                grammage: editedGrammage,
                                extra: nextExtra.isEmpty ? null : nextExtra,
                              ),
                            );
                          }

                          final orders = context.read<OrdersProvider>();
                          final nextWidth = latest.product.width;
                          final nextQuantity = latest.product.quantity;
                          // Бизнес-логика рабочего пространства: изменение бумаги
                          // обязательно сопровождается причиной и сразу
                          // синхронизируется с заказом/управлением/резервом.
                          final error = await orders.updateOrderPapersFromWorkspace(
                            orderId: latest.id,
                            paperMaterials: nextMaterials,
                            reason: reasonController.text,
                            lengthL: nextLengthL,
                            width: nextWidth,
                            quantity: nextQuantity,
                            widthB: primaryWidthB,
                            blQuantity: primaryBlQuantity,
                          );
                          if (!mounted) return;
                          if (error != null) {
                            setDialogState(() {
                              saving = false;
                              errorText = error;
                            });
                            return;
                          }
                          final paperComment = _buildWorkspacePaperChangeComment(
                            before: currentMaterials,
                            after: nextMaterials,
                            reason: reasonController.text,
                            beforePrimaryWidthB: latest.product.widthB,
                            beforePrimaryBlQuantity: latest.product.blQuantity,
                            afterPrimaryWidthB: primaryWidthB ?? latest.product.widthB,
                            afterPrimaryBlQuantity:
                                primaryBlQuantity ?? latest.product.blQuantity,
                          );
                          await _addWorkspacePaperChangeComment(
                            orderId: latest.id,
                            text: paperComment,
                          );
                          Navigator.of(dialogContext).pop();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Бумага успешно обновлена.'),
                            ),
                          );
                        },
                  child: Text(saving ? 'Сохранение...' : 'Сохранить'),
                ),
              ],
            );
          },
        );
      },
    );

    for (final controller in qtyControllers) {
      controller.dispose();
    }
    for (final controller in formatControllers) {
      controller.dispose();
    }
    for (final controller in grammageControllers) {
      controller.dispose();
    }
    for (final controller in widthBControllers) {
      controller.dispose();
    }
    for (final controller in blQuantityControllers) {
      controller.dispose();
    }
    reasonController.dispose();
  }

  List<String> _stageGroupMembers(String orderId, String stageId) {
    final taskProvider = Provider.of<TaskProvider?>(context, listen: false);
    final savedMembers =
        taskProvider?.stageGroupMembersForOrder(orderId, stageId);
    if (savedMembers != null && savedMembers.isNotEmpty) {
      return savedMembers;
    }

    // Template-derived grouping is intentionally centralized in TaskProvider via
    // OrderQueueService and is only allowed as a legacy fallback there.
    return [stageId];
  }

  String _stageGroupKey(String orderId, String stageId) {
    final taskProvider = Provider.of<TaskProvider?>(context, listen: false);
    final savedKey = taskProvider?.stageGroupMapForOrder(orderId)?[stageId.trim()]
        ?.trim();
    if (savedKey != null && savedKey.isNotEmpty) return savedKey;
    return _stageGroupMembers(orderId, stageId).join('|');
  }

  bool _isStageGroupLocked(TaskProvider provider, TaskModel task) {
    final groupMembers = _stageGroupMembers(task.orderId, task.stageId);
    // Блокируем только альтернативные группы (2+ различных этапа).
    final hasAlternatives = groupMembers.toSet().length > 1;
    if (!hasAlternatives) return false;

    final related = provider.tasks.where((t) =>
        t.orderId == task.orderId && groupMembers.contains(t.stageId));
    final capturedWorkplace = related
        .map((t) => t.capturedByWorkplaceId?.trim() ?? '')
        .firstWhere((id) => id.isNotEmpty, orElse: () => '');
    if (capturedWorkplace.isNotEmpty && capturedWorkplace != task.stageId) {
      // Этап уже захвачен другим рабочим местом — блокируем управление.
      return true;
    }

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
      case 'setup_resume':
        return 'Продолжил(а) наладку';
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
      case 'helper_removed':
        return comment.text.isNotEmpty ? comment.text : 'Помощник удалён с этапа';
      case 'helper_removed_qty':
        return comment.text.isNotEmpty
            ? 'Количество удалённого помощника: ${comment.text}'
            : 'Количество удалённого помощника зафиксировано';
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
      case 'shift_pause_state':
        return 'Состояние для пересмены сохранено';
      case 'ink_writeoff':
        return comment.text.isNotEmpty
            ? comment.text
            : 'Зафиксировано списание краски';
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
    return TaskStatus.inProgress;
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

    final orderIds =
        ordersProvider.orders.map((o) => o.id).toList(growable: false);
    _scheduleTaskRefreshForLaunchedOrders(
      orders: ordersProvider.orders,
      taskProvider: taskProvider,
    );

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
    final double baseLayoutScale = isTablet1280x800
        ? 0.78 // планшеты 1280x800 — уменьшаем элементы под макет
        : (isTablet1000x700
            ? 0.72 // планшеты 1000x700 — уменьшаем элементы под макет
            : (isCompactTablet
                ? 0.88 // компактные планшеты — ещё аккуратнее базового масштаба
                : (isTablet
                    ? 1.0 // обычные планшеты — без увеличения
                    : 1.08))); // десктопы/веб — умеренное увеличение
    final double layoutScale = baseLayoutScale * 0.7;

    // Поддерживаем читаемость текста, но без лишнего укрупнения на
    // маленьких планшетах.
    final double textScaleFactor = isTablet1280x800
        ? media.textScaleFactor * 0.98
        : (isTablet1000x700
            ? media.textScaleFactor * 0.94
            : math.max(
                media.textScaleFactor,
                isCompactTablet
                    ? 1.03
                    : (isTablet
                        ? 1.1
                        : 1.18),
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

    final hasValidSelectedWorkplace = _selectedWorkplaceId != null &&
        workplaces.any((w) => w.id == _selectedWorkplaceId);

    if (!hasValidSelectedWorkplace && workplaces.isNotEmpty) {
      final desiredWorkplaceId =
          savedWid?.trim().isNotEmpty == true &&
                  workplaces.any((w) => w.id == savedWid)
              ? savedWid!.trim()
              : workplaces.first.id.trim();
      _scheduleSelectionUpdate(() {
        final stillValid = _selectedWorkplaceId != null &&
            workplaces.any((w) => w.id == _selectedWorkplaceId);
        if (stillValid) return;
        _selection.workplaceId = desiredWorkplaceId;
        _persistWorkplace(desiredWorkplaceId);
        _selection.notifyListeners();
      });
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

    final tasksForWorkplace = _tasksForWorkplace(taskProvider);

    if (_selectedTask == null && savedTid != null) {
      TaskModel? restoredTask;
      try {
        restoredTask = tasksForWorkplace.firstWhere((t) => t.id == savedTid);
      } catch (_) {}
      if (restoredTask != null) {
        _scheduleSelectionUpdate(() {
          if (_selectedTask != null) return;
          _selection.task = restoredTask;
          _selection.status = _sectionForTask(restoredTask!);
          _persistTask(restoredTask!.id);
          _selection.notifyListeners();
        });
      }
    } else if (_selectedWorkplaceId != null &&
        _selectedTask != null &&
        !tasksForWorkplace.any((t) => t.id == _selectedTask!.id)) {
      _scheduleSelectionUpdate(() {
        if (_selectedTask == null) return;
        _selection.task = null;
        _persistTask(null);
        _selection.notifyListeners();
      });
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
        : taskProvider.tasks
            .where((t) => t.stageId == _selectedWorkplaceId)
            .where((task) => isTaskOrderLaunchedForWorkspace(
                  findOrder(task.orderId),
                ))
            .toList();
    final stageQueueIds = stageTasksAll
        .map((task) => _queueOrderIdForTask(task, ordersProvider))
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();

    _scheduleQueueSyncIfNeeded(
      queue: queue,
      groupId: queueGroupId,
      ids: _selectedWorkplaceId == null ? orderIds : stageQueueIds,
    );

    final sectionedTasks = tasksForWorkplace.toList();
    sectionedTasks.sort((a, b) =>
        queue
            .priorityOf(
              _queueOrderIdForTask(a, ordersProvider),
              groupId: queueGroupId,
            )
            .compareTo(queue.priorityOf(
                  _queueOrderIdForTask(b, ordersProvider),
                  groupId: queueGroupId,
                )));
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
    final activeTask = _activeTaskForEmployee(taskProvider);

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
        final uniqueWorkplacesById = <String, WorkplaceModel>{
          for (final workplace in workplaces) workplace.id: workplace,
        };
        final uniqueWorkplaces = uniqueWorkplacesById.values.toList(growable: false);
        final selectedWorkplaceId = uniqueWorkplacesById.containsKey(_selectedWorkplaceId)
            ? _selectedWorkplaceId
            : null;

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
                value: selectedWorkplaceId,
                isDense: true,
                isExpanded: true,
                style: TextStyle(fontSize: scaled(12.5), color: Colors.black87),
                itemHeight: math.max(
                  scaled(48),
                  kMinInteractiveDimension,
                ),
                items: [
                  for (final w in uniqueWorkplaces)
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
                  for (final w in uniqueWorkplaces)
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

      Widget buildActiveTaskShortcut() {
        if (activeTask == null) return const SizedBox.shrink();

        final workplace = personnel.workplaceById(activeTask.stageId);
        final workplaceName = workplace?.name.trim().isNotEmpty == true
            ? workplace!.name.trim()
            : activeTask.stageId;
        final orderLabel = _orderLabelForTask(activeTask, ordersProvider);

        return Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () {
              _persistWorkplace(activeTask.stageId);
              _persistTask(activeTask.id);
              setState(() {
                _selectedWorkplaceId = activeTask.stageId;
                _selectedTask = activeTask;
                _selectedStatus = _sectionForTask(activeTask);
              });
            },
            child: Text(
              '↩ $workplaceName · заказ $orderLabel',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: scaled(11.5),
                fontWeight: FontWeight.w600,
              ),
            ),
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
          if (activeTask != null) ...[
            SizedBox(height: smallSpacing),
            buildActiveTaskShortcut(),
          ],
          SizedBox(height: sectionSpacing * 0.6),
          SizedBox(height: sectionSpacing),
          if (sectionedTasks.isEmpty)
            const Center(
              child: Text(
                'Нет доступных заданий для этого рабочего места',
                textAlign: TextAlign.center,
              ),
            )
          else
            ListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (int i = 0; i < sectionedTasks.length; i++)
                  Builder(builder: (context) {
                    final task = sectionedTasks[i];
                    final workplace = personnel.workplaceById(task.stageId);
                    final unlockedByQueue = _isUnlockedByWorkplaceQueue(
                      task,
                      taskProvider,
                      queue,
                      workplace,
                    );
                    final readyForStage = task.status == TaskStatus.waiting &&
                        unlockedByQueue &&
                        _isFirstPendingStage(
                          taskProvider,
                          personnel,
                          task,
                          groupResolver: _stageGroupKey,
                        );
                    const canOpen = true;
                    return _TaskCard(
                      task: task,
                      order: findOrder(task.orderId),
                      readyForStage: readyForStage,
                      shiftPaused: _isShiftPausedForStage(taskProvider, task),
                      selected: _selectedTask?.id == task.id,
                      scale: scale,
                      compact: isCompactTablet || widget.compactList,
                      showStageHint: task.status == TaskStatus.waiting,
                      sequenceNumber: i + 1,
                      enabled: canOpen,
                      onTap: () {
                        if (!canOpen) return;
                        _persistTask(task.id);
                        setState(() {
                          _selectedTask = task;
                          _selectedStatus = _sectionForTask(task);
                        });
                        DefaultTabController.of(context)?.animateTo(1);
                      },
                    );
                  }),
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
        ],
      );
    }

    Widget buildRightPanel({required bool scrollable}) {
      final Widget content = buildDetailsPanel();

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
            final bool isNarrow = constraints.maxWidth < (isTablet ? 700 : 1000);
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

            final Widget rightPanel = buildRightPanel(scrollable: true);

            if (widget.showListOnly && showList) {
              return SingleChildScrollView(
                padding: EdgeInsets.all(outerPadding),
                child: leftPanel,
              );
            }

            if (showList && showDetails) {
              if (!isNarrow) {
                const int leftPanelFlex = 8;
                const int rightPanelFlex = 24;
                return Padding(
                  padding: EdgeInsets.all(outerPadding),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: leftPanelFlex,
                        child: leftPanel,
                      ),
                      SizedBox(width: columnGap),
                      Expanded(
                        flex: rightPanelFlex,
                        child: rightPanel,
                      ),
                    ],
                  ),
                );
              }

              return LayoutBuilder(
                builder: (context, scrollConstraints) {
                  const double minLeftPanelWidth = 320;
                  const double minRightPanelWidth = 640;
                  final double totalMinWidth =
                      minLeftPanelWidth + columnGap + minRightPanelWidth;
                  final double contentWidth = math.max(
                    scrollConstraints.maxWidth,
                    totalMinWidth,
                  );
                  final double rightPanelWidth =
                      contentWidth - minLeftPanelWidth - columnGap;
                  return SingleChildScrollView(
                    padding: EdgeInsets.all(outerPadding),
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: contentWidth,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: minLeftPanelWidth,
                            child: leftPanel,
                          ),
                          SizedBox(width: columnGap),
                          SizedBox(
                            width: rightPanelWidth,
                            height: scrollConstraints.maxHeight,
                            child: rightPanel,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            }

            if (showList) {
              return SingleChildScrollView(
                padding: EdgeInsets.all(outerPadding),
                child: leftPanel,
              );
            }

            final Widget detailsPanel = buildDetailsPanel();
            final Widget controlCommentsPanel = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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

            if (!isNarrow) {
              const int detailsPanelFlex = 1;
              const int controlPanelFlex = 1;
              return SingleChildScrollView(
                padding: EdgeInsets.all(outerPadding),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: detailsPanelFlex,
                      child: detailsPanel,
                    ),
                    SizedBox(width: columnGap),
                    Expanded(
                      flex: controlPanelFlex,
                      child: controlCommentsPanel,
                    ),
                  ],
                ),
              );
            }

            return LayoutBuilder(
              builder: (context, scrollConstraints) {
                const double minDetailsPanelWidth = 560;
                const double minControlPanelWidth = 560;
                final double totalMinWidth =
                    minDetailsPanelWidth + columnGap + minControlPanelWidth;
                final double contentWidth = math.max(
                  scrollConstraints.maxWidth,
                  totalMinWidth,
                );
                final double controlPanelWidth =
                    contentWidth - minDetailsPanelWidth - columnGap;
                return SingleChildScrollView(
                  padding: EdgeInsets.all(outerPadding),
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: contentWidth,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: minDetailsPanelWidth,
                          height: scrollConstraints.maxHeight,
                          child: SingleChildScrollView(
                              child: detailsPanel),
                        ),
                        SizedBox(width: columnGap),
                        SizedBox(
                          width: controlPanelWidth,
                          height: scrollConstraints.maxHeight,
                          child:
                              SingleChildScrollView(child: controlCommentsPanel),
                        ),
                      ],
                    ),
                  ),
                );
              },
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
      width: double.infinity,
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
    final totalFromFormula = RegExp(r'=\s*(\d+)').firstMatch(text);
    if (totalFromFormula != null) {
      return int.tryParse(totalFromFormula.group(1) ?? '') ?? 0;
    }
    final packMatch =
        RegExp(r'(\d+)\s*пач', caseSensitive: false).firstMatch(text);
    final inPackMatch = RegExp(r'[x×*]\s*(\d+)').firstMatch(text);
    if (packMatch != null && inPackMatch != null) {
      final packs = int.tryParse(packMatch.group(1) ?? '') ?? 0;
      final inPack = int.tryParse(inPackMatch.group(1) ?? '') ?? 0;
      return packs * inPack;
    }
    final match = RegExp(r'(\d+)').firstMatch(text);
    if (match == null) return 0;
    return int.tryParse(match.group(1) ?? '') ?? 0;
  }

  int _sumQuantities(TaskModel task) {
    int total = 0;
    for (final comment in task.comments) {
      if (comment.type == 'quantity_done' ||
          comment.type == 'quantity_team_total') {
        total += _parseQuantity(comment.text);
      }
    }
    return total;
  }

  String _latestQuantityLabel(TaskModel task) {
    final items = task.comments
        .where((c) =>
            c.type == 'quantity_done' || c.type == 'quantity_team_total')
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


  bool get _shouldUseFilePickerForMedia =>
      AttachmentService.shouldUseFilePickerForMedia;

  Future<void> _pickCommentAttachment({
    required String source,
    required void Function(void Function()) updateDialogState,
  }) async {
    try {
      final draft = await AttachmentService().pickAttachmentDraft(source: source);
      if (draft == null) return;
      updateDialogState(() => _pendingCommentAttachments.add(draft));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось добавить вложение: $error')),
      );
    }
  }

  Widget _attachmentActionButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    required double scale,
  }) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: scale * 18),
    );
  }

  Widget _pendingAttachmentsPreview(
    double scale, {
    required void Function(void Function()) updateDialogState,
  }) {
    if (_pendingCommentAttachments.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: scale * 6,
      runSpacing: scale * 6,
      children: [
        for (var i = 0; i < _pendingCommentAttachments.length; i++)
          Chip(
            avatar: Icon(
              _iconForAttachmentType(_fileTypeFromMime(_pendingCommentAttachments[i].mimeType)),
              size: scale * 16,
            ),
            label: Text(
              _pendingCommentAttachments[i].fileName,
              overflow: TextOverflow.ellipsis,
            ),
            onDeleted: () => updateDialogState(
              () => _pendingCommentAttachments.removeAt(i),
            ),
          ),
      ],
    );
  }

  String _fileTypeFromMime(String mimeType) {
    final value = mimeType.toLowerCase();
    if (value.startsWith('image/')) return 'image';
    if (value.startsWith('video/')) return 'video';
    if (value.startsWith('audio/')) return 'audio';
    return 'file';
  }

  IconData _iconForAttachmentType(String fileType) {
    switch (fileType) {
      case 'image':
        return Icons.image_outlined;
      case 'video':
        return Icons.videocam_outlined;
      case 'audio':
        return Icons.audiotrack_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  Future<void> _openAttachment(TaskCommentAttachment attachment) async {
    final url = (attachment.fileUrl ?? '').trim();
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (!kIsWeb && uri.scheme == 'file') {
      await OpenFilex.open(uri.toFilePath());
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Widget _attachmentTile(TaskCommentAttachment attachment, double scale) {
    final isImage = attachment.fileType == 'image' &&
        (attachment.fileUrl ?? '').trim().isNotEmpty;
    return InkWell(
      onTap: () => _openAttachment(attachment),
      child: Container(
        width: scale * 112,
        padding: EdgeInsets.all(scale * 6),
        decoration: BoxDecoration(
          color: const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(scale * 10),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isImage)
              ClipRRect(
                borderRadius: BorderRadius.circular(scale * 8),
                child: Image.network(
                  attachment.fileUrl!,
                  width: double.infinity,
                  height: scale * 68,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Icon(
                    _iconForAttachmentType(attachment.fileType),
                    size: scale * 34,
                  ),
                ),
              )
            else
              Icon(
                _iconForAttachmentType(attachment.fileType),
                size: scale * 34,
                color: const Color(0xFF374151),
              ),
            SizedBox(height: scale * 4),
            Text(
              attachment.fileName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: scale * 10.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCommentsPanel(TaskModel task, double scale) {
    final isAssignee = task.assignees.contains(widget.employeeId) ||
        task.assignees.isEmpty;
    final personnel = context.watch<PersonnelProvider>();
    final taskProvider = context.watch<TaskProvider>();
    final aggregated = _collectOrderComments(taskProvider, task);
    Future.microtask(
      () => taskProvider.loadAttachmentsForComments(
        aggregated.map((entry) => entry.comment.id),
      ),
    );
    _maybeAutoScrollComments(task.id, aggregated);

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
                    return Icon(icon, size: scale * 16, color: color);
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
                                style: TextStyle(
                                  fontSize: scale * 9.5,
                                  color: Colors.grey,
                                ),
                              ),
                            Text(
                              _describeComment(entry.comment),
                              style: TextStyle(fontSize: scale * 12.5),
                            ),
                            Builder(builder: (_) {
                              final attachments = taskProvider
                                  .attachmentsForComment(entry.comment.id);
                              if (attachments.isEmpty) {
                                return const SizedBox.shrink();
                              }
                              return Padding(
                                padding: EdgeInsets.only(top: scale * 6),
                                child: Wrap(
                                  spacing: scale * 6,
                                  runSpacing: scale * 6,
                                  children: [
                                    for (final attachment in attachments)
                                      _attachmentTile(attachment, scale),
                                  ],
                                ),
                              );
                            }),
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
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: scale * 220),
            child: Scrollbar(
              controller: _commentsScrollController,
              thumbVisibility: aggregated.length > 4,
              child: SingleChildScrollView(
                controller: _commentsScrollController,
                child: commentList(),
              ),
            ),
          ),
          SizedBox(height: scale * 6),
          if (_pendingCommentAttachments.isNotEmpty) ...[
            _pendingAttachmentsPreview(scale, updateDialogState: setState),
            SizedBox(height: scale * 6),
          ],
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _chatController,
                  maxLines: 1,
                  readOnly: !isAssignee,
                  style: TextStyle(fontSize: scale * 12.5),
                  decoration: InputDecoration(
                    hintText: 'Написать комментарий…',
                    hintStyle: TextStyle(fontSize: scale * 12.5),
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
              SizedBox(width: scale * 4),
              _attachmentActionButton(
                icon: Icons.photo_outlined,
                tooltip: 'Фото',
                scale: scale,
                onPressed: isAssignee
                    ? () => _pickCommentAttachment(
                          source: 'photo',
                          updateDialogState: setState,
                        )
                    : null,
              ),
              _attachmentActionButton(
                icon: Icons.videocam_outlined,
                tooltip: 'Видео',
                scale: scale,
                onPressed: isAssignee
                    ? () => _pickCommentAttachment(
                          source: 'video',
                          updateDialogState: setState,
                        )
                    : null,
              ),
              _attachmentActionButton(
                icon: Icons.photo_camera_outlined,
                tooltip: _shouldUseFilePickerForMedia ? 'Файл' : 'Камера',
                scale: scale,
                onPressed: isAssignee
                    ? () => _pickCommentAttachment(
                          source: 'camera',
                          updateDialogState: setState,
                        )
                    : null,
              ),
              _attachmentActionButton(
                icon: Icons.attach_file,
                tooltip: 'Файл',
                scale: scale,
                onPressed: isAssignee
                    ? () => _pickCommentAttachment(
                          source: 'file',
                          updateDialogState: setState,
                        )
                    : null,
              ),
              SizedBox(width: scale * 4),
              InkResponse(
                onTap: isAssignee
                    ? () async {
                        final txt = _chatController.text.trim();
                        final attachments = List<AttachmentDraft>.from(
                          _pendingCommentAttachments,
                        );
                        if (txt.isEmpty && attachments.isEmpty) return;
                        await context.read<TaskProvider>().createCommentWithAttachments(
                              taskId: task.id,
                              type: 'msg',
                              text: txt.isEmpty ? 'Вложение' : txt,
                              userId: widget.employeeId,
                              attachments: attachments,
                            );
                        _chatController.clear();
                        setState(() => _pendingCommentAttachments.clear());
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
                  child: Icon(Icons.send, color: Colors.white, size: scale * 18),
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
        Center(
          child: Text(
            'История пока пуста',
            style: TextStyle(fontSize: scale * 12),
          ),
        ),
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

  Widget _buildDetailsPanel(OrderModel order, WorkplaceModel _,
      List<TemplateModel> templates, double scale) {
    final templateName = (order.stageTemplateId != null &&
            order.stageTemplateId!.isNotEmpty)
        ? _resolveTemplateName(order.stageTemplateId, templates)
        : null;

    final cachedFormImageUrl = _formImageCache[order.id]?.url;

    return Container(
      padding: EdgeInsets.all(10 * scale),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10 * scale),
        border: Border.all(color: const Color(0xFFE6E7EC)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          )
        ],
      ),
      child: FutureBuilder<List<dynamic>>(
        future: Future.wait<dynamic>([
          _getFormImageFuture(order),
          _getOrderPaintsFuture(order.id),
          _getOrderFilesFuture(order.id),
        ]),
        initialData: <dynamic>[
          cachedFormImageUrl,
          _orderPaintsCache[order.id] ?? const <Map<String, dynamic>>[],
          _orderFilesCache[order.id] ?? const <Map<String, dynamic>>[],
        ],
        builder: (context, snapshot) {
          final data = snapshot.data;
          final resolvedFormImageUrl =
              (data != null && data.isNotEmpty ? data[0] as String? : null) ??
                  cachedFormImageUrl;
          final resolvedFormDetails = _formImageCache[order.id]?.details;
          final resolvedPaints =
              (data != null && data.length > 1
                      ? data[1] as List<Map<String, dynamic>>
                      : null) ??
                  (_orderPaintsCache[order.id] ?? const <Map<String, dynamic>>[]);
          final resolvedFiles =
              (data != null && data.length > 2
                      ? data[2] as List<Map<String, dynamic>>
                      : null) ??
                  (_orderFilesCache[order.id] ?? const <Map<String, dynamic>>[]);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OrderDetailsCard(
                order: order,
                paints: resolvedPaints,
                files: resolvedFiles,
                stageTemplateName: templateName,
                formImageUrl: resolvedFormImageUrl,
                formDetails: resolvedFormDetails,
                extraSections: [
                  _buildStageList(order, scale),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Future<List<Map<String, dynamic>>> _getOrderPaintsFuture(String orderId) {
    final normalizedOrderId = orderId.trim();
    if (normalizedOrderId.isEmpty) {
      return Future.value(const <Map<String, dynamic>>[]);
    }

    final pending = _orderPaintsPending[normalizedOrderId];
    if (pending != null) {
      return pending;
    }

    final future = OrdersRepository().getPaints(normalizedOrderId).then((paints) {
      final normalizedPaints = List<Map<String, dynamic>>.from(paints);
      _orderPaintsCache[normalizedOrderId] = normalizedPaints;
      return normalizedPaints;
    }).catchError((_) {
      return _orderPaintsCache[normalizedOrderId] ?? const <Map<String, dynamic>>[];
    }).whenComplete(() {
      _orderPaintsPending.remove(normalizedOrderId);
    });

    _orderPaintsPending[normalizedOrderId] = future;
    return future;
  }

  Future<List<Map<String, dynamic>>> _getOrderFilesFuture(String orderId) {
    final normalizedOrderId = orderId.trim();
    if (normalizedOrderId.isEmpty) {
      return Future.value(const <Map<String, dynamic>>[]);
    }

    final pending = _orderFilesPending[normalizedOrderId];
    if (pending != null) {
      return pending;
    }

    final future = listOrderFiles(normalizedOrderId)
        .then((files) {
          final normalizedFiles = List<Map<String, dynamic>>.from(files);
          _orderFilesCache[normalizedOrderId] = normalizedFiles;
          return normalizedFiles;
        })
        .catchError((_) {
          return _orderFilesCache[normalizedOrderId] ??
              const <Map<String, dynamic>>[];
        })
        .whenComplete(() {
          _orderFilesPending.remove(normalizedOrderId);
        });

    _orderFilesPending[normalizedOrderId] = future;
    return future;
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
      final key = _stageGroupKey(order.id, stageId);
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
          personnel,
          templates,
          ordersProvider,
          taskProvider,
          order.id,
          repId,
        ).toLowerCase();
      }

      orderedGroupKeys.sort(
        (a, b) => labelForKey(a).compareTo(labelForKey(b)),
      );
    }

    // Некоторые источники плана этапов возвращают дублированную
    // "зеркальную" последовательность (A→B→C→C→B→A). Для отображения
    // оставляем только исходный прямой проход.
    if (orderedGroupKeys.length >= 4 && orderedGroupKeys.length.isEven) {
      final half = orderedGroupKeys.length ~/ 2;
      var isMirroredDuplicate = true;
      for (var i = 0; i < half; i++) {
        final mirroredIndex = orderedGroupKeys.length - 1 - i;
        if (orderedGroupKeys[i] != orderedGroupKeys[mirroredIndex]) {
          isMirroredDuplicate = false;
          break;
        }
      }
      if (isMirroredDuplicate) {
        orderedGroupKeys.removeRange(half, orderedGroupKeys.length);
      }
    }

    final deduplicatedGroupKeys = <String>[];
    final seenLabels = <String>{};
    for (final key in orderedGroupKeys) {
      final repId = groupRepresentative[key] ?? key.split('|').first;
      final label = _stageLabelForOrder(
        personnel,
        templates,
        ordersProvider,
        taskProvider,
        order.id,
        repId,
      ).trim();
      final labelKey = label.toLowerCase();

      if (labelKey.isNotEmpty && seenLabels.contains(labelKey)) {
        continue;
      }
      deduplicatedGroupKeys.add(key);
      if (labelKey.isNotEmpty) {
        seenLabels.add(labelKey);
      }
    }
    orderedGroupKeys
      ..clear()
      ..addAll(deduplicatedGroupKeys);

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
                      final bool completed = stageTasks.isNotEmpty &&
                          (groupIds.length > 1
                              ? stageTasks.any(_isEffectivelyCompleted)
                              : stageTasks.every(_isEffectivelyCompleted));
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
                            Text(
                              label,
                              style: stageTextStyle,
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
    if (!_hasProductionStartedForStage(task)) return false;
    if (_anyUserActive(task)) return false;
    if (_isInkConfirmationStage(task)) {
      return true;
    }
    if (!_allPerformersFinished(task)) return false;
    return true;
  }

  bool _isInkConfirmationStage(TaskModel task) {
    final stageId = task.stageId.trim().toLowerCase();
    const flexoStageAliases = {
      '0571c01c-f086-47e4-81b2-5d8b2ab91218',
      'w_flexoprint',
      'w_flexo',
      'position:print',
      'print',
    };
    if (flexoStageAliases.contains(stageId) ||
        stageId.contains('flexo') ||
        stageId.contains('флекс')) {
      return true;
    }
    final personnel = context.read<PersonnelProvider>();
    final templates = context.read<TemplateProvider>();
    final orders = context.read<OrdersProvider>();
    final tasks = context.read<TaskProvider>();
    final label = _stageLabelForOrder(
      personnel,
      templates,
      orders,
      tasks,
      task.orderId,
      task.stageId,
    ).toLowerCase();
    return label.contains('флекс') ||
        label.contains('flexo');
  }

  String _orderDisplayNameForWriteoff(OrderModel order) {
    final customer = order.customer.trim();
    if (customer.isNotEmpty && !_looksLikeOrderCode(customer)) {
      return customer;
    }
    final productName = order.product.type.trim();
    if (productName.isNotEmpty && !_looksLikeOrderCode(productName)) {
      return productName;
    }
    return 'Без названия';
  }

  String _orderReferenceForWriteoff(OrderModel order) {
    return _orderDisplayNameForWriteoff(order);
  }

  bool _looksLikeOrderCode(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized.isEmpty) return true;
    if (RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$')
        .hasMatch(normalized)) {
      return true;
    }
    if (RegExp(r'^(заказ\s*)?#?\d+$').hasMatch(normalized)) {
      return true;
    }
    if (RegExp(r'^зк[-\s]?\d{4}(?:[.\-/]\d{1,2}){1,2}[-\s]?\d+$')
        .hasMatch(normalized)) {
      return true;
    }
    if (RegExp(r'^ord[-\s]?\d{4}[-\s]?\d+$').hasMatch(normalized)) {
      return true;
    }
    return false;
  }

  String _stageLabel(TaskModel task) {
    final personnel = context.read<PersonnelProvider>();
    final templates = context.read<TemplateProvider>();
    final orders = context.read<OrdersProvider>();
    final tasks = context.read<TaskProvider>();
    return _stageLabelForOrder(
      personnel,
      templates,
      orders,
      tasks,
      task.orderId,
      task.stageId,
    );
  }

  double _paintQtyKilogramsToDisplayGrams(dynamic value) {
    if (value is num) return value.toDouble() * 1000;
    final parsed = double.tryParse(value?.toString().replaceAll(',', '.') ?? '');
    return (parsed ?? 0) * 1000;
  }

  double _gramsToKilogramsForPersistence(double grams) => grams / 1000;

  double? _parsePositiveGrams(String text) {
    final normalized = text.trim().replaceAll(',', '.');
    if (normalized.isEmpty) return null;
    final parsed = double.tryParse(normalized);
    if (parsed == null || parsed <= 0) return null;
    return parsed;
  }

  String _formatAmountForDialog(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  String _stringFromRow(Map<String, dynamic> row, List<String> keys) {
    for (final key in keys) {
      final value = (row[key] ?? '').toString().trim();
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  bool _isPendingPaintRow(Map<String, dynamic> row) {
    final normalized = _stringFromRow(row, const [
      'source',
      'writeoff_source',
      'write_off_source',
    ]).trim().toLowerCase();
    return normalized == 'pending' ||
        normalized == 'pending_queue' ||
        normalized == 'queued' ||
        normalized == 'writeoff_queue';
  }

  FlexPaintWriteoffRow _paintWriteoffRowFromMap(
    Map<String, dynamic> row,
    String? defaultUnit,
  ) {
    final source = _stringFromRow(row, const [
      'source',
      'writeoff_source',
      'write_off_source',
    ]);
    final plannedGrams = row['planned_amount'] is num
        ? (row['planned_amount'] as num).toDouble()
        : row['planned_qty'] is num
            ? (row['planned_qty'] as num).toDouble()
            : row['planned_qty_g'] is num
                ? (row['planned_qty_g'] as num).toDouble()
                : row['reserved_qty'] is num
                    ? (row['reserved_qty'] as num).toDouble()
                    : _paintQtyKilogramsToDisplayGrams(row['qty_kg']);
    final actualUsedText = _stringFromRow(row, const [
      'actual_used_text',
      'actualUsedText',
      'used_qty_text',
    ]);
    final orderId = _stringFromRow(row, const ['order_id', 'orderId']);
    return FlexPaintWriteoffRow(
      sourceRow: Map<String, dynamic>.from(row),
      source: source.isEmpty ? 'current_order' : source,
      queueId: _stringFromRow(row, const ['queue_id', 'queueId']),
      orderId: orderId,
      orderLabel: _stringFromRow(row, const [
        'order_label',
        'orderLabel',
        'order_name',
      ]).isNotEmpty
          ? _stringFromRow(
              row,
              const ['order_label', 'orderLabel', 'order_name'],
            )
          : (orderId.isEmpty ? 'Текущий заказ' : orderId),
      paintId: _stringFromRow(row, const ['paint_id', 'material_id', 'paintId']),
      paintName:
          _stringFromRow(row, const ['paint_name', 'name', 'paintName']).isEmpty
          ? 'Краска'
          : _stringFromRow(row, const ['paint_name', 'name', 'paintName']),
      plannedAmount: plannedGrams,
      unit: _stringFromRow(row, const ['unit']).isEmpty
          ? ((defaultUnit ?? '').trim().isEmpty ? 'г' : defaultUnit!.trim())
          : _stringFromRow(row, const ['unit']),
      actualUsedText: actualUsedText,
      writeOffNow: row['write_off_now'] == true || row['writeOffNow'] == true,
    );
  }

  Widget _buildPaintWriteoffSection(
    String title,
    List<FlexPaintWriteoffRow> rows,
    Map<FlexPaintWriteoffRow, TextEditingController> controllers,
    void Function(VoidCallback fn) updateDialogState,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        if (rows.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text('Нет строк для отображения.'),
          )
        else
          ...rows.map(
            (row) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 16,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            'Заказ: ${row.orderLabel}',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text('Краска: ${row.paintName}'),
                          Text(
                            'План: ${_formatAmountForDialog(row.plannedAmount)} ${row.unit}',
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: controllers[row],
                              keyboardType: const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              decoration: const InputDecoration(
                                labelText: 'Фактический расход',
                                border: OutlineInputBorder(),
                              ),
                              onChanged: (value) => row.actualUsedText = value,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Text(row.unit),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 3,
                            child: CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              value: row.writeOffNow,
                              controlAffinity: ListTileControlAffinity.leading,
                              title: const Text('Списать сейчас'),
                              subtitle: Text(row.status),
                              onChanged: (value) {
                                updateDialogState(() {
                                  row.writeOffNow = value ?? false;
                                  row.refreshStatus();
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<_InkUsageDialogResult?> _showInkAdjustDialog(
    List<Map<String, dynamic>> paints,
    String? unit, {
    bool allowPaperEdit = false,
  }) async {
    final rows = paints
        .map((row) => _paintWriteoffRowFromMap(row, unit))
        .toList(growable: true);
    final currentRows = rows.where((row) => !row.isPendingSource).toList();
    final pendingRows = rows.where((row) => row.isPendingSource).toList();
    final controllers = <FlexPaintWriteoffRow, TextEditingController>{
      for (final row in rows)
        row: TextEditingController(text: row.actualUsedText),
    };
    const paperEditValue = '__open_paper_edit__';
    final result = await showDialog<Object?>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, updateDialogState) => AlertDialog(
          title: const Text('Списание красок'),
          content: SizedBox(
            width: 760,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Проверьте расход по каждой краске и отметьте строки, которые нужно списать сейчас.',
                  ),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: rows.isEmpty
                      ? const Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'В заказе не указаны краски. При необходимости вернитесь и добавьте их в заказ.',
                          ),
                        )
                      : ListView(
                          shrinkWrap: true,
                          children: [
                            _buildPaintWriteoffSection(
                              'Краски текущего заказа',
                              currentRows,
                              controllers,
                              updateDialogState,
                            ),
                            const SizedBox(height: 16),
                            _buildPaintWriteoffSection(
                              'Краски, ожидающие списания',
                              pendingRows,
                              controllers,
                              updateDialogState,
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
          actions: [
            if (allowPaperEdit)
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(paperEditValue),
                child: const Text('Изменить бумагу'),
              ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                final resultRows = <Map<String, dynamic>>[];
                for (final row in rows) {
                  final enteredText =
                      controllers[row]?.text ?? row.actualUsedText;
                  row.actualUsedText = enteredText;
                  row.refreshStatus();
                  final actualGrams = _parsePositiveGrams(enteredText);
                  final output = Map<String, dynamic>.from(row.sourceRow)
                    ..addAll({
                      'source': row.source,
                      'queue_id': row.queueId,
                      'order_id': row.orderId,
                      'source_order_id': row.orderId,
                      'order_label': row.orderLabel,
                      'paint_id': row.paintId,
                      'paint_name': row.paintName,
                      'planned_amount': row.plannedAmount,
                      'unit': row.unit,
                      'actual_used_text': row.actualUsedText,
                      'actual_used_amount': actualGrams,
                      'write_off_now': row.writeOffNow,
                      'status': row.status,
                    });

                  if (row.writeOffNow) {
                    if (actualGrams == null) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Для строк со списанием укажите фактический расход больше 0.',
                          ),
                        ),
                      );
                      return;
                    }
                    output['used_qty'] = actualGrams;
                    output['qty_kg'] =
                        _gramsToKilogramsForPersistence(actualGrams);
                  }
                  resultRows.add(output);
                }
                Navigator.of(ctx).pop(
                  _InkUsageDialogResult(
                    paints: resultRows,
                  ),
                );
              },
              child: const Text('Сохранить и завершить'),
            ),
          ],
        ),
      ),
    );
    for (final controller in controllers.values) {
      controller.dispose();
    }
    if (result == paperEditValue) {
      return const _InkUsageDialogResult(
        paints: <Map<String, dynamic>>[],
        openPaperEditor: true,
      );
    }
    if (result is _InkUsageDialogResult) {
      return result;
    }
    return null;
  }

  String _humanizeRpcError(Object error) {
    if (error is PostgrestException) {
      final message = error.message.trim();
      if (message.isNotEmpty) return message;
      final details = (error.details ?? '').toString().trim();
      if (details.isNotEmpty) return details;
    }
    final raw = error.toString();
    final marker = RegExp(r'Недостаточно краски: [^\n}]+');
    final match = marker.firstMatch(raw);
    if (match != null) return match.group(0)!;
    return raw;
  }

  Future<void> _finalizeTask(
    TaskModel task, {
    _QuantityInput? initialQtyInput,
  }) async {
    final unitLabel =
        _workplaceUnit(context.read<PersonnelProvider>(), task.stageId);
    List<Map<String, dynamic>> paints = const <Map<String, dynamic>>[];
    _QuantityInput? qtyInput = initialQtyInput;
    if (_isInkConfirmationStage(task)) {
      List<Map<String, dynamic>> initialPaints = const <Map<String, dynamic>>[];
      try {
        final repo = OrdersRepository();
        initialPaints = await repo.getPaints(task.orderId);
        final pendingWriteoffs = await repo.getPendingPaintWriteoffs(
          excludeOrderId: task.orderId,
        );
        final reservations = await repo.getPaintReservations(task.orderId);
        final order = _orderById(task.orderId);
        final orderLabel =
            order != null ? _orderReferenceForWriteoff(order) : task.orderId;
        final reservationsByKey = <String, Map<String, dynamic>>{};
        for (final reservation in reservations) {
          final id = (reservation['paint_id'] ?? '').toString().trim();
          final name = (reservation['paint_name'] ?? '')
              .toString()
              .trim()
              .toLowerCase();
          if (id.isNotEmpty) reservationsByKey['id:$id'] = reservation;
          if (name.isNotEmpty) reservationsByKey['name:$name'] = reservation;
        }
        final currentPaints = initialPaints.map((paint) {
          final merged = Map<String, dynamic>.from(paint);
          final id = (merged['paint_id'] ?? merged['material_id'] ?? '')
              .toString()
              .trim();
          final name = (merged['paint_name'] ?? merged['name'] ?? '')
              .toString()
              .trim()
              .toLowerCase();
          final reservation =
              (id.isNotEmpty ? reservationsByKey['id:$id'] : null) ??
                  (name.isNotEmpty ? reservationsByKey['name:$name'] : null);
          merged.addAll({
            'source': 'current_order',
            'order_id': task.orderId,
            'source_order_id': task.orderId,
            'source_task_id': task.id,
            'order_label': orderLabel,
          });
          if (reservation != null) {
            merged.addAll({
              'paint_id': reservation['paint_id'],
              'paint_name': reservation['paint_name'] ??
                  merged['paint_name'] ??
                  merged['name'],
              'reserved_qty': reservation['reserved_qty'],
              'used_qty': reservation['used_qty'],
              'released_qty': reservation['released_qty'],
            });
          }
          return merged;
        }).toList(growable: false);
        final pendingPaints = pendingWriteoffs.map((pending) {
          final row = Map<String, dynamic>.from(pending);
          return row
            ..addAll({
              'source': 'pending',
              'pending_writeoff_id': row['id'],
              'order_id': row['order_id'],
              'source_order_id': row['order_id'],
              'source_task_id': row['task_id'],
              'order_label': row['order_id'] ?? 'Заказ',
              'planned_amount': row['planned_amount'],
              'actual_used_amount': row['actual_used_amount'],
              'actual_used_text': row['actual_used_amount']?.toString() ?? '',
            });
        }).toList(growable: false);
        initialPaints = <Map<String, dynamic>>[
          ...currentPaints,
          ...pendingPaints,
        ];
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Не удалось загрузить краски заказа: $e')),
          );
        }
        return;
      }
      var mutablePaints = initialPaints;
      while (true) {
        final dialogResult = await _showInkAdjustDialog(
          mutablePaints,
          unitLabel,
          allowPaperEdit: true,
        );
        if (dialogResult == null) return;
        if (dialogResult.openPaperEditor) {
          final order = _orderById(task.orderId);
          if (order == null) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Не удалось найти заказ для редактирования бумаги.'),
                ),
              );
            }
            return;
          }
          await _openPaperEditDialog(order);
          continue;
        }
        mutablePaints = dialogResult.paints;
        paints = mutablePaints;
        break;
      }
    }

    final stageMode = _execModeForUser(task, widget.employeeId);
    final isSeparateFinalizeWithoutPrefilledQty =
        stageMode == ExecutionMode.separate && qtyInput == null;

    if (!isSeparateFinalizeWithoutPrefilledQty) {
      while (qtyInput == null) {
        final result = await _askQuantity(
          context,
          unit: unitLabel,
          allowPaperEdit: true,
          initialQuantity: _initialMeterQuantityForTask(task, unitLabel),
        );
        if (result == null) return;
        if (!result.openPaperEditor) {
          qtyInput = result;
          break;
        }
        final order = _orderById(task.orderId);
        if (order == null) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Не удалось найти заказ для редактирования бумаги.'),
              ),
            );
          }
          return;
        }
        await _openPaperEditDialog(order);
      }
    }

    final tp = context.read<TaskProvider>();
    if (_isInkConfirmationStage(task)) {
      final note = mounted ? await _askFinishNote() : null;
      try {
        await OrdersRepository().completeFlexPrintingStage(
          taskId: task.id,
          orderId: task.orderId,
          stageId: task.stageId,
          employeeId: widget.employeeId,
          currentOrderRows: paints
              .where((row) => !_isPendingPaintRow(row))
              .toList(growable: false),
          pendingRows: paints
              .where(_isPendingPaintRow)
              .toList(growable: false),
          quantityDone: qtyInput?.displayText,
          comment: note,
        );
        await tp.refresh();
        if (mounted) {
          setState(() {
            _orderPaintsCache[task.orderId] = paints
                .map((row) => Map<String, dynamic>.from(row))
                .toList(growable: false);
          });
        }
      } catch (e) {
        if (mounted) {
          final message = _humanizeRpcError(e);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(message)),
          );
        }
      }
      return;
    }

    final note = mounted ? await _askFinishNote() : null;
    try {
      await OrdersRepository().completeTaskStage(
        taskId: task.id,
        orderId: task.orderId,
        stageId: task.stageId,
        employeeId: widget.employeeId,
        quantityDone: qtyInput?.displayText,
        comment: note,
      );
      await tp.refresh();
    } catch (e) {
      if (mounted) {
        final message = _humanizeRpcError(e);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    }
  }

  bool _hasBlockingActiveOrder(TaskProvider provider, TaskModel currentTask) {
    final currentExecMode = _execModeForUser(currentTask, widget.employeeId);
    if (currentExecMode != ExecutionMode.separate) {
      return false;
    }

    return provider.tasks.any((task) {
      if (task.id == currentTask.id) return false;
      if (task.assignees.contains(widget.employeeId) == false) return false;
      if (_isEffectivelyCompleted(task)) return false;
      final state = _userRunState(task, widget.employeeId);
      return state == UserRunState.active;
    });
  }

  List<TaskModel> _tasksForWorkplace(TaskProvider taskProvider) {
    if (_selectedWorkplaceId == null) return const <TaskModel>[];

    final ordersProvider = context.read<OrdersProvider>();
    OrderModel? findTaskOrder(String id) {
      for (final order in ordersProvider.orders) {
        if (order.id == id) return order;
      }
      for (final order in ordersProvider.orders) {
        if (order.assignmentId != null && order.assignmentId == id) {
          return order;
        }
      }
      return null;
    }

    final templateProvider = context.read<TemplateProvider>();
    final stageGroupByOrder = <String, Map<String, String>>{};
    for (final order in ordersProvider.orders) {
      final map = _stageGroupMapForOrder(
        order,
        templateProvider,
        tasks: taskProvider,
      );
      if (map.isNotEmpty) {
        stageGroupByOrder[order.id] = map;
      }
    }

    String taskGroupKey(TaskModel task) {
      final lookup = stageGroupByOrder[task.orderId];
      final persistedGroup = task.stageGroupKey.trim();
      final groupKey = persistedGroup.isNotEmpty
          ? persistedGroup
          : (lookup?[task.stageId] ?? task.stageId);
      return '${task.orderId}::$groupKey';
    }

    final tasksByGroup = <String, List<TaskModel>>{};
    for (final task in taskProvider.tasks) {
      final key = taskGroupKey(task);
      tasksByGroup.putIfAbsent(key, () => []).add(task);
    }

    return taskProvider.tasks
        .where((t) => t.stageId == _selectedWorkplaceId)
        .where((task) => isTaskOrderLaunchedForWorkspace(
              findTaskOrder(task.orderId),
            ))
        .where((t) => !_isEffectivelyCompleted(t))
        .where((task) {
          final groupKey = taskGroupKey(task);
          final groupTasks = tasksByGroup[groupKey] ?? const <TaskModel>[];
          final capturedWorkplace = groupTasks
              .map((t) => t.capturedByWorkplaceId?.trim() ?? '')
              .firstWhere((id) => id.isNotEmpty, orElse: () => '');
          if (capturedWorkplace.isNotEmpty &&
              capturedWorkplace != task.stageId) {
            // После захвата этап отображается только у рабочего места-захватчика.
            return false;
          }
          final groupHasActive =
              groupTasks.any((t) => t.status != TaskStatus.waiting);
          if (groupHasActive && task.status == TaskStatus.waiting) {
            return false;
          }
          return true;
        })
        .toList();
  }

  bool _isUnlockedByWorkplaceQueue(
    TaskModel task,
    TaskProvider taskProvider,
    ProductionQueueProvider queue,
    WorkplaceModel? workplace,
  ) {
    if (task.status != TaskStatus.waiting) return true;
    if (_selectedWorkplaceId?.trim().isEmpty ?? true) return true;

    final queueGroupId = _selectedWorkplaceId!.trim();
    final ordersProvider = context.read<OrdersProvider>();
    final queued = _tasksForWorkplace(taskProvider)
      ..sort((a, b) => queue
          .priorityOf(
            _queueOrderIdForTask(a, ordersProvider),
            groupId: queueGroupId,
          )
          .compareTo(queue.priorityOf(
                _queueOrderIdForTask(b, ordersProvider),
                groupId: queueGroupId,
              )));

    final index = queued.indexWhere((t) => t.id == task.id);
    if (index <= 0) return true;

    final bool strictSequentialByPreviousCompletion =
        workplace != null && workplace.executionMode != WorkplaceExecutionMode.separate;

    for (var i = 0; i < index; i++) {
      final previous = queued[i];
      if (strictSequentialByPreviousCompletion) {
        final bool previousCompleted = _isEffectivelyCompleted(previous);
        final bool previousInProblem = previous.status == TaskStatus.problem ||
            previous.comments.any((c) => c.type == 'problem');
        // Бизнес-правило для "Одиночная/Совместная": следующий заказ можно
        // стартовать только после завершения предыдущего, либо если он в "Проблеме".
        if (!previousCompleted && !previousInProblem) {
          return false;
        }
        continue;
      }
      if (!_hasWorkplaceQueueActivity(previous)) {
        return false;
      }
    }
    return true;
  }

  Widget _buildControlPanel(TaskModel task, WorkplaceModel stage,
      TaskProvider provider, double scale, bool isTablet) {
    // === Derived state & permissions ===
    final bool shiftPaused = _isShiftPausedForStage(provider, task);
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

    // Старт возможен, если задача ждёт/на паузе/с проблемой,
    // или уже в работе; при этом соблюдаем последовательность этапов.

    bool _slotAvailable() => true;

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
        _isUnlockedByWorkplaceQueue(
          task,
          provider,
          context.read<ProductionQueueProvider>(),
          stage,
        ) &&
        (_canRunOutOfStageSequence(task) ||
            _isFirstPendingStage(context.read<TaskProvider>(),
                context.read<PersonnelProvider>(), task,
                groupResolver: _stageGroupKey)) &&
        stageModeAllowsJoin &&
        !shiftPaused &&
        !groupLocked &&
        !_hasBlockingActiveOrder(provider, task);

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

                  Widget buildControlsFor(String? label,
                      {List<String>? jointGroup, String? userId}) {
                    final tp = context.read<TaskProvider>();

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
                    final bool isSetupActiveForRow =
                        _isSetupInProgressForUser(task, currentRowUserId);
                    final bool isSetupStartPending =
                        _startingSetupTaskIds.contains(task.id);
                    // Disable buttons for other users' rows
                    // Кнопка "Начать" доступна для своей строки, если
                    // пользователь может стартовать, и он либо ещё не
                    // запускал этап (idle), либо находится на паузе/в проблеме
                    // (разрешаем возобновление), либо уже завершил личную
                    // смену статуса, но этап ещё не закрыт общей кнопкой
                    // "Завершить" снизу.
                    final bool requiresSetupBeforeStart =
                        _hasMachineForStage(stage) &&
                            !_hasPendingSetupForStage(task) &&
                            !_isSetupCompletedForStage(task) &&
                            !_hasProductionStartedForStage(task);
                    final bool userParticipatedInStage =
                        _hasUserParticipatedInStage(task, currentRowUserId);
                    final bool stageStartedBeforeShiftResume =
                        _hasProductionStartedForStage(task) &&
                            task.comments.any((c) => c.type == 'shift_resume');
                    final bool blockedByShiftResumeLock =
                        stageStartedBeforeShiftResume &&
                            stateRowUser == UserRunState.idle;
                    final bool hasOpenStartIntentForRowUser =
                        _hasOpenStartIntentForUser(task, currentRowUserId);
                    final bool startIntentBlocksRow =
                        hasOpenStartIntentForRowUser && !isSetupActiveForRow;
                    final bool canStartButtonRow = isMyRow &&
                        canStart &&
                        !_startingTaskIds.contains(task.id) &&
                        !requiresSetupBeforeStart &&
                        !blockedByShiftResumeLock &&
                        !startIntentBlocksRow &&
                        // Для отдельных исполнителей разрешаем возобновлять этап
                        // после личного завершения (до финальной кнопки
                        // "Завершить задание").
                        // Для совместного режима после user_done повторный запуск
                        // через эту строку недоступен.
                        (((stateRowUser == UserRunState.idle)) ||
                            (stateRowUser == UserRunState.paused) ||
                            (stateRowUser == UserRunState.problem) ||
                            (stateRowUser == UserRunState.finished &&
                                stageExecMode == ExecutionMode.separate) ||
                            (stateRowUser == UserRunState.active &&
                                isSetupActiveForRow));
                    final bool shouldShowContinueLabel =
                        stateRowUser == UserRunState.problem ||
                            (stateRowUser == UserRunState.finished &&
                                stageExecMode == ExecutionMode.separate);
                    final bool canPauseRow = isMyRow &&
                        canPause &&
                        stateRowUser == UserRunState.active;
                    // allow pausing also if user resumed
                    final bool canFinishRow = isMyRow &&
                        canFinish &&
                        _hasProductionStartedForStage(task) &&
                        userParticipatedInStage &&
                        (stateRowUser != UserRunState.idle &&
                            stateRowUser != UserRunState.finished) &&
                        !isSetupActiveForRow;
                    final bool canProblemRow = isMyRow &&
                        canProblem &&
                        stateRowUser == UserRunState.active;
                    final bool canShiftControl = shiftPaused
                        ? !_hasBlockingActiveOrder(tp, task)
                        : (isMyRow &&
                            (stateRowUser == UserRunState.active ||
                                stateRowUser == UserRunState.paused ||
                                stateRowUser == UserRunState.problem));
                    Future<void> recordTimeEventForUser(TaskTimeType type,
                        {String? note, bool includeHelpers = true}) async {
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

                      if (includeHelpers && jointGroup != null && isMyRow) {
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

                    final personnel = context.read<PersonnelProvider>();

                    Future<void> onStart() async {
                      if (_startingTaskIds.contains(task.id)) return;
                      setState(() => _startingTaskIds.add(task.id));
                      try {
                        final taskProvider = context.read<TaskProvider>();
                        final personnelProvider = personnel;
                        // Sequential stage guard
                        if (!_canRunOutOfStageSequence(task) &&
                            !_isFirstPendingStage(
                                taskProvider, personnelProvider, task,
                                groupResolver: _stageGroupKey)) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                content: Text(
                                    'Сначала выполните предыдущий этап заказа')));
                          }
                          return;
                        }

                        if (!_isUnlockedByWorkplaceQueue(
                          task,
                          taskProvider,
                          context.read<ProductionQueueProvider>(),
                          stage,
                        )) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                content: Text(
                                    'Сначала начните предыдущие задания в очереди')));
                          }
                          return;
                        }

                        if (_hasBlockingActiveOrder(taskProvider, task)) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                content:
                                    Text('Сначала завершите текущий активный заказ')));
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

                        if (_hasMachineForStage(stage) &&
                            !_hasPendingSetupForStage(task) &&
                            !_isSetupCompletedForStage(task) &&
                            !_hasProductionStartedForStage(task)) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                content: Text(
                                    'Сначала начните наладку, затем запускайте этап')));
                          }
                          return;
                        }


                        final startedAtTs =
                            task.startedAt ?? DateTime.now().millisecondsSinceEpoch;
                        final started = await taskProvider.updateStatus(
                          task.id,
                          TaskStatus.inProgress,
                          startedAt: startedAtTs,
                        );
                        if (!started) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                              content: Text(
                                  'Этап уже запущен другим сотрудником. Обновите список и продолжите работу в активном этапе.'),
                            ));
                          }
                          return;
                        }
                        final ExecutionMode? selectedMode = stageExecMode;
                        final alreadyAssigned =
                            task.assignees.contains(widget.employeeId);
                        if (explicitStageMode == null) {
                          await taskProvider.addComment(
                            taskId: task.id,
                            type: 'exec_mode_stage',
                            text: _executionModeCode(stageExecMode),
                            userId: widget.employeeId,
                          );
                        }

                        if (!alreadyAssigned) {
                          final newAssignees = List<String>.from(task.assignees)
                            ..add(widget.employeeId);
                          await taskProvider.updateAssignees(task.id, newAssignees);
                        }

                        if (selectedMode != null &&
                            _needsExecModeRecord(
                                task, widget.employeeId, selectedMode)) {
                          await taskProvider.addComment(
                            taskId: task.id,
                            type: 'exec_mode',
                            text: _executionModeCode(selectedMode),
                            userId: widget.employeeId,
                          );
                        }

                        if (_hasMachineForStage(stage) &&
                            !_isSetupCompletedForUser(task, widget.employeeId)) {
                          await _finishSetup(task, provider);
                        }
                        final isResumeAction = stateRowUser == UserRunState.paused ||
                            stateRowUser == UserRunState.problem;
                        await taskProvider.addCommentAutoUser(
                          taskId: task.id,
                          type: isResumeAction ? 'resume' : 'start',
                          text: isResumeAction
                              ? 'Возобновил(а) этап'
                              : 'Начал(а) этап',
                          userIdOverride: widget.employeeId,
                        );
                        await recordTimeEventForUser(TaskTimeType.production);
                      } finally {
                        if (mounted) {
                          setState(() => _startingTaskIds.remove(task.id));
                        } else {
                          _startingTaskIds.remove(task.id);
                        }
                      }
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
                        await context
                            .read<TaskProvider>()
                            .updateStatus(task.id, TaskStatus.paused);
                      }
                    }

                    Future<void> onFinish() async {
                      final unitLabel = _workplaceUnit(personnel, task.stageId);
                      final order = _orderById(task.orderId);
                      _QuantityInput? qtyInput;
                      while (true) {
                        qtyInput = await _askQuantity(
                          context,
                          unit: unitLabel,
                          allowPaperEdit: true,
                          initialQuantity:
                              _initialMeterQuantityForTask(task, unitLabel),
                        );
                        if (qtyInput == null) return;
                        if (!qtyInput.openPaperEditor) break;
                        if (order == null) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                    'Не удалось найти заказ для редактирования бумаги.'),
                              ),
                            );
                          }
                          return;
                        }
                        await _openPaperEditDialog(order);
                      }
                      if (qtyInput == null) return;
                      final qtyText = qtyInput.displayText;
                      final taskProvider = context.read<TaskProvider>();
                      var separateAllDone = false;
                      var jointUserIds = <String>[];
                      if (jointGroup != null) {
                        final latestTask = taskProvider.tasks.firstWhere(
                          (t) => t.id == task.id,
                          orElse: () => task,
                        );
                        jointUserIds = latestTask.assignees
                            .where((id) =>
                                _execModeForUser(latestTask, id) ==
                                ExecutionMode.joint)
                            .toSet()
                            .toList(growable: false);
                        if (!jointUserIds.contains(widget.employeeId)) {
                          jointUserIds.add(widget.employeeId);
                        }
                      } else {
                        // SEPARATE: write personal qty, require ALL separate-mode assignees to finish.
                        // This path does not complete the stage; final stage completion is
                        // performed by the backend RPC from the separate "Завершить задание" action.
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
                        final doneUsers = latestTask.comments
                            .where((c) => c.type == 'user_done')
                            .map((c) => c.userId)
                            .where((id) => id.isNotEmpty)
                            .toSet();
                        doneUsers.add(widget.employeeId);
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
                          final has = doneUsers.contains(id);
                          if (!has) {
                            allDone = false;
                            break;
                          }
                        }
                        if (allDone) {
                          separateAllDone = true;
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
                      // В режиме "отдельный исполнитель" кнопка в строке
                      // фиксирует только личное завершение сотрудника. Сам этап
                      // закрывается только отдельной кнопкой "Завершить задание"
                      // после того, как все отдельные исполнители отметились.
                      final shouldCloseStage = jointGroup != null;
                      final canApplyFinish = !_anyUserActive(latestTask);
                      if (canApplyFinish) {
                        final _secs = _elapsed(latestTask).inSeconds;
                        if (shouldCloseStage) {
                          if (_isInkConfirmationStage(task)) {
                            await _finalizeTask(task, initialQtyInput: qtyInput);
                            return;
                          }
                          final note =
                              context.mounted ? await _askFinishNote() : null;
                          try {
                            await OrdersRepository().completeTaskStage(
                              taskId: task.id,
                              orderId: task.orderId,
                              stageId: task.stageId,
                              employeeId: widget.employeeId,
                              quantityDone: qtyText,
                              comment: note,
                              jointUserIds: jointUserIds,
                            );
                            await taskProvider.refresh();
                          } catch (e) {
                            if (context.mounted) {
                              final message = _humanizeRpcError(e);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(message)),
                              );
                            }
                          }
                          return;
                        }

                        await taskProvider.updateStatus(
                            task.id, TaskStatus.paused,
                            spentSeconds: _secs,
                            startedAt: null,
                            clearStartedAt: true);
                        if (context.mounted && separateAllDone) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Все исполнители завершили работу. Нажмите «Завершить задание» для закрытия этапа.',
                              ),
                            ),
                          );
                        }
                      }
                    }

                    Future<void> onProblem() async {
                      final problemDraft = await _askCommentDraft(
                        'Причина проблемы',
                        allowAttachments: true,
                      );
                      if (problemDraft == null) return;
                      final comment = problemDraft.text;
                      final subjects = <String>[currentRowUserId];
                      if (jointGroup != null && isMyRow) {
                        subjects
                          ..clear()
                          ..addAll(jointGroup);
                      }
                      final saved = await tp.reportProblem(
                        taskId: task.id,
                        text: comment,
                        userId: widget.employeeId,
                        participantsSnapshot:
                            _participantsSnapshot(task, widget.employeeId),
                        subjectUserIds: subjects,
                        workplaceId: task.stageId,
                        executionMode: _executionModeCode(
                          stageExecMode ??
                              _execModeForUser(task, widget.employeeId),
                        ),
                        attachments: problemDraft.attachments,
                      );
                      if (!saved && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Проблему можно зафиксировать только для этапа в работе.',
                            ),
                          ),
                        );
                      }
                    }

                    Future<void> onAddHelper() async {
                      final taskProvider = context.read<TaskProvider>();
                      final bool isOwner = task.assignees.isNotEmpty &&
                          task.assignees.first == widget.employeeId;
                      if (!isOwner || stageExecMode != ExecutionMode.joint) {
                        return;
                      }

                      final available = personnel.employees
                          .where((e) => !task.assignees.contains(e.id))
                          .toList();
                      if (available.isEmpty) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                              content: Text('Нет свободных сотрудников для помощи.')));
                        }
                        return;
                      }

                      String? selectedId;
                      final approved = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => StatefulBuilder(
                          builder: (ctx, setState) => AlertDialog(
                            title: const Text('Добавить помощника'),
                            content: DropdownButtonFormField<String>(
                              value: selectedId,
                              decoration: const InputDecoration(
                                labelText: 'Сотрудник',
                                border: OutlineInputBorder(),
                              ),
                              items: available
                                  .map((e) => DropdownMenuItem(
                                        value: e.id,
                                        child: Text(
                                          '${e.firstName} ${e.lastName}'.trim(),
                                        ),
                                      ))
                                  .toList(),
                              onChanged: (value) => setState(() => selectedId = value),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('Отмена'),
                              ),
                              FilledButton(
                                onPressed: selectedId == null
                                    ? null
                                    : () => Navigator.pop(ctx, true),
                                child: const Text('Добавить'),
                              ),
                            ],
                          ),
                        ),
                      );

                      if (approved != true || selectedId == null) return;

                      if (_needsExecModeRecord(
                          task, widget.employeeId, ExecutionMode.joint)) {
                        await taskProvider.addComment(
                          taskId: task.id,
                          type: 'exec_mode',
                          text: _executionModeCode(ExecutionMode.joint),
                          userId: widget.employeeId,
                        );
                      }

                      final newAssignees = List<String>.from(task.assignees)
                        ..add(selectedId!);
                      await taskProvider.updateAssignees(task.id, newAssignees);

                      if (_needsExecModeRecord(
                          task, selectedId!, ExecutionMode.joint)) {
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

                    Future<void> onRemoveHelper(String helperId) async {
                      final taskProvider = context.read<TaskProvider>();
                      final latestTask = taskProvider.tasks.firstWhere(
                        (t) => t.id == task.id,
                        orElse: () => task,
                      );
                      final isOwner = latestTask.assignees.isNotEmpty &&
                          latestTask.assignees.first == widget.employeeId;
                      if (!isOwner) return;
                      if (!latestTask.assignees.contains(helperId)) return;

                      final helper = personnel.employees.firstWhere(
                        (e) => e.id == helperId,
                        orElse: () => EmployeeModel(
                          id: helperId,
                          firstName: 'Сотр.',
                          lastName: helperId.substring(
                              0, helperId.length > 4 ? 4 : helperId.length),
                          patronymic: '',
                          iin: '',
                          positionIds: const [],
                        ),
                      );
                      final helperName =
                          '${helper.firstName} ${helper.lastName}'.trim();
                      final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Удалить помощника'),
                              content: Text(
                                'Убрать сотрудника «$helperName» с этапа?',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(ctx).pop(false),
                                  child: const Text('Отмена'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.of(ctx).pop(true),
                                  child: const Text('Удалить'),
                                ),
                              ],
                            ),
                          ) ??
                          false;
                      if (!confirmed) return;

                      final unitLabel = _workplaceUnit(personnel, task.stageId);
                      final qtyInput = await _askQuantity(
                        context,
                        unit: unitLabel,
                        initialQuantity:
                            _initialMeterQuantityForTask(task, unitLabel),
                      );
                      if (qtyInput == null) return;

                      await taskProvider.closeOpenTimeEvent(
                        task: latestTask,
                        initiatedBy: widget.employeeId,
                        subjectUserId: helperId,
                        note: 'helper_removed',
                      );

                      final updatedAssignees = List<String>.from(
                        latestTask.assignees.where((id) => id != helperId),
                      );
                      await taskProvider.updateAssignees(task.id, updatedAssignees);

                      await taskProvider.addCommentAutoUser(
                        taskId: task.id,
                        type: 'helper_removed',
                        text: 'Помощник удалён: $helperName',
                        userIdOverride: widget.employeeId,
                      );
                      await taskProvider.addCommentAutoUser(
                        taskId: task.id,
                        type: 'helper_removed_qty',
                        text: '$helperName: ${qtyInput.displayText}',
                        userIdOverride: widget.employeeId,
                      );
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

                      if (shiftPaused &&
                          _hasBlockingActiveOrder(taskProvider, task)) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                              content: Text(
                                  'Сначала завершите текущий активный заказ')));
                        }
                        return;
                      }

                      if (!shiftPaused) {
                        final latestTask = taskProvider.tasks.firstWhere(
                          (t) => t.id == task.id,
                          orElse: () => task,
                        );
                        final unitLabel =
                            _workplaceUnit(personnel, task.stageId);
                        _QuantityInput? qtyInput;
                        while (true) {
                          qtyInput = await _askQuantity(
                            context,
                            unit: unitLabel,
                            allowPaperEdit: true,
                            initialQuantity:
                                _initialMeterQuantityForTask(task, unitLabel),
                          );
                          if (qtyInput == null) return;
                          if (!qtyInput.openPaperEditor) break;
                          final order = _orderById(task.orderId);
                          if (order == null) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Не удалось найти заказ для редактирования бумаги.',
                                  ),
                                ),
                              );
                            }
                            return;
                          }
                          await _openPaperEditDialog(order);
                        }
                        if (qtyInput == null) return;
                        final qtyText = qtyInput.displayText;
                        final helperIds = jointGroup != null && isMyRow
                            ? latestTask.assignees
                                .where((id) =>
                                    id != latestTask.assignees.first &&
                                    _execModeForUser(latestTask, id) ==
                                        ExecutionMode.joint)
                                .toList()
                            : const <String>[];
                        final hasPendingSetup =
                            _hasPendingSetupForStage(latestTask);
                        final isSetupInProgress = _isSetupInProgressForUser(
                          latestTask,
                          currentRowUserId,
                        );
                        final stageProductionStarted =
                            _hasProductionStartedForStage(latestTask);
                        final shiftResumeState = stateRowUser == UserRunState.problem
                            ? 'problem'
                            : stateRowUser == UserRunState.paused
                                ? 'paused'
                                : (!stageProductionStarted &&
                                        (isSetupActiveForRow ||
                                            isSetupInProgress ||
                                            hasPendingSetup))
                                    ? 'setup'
                                    : 'production';

                        await taskProvider.addCommentAutoUser(
                            taskId: task.id,
                            type: 'quantity_share',
                            text: qtyText,
                            userIdOverride: widget.employeeId);

                        for (final helperId in helperIds) {
                          await taskProvider.addCommentAutoUser(
                              taskId: task.id,
                              type: 'quantity_share',
                              text: qtyText,
                              userIdOverride: helperId);
                          await taskProvider.closeOpenTimeEvent(
                            task: task,
                            initiatedBy: widget.employeeId,
                            subjectUserId: helperId,
                            note: 'shift_change',
                          );
                        }

                        if (helperIds.isNotEmpty) {
                          final updatedAssignees = latestTask.assignees
                              .where((id) => !helperIds.contains(id))
                              .toList();
                          await taskProvider.updateAssignees(
                              task.id, updatedAssignees);
                        }

                        final related = _relatedTasks(taskProvider, task);
                        for (final rel in related) {
                          if (rel.status == TaskStatus.inProgress) {
                            await taskProvider.updateStatus(
                                rel.id, TaskStatus.paused);
                          }
                        }
                        await recordTimeEventForUser(TaskTimeType.shiftChange);
                        await taskProvider.addCommentAutoUser(
                            taskId: task.id,
                            type: 'shift_pause_state',
                            text: shiftResumeState,
                            userIdOverride: widget.employeeId);
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
                        final latestTask = taskProvider.tasks.firstWhere(
                          (t) => t.id == task.id,
                          orElse: () => task,
                        );
                        final assignees = latestTask.assignees;
                        if (assignees.length != 1 ||
                            assignees.first != widget.employeeId) {
                          await taskProvider.updateAssignees(
                              task.id, [widget.employeeId]);
                        }
                        final related = _relatedTasks(taskProvider, latestTask);
                        for (final rel in related) {
                          final openShiftEvents = _taskTimeEvents(rel)
                              .where((e) =>
                                  e.type == TaskTimeType.shiftChange &&
                                  e.endTime == null)
                              .toList();
                          for (final event in openShiftEvents) {
                            await taskProvider.closeOpenTimeEvent(
                              task: rel,
                              initiatedBy: widget.employeeId,
                              subjectUserId: event.subjectUserId,
                              note: 'shift_resume',
                            );
                          }
                        }
                        final shiftStateComment = latestTask.comments
                            .where((comment) => comment.type == 'shift_pause_state')
                            .toList();
                        final shiftResumeState = shiftStateComment.isNotEmpty
                            ? shiftStateComment.last.text.trim().toLowerCase()
                            : (_hasPendingSetupForStage(latestTask)
                                ? 'setup'
                                : 'production');
                        final startedAtTs = latestTask.startedAt ??
                            DateTime.now().millisecondsSinceEpoch;
                        final participants =
                            _participantsSnapshot(latestTask, widget.employeeId);
                        final execMode = _stageExecutionMode(latestTask);

                        if (shiftResumeState == 'setup') {
                          if (!_isSetupInProgressForUser(
                                  latestTask, widget.employeeId) &&
                              !_isSetupCompletedForUser(
                                  latestTask, widget.employeeId)) {
                            await taskProvider.addCommentAutoUser(
                              taskId: task.id,
                              type: 'setup_start',
                              text: 'Начал(а) настройку станка',
                              userIdOverride: widget.employeeId,
                            );
                          }
                          await taskProvider.updateStatus(
                            task.id,
                            TaskStatus.inProgress,
                            startedAt: startedAtTs,
                          );
                          await taskProvider.recordTimeEvent(
                            task: latestTask,
                            type: TaskTimeType.setup,
                            initiatedBy: widget.employeeId,
                            subjectUserId: widget.employeeId,
                            workplaceId: latestTask.stageId,
                            participantsSnapshot: participants,
                            executionMode: execMode != null
                                ? _executionModeCode(execMode)
                                : null,
                            note: 'shift_resume_setup',
                          );
                        } else if (shiftResumeState == 'paused') {
                          await taskProvider.updateStatus(task.id, TaskStatus.paused);
                          await taskProvider.recordTimeEvent(
                            task: latestTask,
                            type: TaskTimeType.pause,
                            initiatedBy: widget.employeeId,
                            subjectUserId: widget.employeeId,
                            workplaceId: latestTask.stageId,
                            participantsSnapshot: participants,
                            executionMode: execMode != null
                                ? _executionModeCode(execMode)
                                : null,
                            note: 'shift_resume_pause',
                          );
                        } else if (shiftResumeState == 'problem') {
                          await taskProvider.updateStatus(task.id, TaskStatus.problem);
                          await taskProvider.recordTimeEvent(
                            task: latestTask,
                            type: TaskTimeType.problem,
                            initiatedBy: widget.employeeId,
                            subjectUserId: widget.employeeId,
                            workplaceId: latestTask.stageId,
                            participantsSnapshot: participants,
                            executionMode: execMode != null
                                ? _executionModeCode(execMode)
                                : null,
                            note: 'shift_resume_problem',
                          );
                        } else {
                          await taskProvider.updateStatus(
                            task.id,
                            TaskStatus.inProgress,
                            startedAt: startedAtTs,
                          );
                          await taskProvider.recordTimeEvent(
                            task: latestTask,
                            type: TaskTimeType.production,
                            initiatedBy: widget.employeeId,
                            subjectUserId: widget.employeeId,
                            workplaceId: latestTask.stageId,
                            participantsSnapshot: participants,
                            executionMode: execMode != null
                                ? _executionModeCode(execMode)
                                : null,
                            note: 'shift_resume_production',
                          );
                        }
                        final updated = taskProvider.tasks.firstWhere(
                          (t) => t.id == task.id,
                          orElse: () => task,
                        );
                        final resumeDetails = updated.status == TaskStatus.inProgress
                            ? 'Пересмена: работа возобновлена'
                            : 'Пересмена: состояние восстановлено';
                        await taskProvider.addCommentAutoUser(
                            taskId: task.id,
                            type: 'shift_resume',
                            text: resumeDetails,
                            userIdOverride: widget.employeeId);
                        await analytics.logEvent(
                          orderId: task.orderId,
                          stageId: task.stageId,
                          userId: widget.employeeId,
                          action: 'shift_resume',
                          category: 'production',
                          details: updated.status == TaskStatus.inProgress
                              ? 'Работа возобновлена после пересмены'
                              : 'Восстановлено состояние этапа после пересмены',
                        );
                      }
                    }

                    String timeText() {
                      final hasShiftHistory = _taskTimeEvents(task)
                              .any((event) => event.type == TaskTimeType.shiftChange) ||
                          task.comments.any((c) =>
                              c.type == 'shift_pause' || c.type == 'shift_resume');
                      final d = (jointGroup != null || hasShiftHistory)
                          ? _totalStageTime(task)
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
                                            style: TextStyle(
                                              fontWeight: FontWeight.w600,
                                              fontSize: scaled(12),
                                            ))),
                                  if (_hasMachineForStage(stage) && isMyRow) ...[
                                    ElevatedButton.icon(
                                      onPressed: (!shiftPaused &&
                                              !isSetupStartPending &&
                                              _canStartOrResumeSetupForUser(
                                                task,
                                                widget.employeeId,
                                              ))
                                          ? () => _startSetup(task, provider)
                                          : null,
                                      style: ElevatedButton.styleFrom(
                                        textStyle:
                                            TextStyle(fontSize: scaled(11.5)),
                                        padding: EdgeInsets.symmetric(
                                          horizontal: scaled(12),
                                          vertical: scaled(10),
                                        ),
                                        minimumSize:
                                            Size(scaled(90), scaled(36)),
                                        visualDensity: isTablet
                                            ? const VisualDensity(
                                                horizontal: -1, vertical: -1)
                                            : null,
                                      ),
                                      icon: const Icon(Icons.build),
                                      label: Text(
                                        _hasUnfinishedSetupForUser(
                                          task,
                                          widget.employeeId,
                                        )
                                            ? 'Продолжить наладку'
                                            : 'Начать наладку',
                                      ),
                                    ),
                                    SizedBox(width: buttonSpacing),
                                  ],
                                  ElevatedButton(
                                      onPressed:
                                          canStartButtonRow ? onStart : null,
                                      style: ElevatedButton.styleFrom(
                                        textStyle:
                                            TextStyle(fontSize: scaled(11.5)),
                                      ),
                                      child: Text(
                                          shouldShowContinueLabel
                                              ? (stateRowUser == UserRunState.problem
                                                  ? '↩ Вернуть в работу'
                                                  : '▶ Продолжить')
                                              : '▶ Начать')),
                                  ElevatedButton(
                                      onPressed: canPauseRow ? onPause : null,
                                      style: ElevatedButton.styleFrom(
                                        textStyle:
                                            TextStyle(fontSize: scaled(11.5)),
                                      ),
                                      child: const Text('⏸ Пауза')),
                                  ElevatedButton(
                                      onPressed: canFinishRow ? onFinish : null,
                                      style: ElevatedButton.styleFrom(
                                        textStyle:
                                            TextStyle(fontSize: scaled(11.5)),
                                      ),
                                      child: Text(
                                          stageExecMode == ExecutionMode.joint
                                              ? '✓ Завершить'
                                              : '✓ Завершить участие')),
                                  ElevatedButton(
                                      onPressed:
                                          canProblemRow ? onProblem : null,
                                      style: ElevatedButton.styleFrom(
                                        textStyle:
                                            TextStyle(fontSize: scaled(11.5)),
                                      ),
                                      child: const Text('⚠ Проблема')),
                                  if (stageExecMode == ExecutionMode.joint &&
                                      task.assignees.isNotEmpty &&
                                      task.assignees.first == widget.employeeId)
                                    ElevatedButton.icon(
                                      onPressed:
                                          shiftPaused ? null : onAddHelper,
                                      style: ElevatedButton.styleFrom(
                                        textStyle:
                                            TextStyle(fontSize: scaled(11.5)),
                                      ),
                                      icon: const Icon(Icons.person_add_alt_1),
                                      label: const Text('Добавить помощника'),
                                    ),
                                  if (stageExecMode == ExecutionMode.joint &&
                                      task.assignees.isNotEmpty &&
                                      task.assignees.first == widget.employeeId)
                                    ...[
                                      for (final helperId in _helperIds(task))
                                        ElevatedButton.icon(
                                          onPressed: shiftPaused
                                              ? null
                                              : () => onRemoveHelper(helperId),
                                          style: ElevatedButton.styleFrom(
                                            textStyle: TextStyle(
                                                fontSize: scaled(11.5)),
                                          ),
                                          icon: const Icon(Icons.person_remove),
                                          label: Text(
                                            'Удалить ${nameFor(helperId)}',
                                          ),
                                        ),
                                    ],
                                  SizedBox(width: gapMedium),
                                  // Обновляем отображение времени для каждой строки каждую секунду
                                  StreamBuilder<DateTime>(
                                    stream: Stream<DateTime>.periodic(
                                        const Duration(seconds: 1),
                                        (_) => DateTime.now()),
                                    builder: (context, _) {
                                      return Text(
                                        'Время: ' + timeText(),
                                        style: TextStyle(fontSize: scaled(12)),
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ),
                            if (stageExecMode == ExecutionMode.joint) ...[
                              SizedBox(width: buttonSpacing),
                              ElevatedButton.icon(
                                onPressed: canShiftControl ? onShift : null,
                                icon: const Icon(Icons.autorenew),
                                style: ElevatedButton.styleFrom(
                                  textStyle:
                                      TextStyle(fontSize: scaled(11.5)),
                                ),
                                label: Text(shiftPaused
                                    ? 'Продолжить пересмену'
                                    : 'Пересмена'),
                              ),
                            ],
                          ],
                        ),
                      ],
                    );
                  }

                  final rows = <Widget>[];
                  final shouldShowOnlyCurrentUserRow =
                      shiftPaused && !task.assignees.contains(widget.employeeId);

                  if (shouldShowOnlyCurrentUserRow) {
                    rows.add(buildControlsFor('Вы', userId: widget.employeeId));
                  } else {
                    if (separateUsers.isNotEmpty) {
                      for (final uid in separateUsers) {
                        rows.add(buildControlsFor('Исполнитель: ' + nameFor(uid),
                            userId: uid));
                        rows.add(SizedBox(height: scaled(8)));
                      }
                    }
                    if (jointUsers.isNotEmpty) {
                      final helperIds = _helperIds(task);
                      final ownerId =
                          task.assignees.isNotEmpty ? task.assignees.first : null;
                      final labels = helperIds.map(nameFor).toList();
                      final label = labels.isEmpty
                          ? (ownerId != null
                              ? 'Исполнитель: ' + nameFor(ownerId)
                              : 'Одиночная или совместная работа')
                          : 'Помощники: ' + labels.join(', ');
                      if (label == 'Одиночная или совместная работа') {
                        // скрываем строку с кнопками для "одиночной/совместной" работы
                      } else if (separateUsers.isEmpty) {
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
                    }
                    final shouldShowCurrentUserRow =
                        !task.assignees.contains(widget.employeeId) &&
                            (canStart || shiftPaused);
                    if (shouldShowCurrentUserRow) {
                      rows.add(buildControlsFor('Вы', userId: widget.employeeId));
                    }
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
              if (task.assignees.isNotEmpty &&
                  stageMode == ExecutionMode.separate)
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
    final hasSetupTimeEvents = related.any((t) =>
        _taskTimeEvents(t).any((event) => event.type == TaskTimeType.setup));
    Duration maxDur = Duration.zero;
    for (final t in related) {
      // Получаем объединённую длительность настройки для каждой задачи
      final d = hasSetupTimeEvents
          ? _setupElapsedFromTimeEvents(t)
          : _setupElapsedAgg(t);
      if (d > maxDur) maxDur = d;
    }
    return maxDur;
  }

  Future<String?> _askComment(String title) async {
    final draft = await _askCommentDraft(title, allowAttachments: false);
    return draft?.text;
  }

  Future<_CommentDraft?> _askCommentDraft(
    String title, {
    bool allowAttachments = false,
  }) async {
    final controller = TextEditingController();
    final previousPending = List<AttachmentDraft>.from(_pendingCommentAttachments);
    _pendingCommentAttachments.clear();
    try {
      return showDialog<_CommentDraft?>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: Text(title),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: controller,
                    decoration: const InputDecoration(hintText: 'Укажите причину'),
                    maxLines: 3,
                  ),
                  if (allowAttachments) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 4,
                      children: [
                        _attachmentActionButton(
                          icon: Icons.photo_outlined,
                          tooltip: 'Фото',
                          scale: 1,
                          onPressed: () => _pickCommentAttachment(
                            source: 'photo',
                            updateDialogState: setDialogState,
                          ),
                        ),
                        _attachmentActionButton(
                          icon: Icons.videocam_outlined,
                          tooltip: 'Видео',
                          scale: 1,
                          onPressed: () => _pickCommentAttachment(
                            source: 'video',
                            updateDialogState: setDialogState,
                          ),
                        ),
                        _attachmentActionButton(
                          icon: Icons.photo_camera_outlined,
                          tooltip: _shouldUseFilePickerForMedia ? 'Файл' : 'Камера',
                          scale: 1,
                          onPressed: () => _pickCommentAttachment(
                            source: 'camera',
                            updateDialogState: setDialogState,
                          ),
                        ),
                        _attachmentActionButton(
                          icon: Icons.attach_file,
                          tooltip: 'Файл',
                          scale: 1,
                          onPressed: () => _pickCommentAttachment(
                            source: 'file',
                            updateDialogState: setDialogState,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _pendingAttachmentsPreview(1, updateDialogState: setDialogState),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                child: const Text('Отмена'),
              ),
              TextButton(
                onPressed: () {
                  final text = controller.text.trim();
                  final attachments = List<AttachmentDraft>.from(_pendingCommentAttachments);
                  if (text.isEmpty && attachments.isEmpty) {
                    Navigator.of(ctx).pop(null);
                    return;
                  }
                  Navigator.of(ctx).pop(_CommentDraft(
                    text: text.isEmpty ? 'Вложение' : text,
                    attachments: attachments,
                  ));
                },
                child: const Text('Сохранить'),
              ),
            ],
          ),
        ),
      );
    } finally {
      _pendingCommentAttachments
        ..clear()
        ..addAll(previousPending);
      controller.dispose();
    }
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
    if (starts.isEmpty) return dones.isNotEmpty;
    final lastStartTs =
        starts.map((c) => c.timestamp).reduce((a, b) => a > b ? a : b);
    final lastDoneTs = dones.isEmpty
        ? 0
        : dones.map((c) => c.timestamp).reduce((a, b) => a > b ? a : b);
    return lastDoneTs > lastStartTs;
  }

  bool _isSetupInProgressForUser(TaskModel task, String userId) {
    final openEvent = _openEventForUser(task, userId);
    if (openEvent != null) {
      return openEvent.type == TaskTimeType.setup;
    }
    final starts = task.comments
        .where((c) => c.type == 'setup_start' && c.userId == userId)
        .toList();
    if (starts.isEmpty) return false;
    final dones = task.comments
        .where((c) => c.type == 'setup_done' && c.userId == userId)
        .toList();
    final lastStartTs =
        starts.map((c) => c.timestamp).reduce((a, b) => a > b ? a : b);
    final lastDoneTs = dones.isEmpty
        ? 0
        : dones.map((c) => c.timestamp).reduce((a, b) => a > b ? a : b);
    return lastStartTs > lastDoneTs;
  }

  bool _hasOpenStartIntentForUser(TaskModel task, String userId) {
    final events = task.comments
        .where((c) =>
            c.userId == userId &&
            (c.type == 'start' ||
                c.type == 'resume' ||
                c.type == 'pause' ||
                c.type == 'problem' ||
                c.type == 'user_done'))
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (events.isEmpty) return false;
    final lastType = events.last.type;
    return lastType == 'start' || lastType == 'resume';
  }

  bool _hasPendingSetupForStage(TaskModel task) {
    final lastStartByUser = <String, int>{};
    final lastDoneByUser = <String, int>{};
    for (final c in task.comments) {
      final uid = c.userId;
      if (uid.isEmpty) continue;
      if (c.type == 'setup_start') {
        final prev = lastStartByUser[uid] ?? 0;
        if (c.timestamp > prev) lastStartByUser[uid] = c.timestamp;
      } else if (c.type == 'setup_done') {
        final prev = lastDoneByUser[uid] ?? 0;
        if (c.timestamp > prev) lastDoneByUser[uid] = c.timestamp;
      }
    }
    for (final entry in lastStartByUser.entries) {
      if (entry.value > (lastDoneByUser[entry.key] ?? 0)) {
        return true;
      }
    }
    return false;
  }

  bool _hasUnfinishedSetupForUser(TaskModel task, String userId) {
    var lastSetupStart = 0;
    var lastSetupDone = 0;
    for (final c in task.comments) {
      if (c.userId != userId) continue;
      if (c.type == 'setup_start' || c.type == 'setup_resume') {
        if (c.timestamp > lastSetupStart) lastSetupStart = c.timestamp;
      } else if (c.type == 'setup_done') {
        if (c.timestamp > lastSetupDone) lastSetupDone = c.timestamp;
      }
    }
    return lastSetupStart > 0 && lastSetupStart > lastSetupDone;
  }

  bool _canStartOrResumeSetupForUser(TaskModel task, String userId) {
    if (_hasProductionStartedForStage(task) || _isSetupCompletedForStage(task)) {
      return false;
    }
    if (_openEventForUser(task, userId)?.type == TaskTimeType.setup) {
      return false;
    }
    final hasPendingSetup = _hasPendingSetupForStage(task);
    if (!hasPendingSetup) return true;
    return _hasUnfinishedSetupForUser(task, userId);
  }

  bool _isSetupCompletedForStage(TaskModel task) {
    if (_hasPendingSetupForStage(task)) return false;
    return task.comments.any((c) => c.type == 'setup_done');
  }

  bool _hasProductionStartedForStage(TaskModel task) {
    if (task.comments.any((c) => c.type == 'start')) return true;
    return _taskTimeEvents(task)
        .any((event) => event.type == TaskTimeType.production);
  }

  Future<void> _startSetup(TaskModel task, TaskProvider provider) async {
    if (_startingSetupTaskIds.contains(task.id)) return;
    setState(() => _startingSetupTaskIds.add(task.id));
    try {
      final latestTask = provider.tasks.firstWhere(
        (t) => t.id == task.id,
        orElse: () => task,
      );
      final resumeOwnSetup = _hasUnfinishedSetupForUser(
        latestTask,
        widget.employeeId,
      );
      final hasOwnSetupTimer =
          _openEventForUser(latestTask, widget.employeeId)?.type ==
              TaskTimeType.setup;
      if (hasOwnSetupTimer ||
          (_hasPendingSetupForStage(latestTask) && !resumeOwnSetup) ||
          _isSetupCompletedForStage(latestTask) ||
          _hasProductionStartedForStage(latestTask)) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Наладка уже запущена. Обновите список и продолжайте работу в активном этапе.'),
        ));
        return;
      }

      if (latestTask.status != TaskStatus.inProgress) {
        final startedAtTs =
            latestTask.startedAt ?? DateTime.now().millisecondsSinceEpoch;
        final started = await provider.updateStatus(
          task.id,
          TaskStatus.inProgress,
          startedAt: startedAtTs,
        );
        if (!started) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Этап уже запущен другим сотрудником. Наладка недоступна для второго запуска.'),
          ));
          return;
        }
      }
      await provider.addCommentAutoUser(
        taskId: task.id,
        type: resumeOwnSetup ? 'setup_resume' : 'setup_start',
        text: resumeOwnSetup
            ? 'Продолжил(а) настройку станка'
            : 'Начал(а) настройку станка',
        userIdOverride: widget.employeeId,
      );
      final setupTask = provider.tasks.firstWhere(
        (t) => t.id == task.id,
        orElse: () => latestTask,
      );
      final participants = _participantsSnapshot(setupTask, widget.employeeId);
      final execMode = _stageExecutionMode(setupTask);
      await provider.recordTimeEvent(
        task: setupTask,
        type: TaskTimeType.setup,
        initiatedBy: widget.employeeId,
        subjectUserId: widget.employeeId,
        workplaceId: setupTask.stageId,
        participantsSnapshot: participants,
        executionMode: execMode != null ? _executionModeCode(execMode) : null,
      );
      final helpers = _helperIds(setupTask);
      if (helpers.isNotEmpty &&
          setupTask.assignees.first == widget.employeeId) {
        for (final helperId in helpers) {
          await provider.recordTimeEvent(
            task: setupTask,
            type: TaskTimeType.setup,
            initiatedBy: widget.employeeId,
            subjectUserId: helperId,
            workplaceId: setupTask.stageId,
            participantsSnapshot: participants,
            executionMode:
                execMode != null ? _executionModeCode(execMode) : null,
            helperId: helperId,
          );
        }
      }
      if (!setupTask.assignees.contains(widget.employeeId)) {
        try {
          await (provider as dynamic).addAssignee(task.id, widget.employeeId);
        } catch (_) {
          final newAssignees = List<String>.from(setupTask.assignees)
            ..add(widget.employeeId);
          await provider.updateAssignees(task.id, newAssignees);
        }
      }
    } finally {
      if (mounted) {
        setState(() => _startingSetupTaskIds.remove(task.id));
      } else {
        _startingSetupTaskIds.remove(task.id);
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
    final problemDraft = await _askCommentDraft(
      'Причина проблемы',
      allowAttachments: true,
    );
    if (problemDraft == null) return;
    final comment = problemDraft.text;
    final saved = await provider.reportProblem(
      taskId: task.id,
      text: comment,
      userId: widget.employeeId,
      participantsSnapshot: _participantsSnapshot(task, widget.employeeId),
      subjectUserIds: [widget.employeeId],
      workplaceId: task.stageId,
      executionMode: _executionModeCode(_execModeForUser(task, widget.employeeId)),
      attachments: problemDraft.attachments,
    );
    if (!saved && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Проблему можно зафиксировать только для этапа в работе.'),
        ),
      );
      return;
    }

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
            .select()
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
            .select()
            .eq('series', order.formSeries!.trim())
            .eq('number', order.newFormNo!)
            .maybeSingle();
        if (res != null && res is Map) {
          row = Map<String, dynamic>.from(res);
        }
      }
      final url = _buildFormImageUrl(
        row?['image_url']?.toString(),
        updatedAt: row?['updated_at']?.toString(),
      );
      _formImageCache[key] = _FormImageCacheEntry(
        url: url,
        details: row,
        fetchedAt: DateTime.now(),
      );
      return url;
    } catch (e) {
      debugPrint('❌ load form image error: $e');
      _formImageCache[key] = _FormImageCacheEntry(
        url: null,
        details: null,
        fetchedAt: DateTime.now(),
      );
      return null;
    } finally {
      _formImagePending.remove(key);
    }
  }

  String? _buildFormImageUrl(String? rawUrl, {String? updatedAt}) {
    final trimmed = rawUrl?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;

    String resolvedUrl = trimmed;
    if (!(trimmed.startsWith('http://') || trimmed.startsWith('https://'))) {
      resolvedUrl = Supabase.instance.client.storage.from('tmc').getPublicUrl(trimmed);
    }

    final dt = DateTime.tryParse(updatedAt ?? '');
    if (dt == null) return resolvedUrl;

    final uri = Uri.tryParse(resolvedUrl);
    if (uri == null) return resolvedUrl;

    final query = Map<String, String>.from(uri.queryParameters);
    query['v'] = dt.millisecondsSinceEpoch.toString();
    return uri.replace(queryParameters: query).toString();
  }

  Future<String?> _getFormImageFuture(OrderModel order) {
    final key = order.id;
    final cached = _formImageCache[key];
    if (cached != null &&
        DateTime.now().difference(cached.fetchedAt) <= _formImageCacheTtl) {
      return Future.value(cached.url);
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

class _FormImageCacheEntry {
  final String? url;
  final Map<String, dynamic>? details;
  final DateTime fetchedAt;

  const _FormImageCacheEntry({
    required this.url,
    required this.details,
    required this.fetchedAt,
  });
}

class _TaskCard extends StatelessWidget {
  final TaskModel task;
  final OrderModel? order;
  final bool selected;
  final bool readyForStage;
  final bool shiftPaused;
  final bool showStageHint;
  final VoidCallback onTap;
  final bool compact;
  final double scale;
  final int sequenceNumber;
  final bool enabled;

  const _TaskCard({
    required this.task,
    required this.order,
    required this.onTap,
    this.selected = false,
    this.readyForStage = false,
    this.shiftPaused = false,
    this.showStageHint = false,
    this.compact = false,
    this.scale = 1.0,
    this.sequenceNumber = 0,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
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
            ? 'Можно начинать: предыдущий этап начат'
            : 'Ожидает начала предыдущего этапа')
        : null;
    final Color readyColor = Colors.green.shade600;
    final Color stageHintColor =
        readyForStage ? readyColor : Colors.grey.shade600;
    final Color disabledColor = const Color(0xFF9CA3AF);

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
      color: !enabled
          ? const Color(0xFFF3F4F6)
          : (readyForStage ? readyColor.withOpacity(0.05) : Colors.white),
      child: ListTile(
        onTap: enabled ? onTap : null,
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
            color: enabled ? Colors.black87 : disabledColor,
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
          width: scaled(28),
          height: scaled(28),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: enabled ? const Color(0xFFDBEAFE) : const Color(0xFFE5E7EB),
            shape: BoxShape.circle,
          ),
          child: Text(
            sequenceNumber > 0 ? sequenceNumber.toString() : '•',
            style: TextStyle(
              color: enabled ? const Color(0xFF1D4ED8) : const Color(0xFF6B7280),
              fontWeight: FontWeight.w700,
              fontSize: statusSize,
            ),
          ),
        ),
      ),
    );
  }
}

class _TaskListBadge {
  final String label;
  final Color color;
  const _TaskListBadge(this.label, this.color);
}

_TaskListBadge _taskListBadge({
  required TaskModel task,
  required bool readyForStage,
  required bool shiftPaused,
}) {
  if (task.status == TaskStatus.completed) {
    return _TaskListBadge('Завершено', Colors.green);
  }
  if (task.status == TaskStatus.problem) {
    return _TaskListBadge('Проблема', Colors.redAccent);
  }
  if (shiftPaused) {
    return _TaskListBadge('Пересмена', Colors.deepPurple);
  }
  if (task.status == TaskStatus.paused) {
    return _TaskListBadge('Пауза', Colors.grey);
  }
  if (task.status == TaskStatus.inProgress) {
    return _TaskListBadge('В работе', Colors.blue);
  }
  if (readyForStage) {
    return _TaskListBadge('Можно начинать', Colors.green.shade700);
  }
  return _TaskListBadge('Ожидает этап', Colors.orange.shade700);
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
    final bool canAddHelper = isOwner &&
        stageMode == ExecutionMode.joint;

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

Future<_QuantityInput?> _askQuantity(
  BuildContext context, {
  String? unit,
  bool allowPaperEdit = false,
  double? initialQuantity,
}) async {
  final totalController = TextEditingController(
    text: initialQuantity != null && initialQuantity > 0
        ? formatTaskInitialQuantity(initialQuantity)
        : '',
  );
  final unitLabel = (unit ?? '').trim();
  const paperEditValue = '__open_paper_edit__';
  final v = await showDialog<_QuantityInput?>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        title: const Text('Количество выполнено'),
        content: TextField(
          controller: totalController,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            hintText: unitLabel.isNotEmpty
                ? 'Введите количество в $unitLabel'
                : 'Введите количество экземпляров',
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          if (allowPaperEdit)
            TextButton(
              onPressed: () => Navigator.pop(
                ctx,
                const _QuantityInput(
                  quantity: 0,
                  displayText: paperEditValue,
                  openPaperEditor: true,
                ),
              ),
              child: const Text('Изменить бумагу'),
            ),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          ElevatedButton(
            onPressed: () {
              final raw = totalController.text.trim();
              final n = double.tryParse(raw.replaceAll(',', '.'));
              if (n == null) return;
              final displayQuantity = formatTaskInitialQuantity(n);
              final display = unitLabel.isNotEmpty
                  ? '$displayQuantity $unitLabel'
                  : displayQuantity;
              Navigator.pop(
                ctx,
                _QuantityInput(quantity: n, displayText: display),
              );
            },
            child: const Text('OK'),
          ),
        ],
      );
    },
  );
  totalController.dispose();
  if (v == null) return null;
  if (v.openPaperEditor || v.displayText == paperEditValue) {
    return const _QuantityInput(
      quantity: 0,
      displayText: '',
      openPaperEditor: true,
    );
  }
  return v;
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
