import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../orders/order_model.dart';
import '../orders/id_format.dart';
import '../orders/orders_provider.dart';
import '../orders/orders_repository.dart';
import '../personnel/employee_model.dart';
import '../personnel/personnel_provider.dart';
import '../personnel/workplace_model.dart';
import '../analytics/analytics_provider.dart';
import '../production_planning/template_provider.dart';
import '../production_planning/template_model.dart';
import 'task_model.dart';
import 'task_provider.dart';
import '../common/pdf_view_screen.dart';
import '../../services/storage_service.dart';
import '../warehouse/warehouse_provider.dart';
import '../warehouse/tmc_model.dart';
// Additional helpers for time formatting and aggregated timers

class TasksScreen extends StatefulWidget {
  final String employeeId;
  const TasksScreen({super.key, required this.employeeId});

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

// === Execution mode per stage/assignee =======================================
enum ExecutionMode { solo, separate, joint }

ExecutionMode? _parseExecutionModeLabel(String raw) {
  final t = raw.toLowerCase();
  if (t.contains('solo') || t.contains('один') || t.contains('одиноч')) {
    return ExecutionMode.solo;
  }
  if (t.contains('joint') || t.contains('совмест')) {
    return ExecutionMode.joint;
  }
  if (t.contains('separ') || t.contains('отдель')) {
    return ExecutionMode.separate;
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
      return ExecutionMode.solo;
    }
    // separate stage
    return ExecutionMode.separate;
  }

  final cm =
      task.comments.where((c) => c.type == 'exec_mode' && c.userId == userId);
  if (cm.isNotEmpty) {
    final t = cm.last.text.toLowerCase();
    if (t.contains('solo') || t.contains('один') || t.contains('одиноч')) {
      return ExecutionMode.solo;
    }
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
      return 'solo';
    case ExecutionMode.separate:
      return 'separate';
    case ExecutionMode.joint:
      return 'joint';
  }
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

enum UserRunState { idle, active, paused, finished, problem }

UserRunState _userRunState(TaskModel task, String userId) {
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

Duration _userElapsed(TaskModel task, String userId) {
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

String _workplaceName(PersonnelProvider personnel, String stageId) {
  try {
    final wp = personnel.workplaces.firstWhere((w) => w.id == stageId);
    if (wp.name.isNotEmpty) return wp.name;
  } catch (_) {}
  return stageId;
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
bool _isFirstPendingStage(
    TaskProvider tasks, PersonnelProvider personnel, TaskModel task) {
  // Все задачи этого заказа
  final all = tasks.tasks.where((t) => t.orderId == task.orderId).toList();
  if (all.isEmpty) return true;

  // Сгруппировать по этапу; интересуют только этапы, где есть не completed
  final stages = <String, bool>{}; // stageId -> hasPending
  for (final t in all) {
    final pending = t.status != TaskStatus.completed;
    stages[t.stageId] = (stages[t.stageId] ?? false) || pending;
  }

  // Отфильтровать только pending этапы
  final pendingStageIds =
      stages.entries.where((e) => e.value).map((e) => e.key).toList();
  if (pendingStageIds.isEmpty) return true;

  final orderedStages = tasks.stageSequenceForOrder(task.orderId) ?? const [];
  if (orderedStages.isNotEmpty) {
    final indexMap = <String, int>{};
    for (var i = 0; i < orderedStages.length; i++) {
      indexMap.putIfAbsent(orderedStages[i], () => i);
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
  return task.stageId == firstPendingStageId;
}

Future<ExecutionMode?> _askExecMode(BuildContext context,
    {ExecutionMode initial = ExecutionMode.separate,
    bool allowSolo = false,
    bool allowJoint = true,
    bool allowSeparate = true}) async {
  ExecutionMode? mode = initial;
  final res = await showDialog<ExecutionMode?>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Режим исполнения'),
      content: StatefulBuilder(
        builder: (ctx, setState) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (allowSolo)
              RadioListTile<ExecutionMode>(
                title: const Text('Одиночное исполнение'),
                value: ExecutionMode.solo,
                groupValue: mode,
                onChanged: (v) => setState(() => mode = v),
              ),
            if (allowJoint)
              RadioListTile<ExecutionMode>(
                title: const Text('Совместное исполнение'),
                value: ExecutionMode.joint,
                groupValue: mode,
                onChanged: (v) => setState(() => mode = v),
              ),
            if (allowSeparate)
              RadioListTile<ExecutionMode>(
                title: const Text('Отдельный исполнитель'),
                value: ExecutionMode.separate,
                groupValue: mode,
                onChanged: (v) => setState(() => mode = v),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Отмена')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, mode),
            child: const Text('Выбрать')),
      ],
    ),
  );
  return res;
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

class _FlexoPaintMeta {
  final String rowId;
  final String name;
  final String? info;
  final double previousGrams;
  final TmcModel? tmc;

  const _FlexoPaintMeta({
    required this.rowId,
    required this.name,
    this.info,
    this.previousGrams = 0,
    this.tmc,
  });
}

class _FlexoPaintUsageEntry {
  final _FlexoPaintMeta meta;
  final double grams;

  const _FlexoPaintUsageEntry({required this.meta, required this.grams});

  String get rowId => meta.rowId;
  String get name => meta.name;
  String? get info => meta.info;
  double get previousGrams => meta.previousGrams;
  TmcModel? get tmc => meta.tmc;
}

class _PaintShipmentRecord {
  final String itemId;
  final double qty;

  const _PaintShipmentRecord({required this.itemId, required this.qty});
}

class _TasksScreenState extends State<TasksScreen>
    with AutomaticKeepAliveClientMixin<TasksScreen> {
  @override
  bool get wantKeepAlive => true;
  // Compatibility shim: legacy takenByAnother flag removed
  bool get takenByAnother => false;

  final TextEditingController _chatController = TextEditingController();
  String? _selectedWorkplaceId;
  TaskModel? _selectedTask;
  final Map<String, String?> _formImageCache = {};
  final Map<String, Future<String?>> _formImagePending = {};
  final Map<String, Map<String, _StageComment>> _orderCommentsCache = {};
  final OrdersRepository _ordersRepository = OrdersRepository();
  String get _widKey => 'ws-${widget.employeeId}-wid';
  String get _tidKey => 'ws-${widget.employeeId}-tid';
  static const Map<TaskStatus, String> _statusLabels = {
    TaskStatus.waiting: 'В ожидании',
    TaskStatus.inProgress: 'В работе',
    TaskStatus.paused: 'На паузе',
    TaskStatus.completed: 'Завершенные',
  };
  TaskStatus _selectedStatus = TaskStatus.waiting;

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

  double _readPaintGrams(Map<String, dynamic> row) {
    double? parse(dynamic raw) {
      if (raw == null) return null;
      if (raw is num) return raw.toDouble();
      if (raw is String) {
        final normalized = raw.replaceAll(',', '.').trim();
        if (normalized.isEmpty) return null;
        final parsed = double.tryParse(normalized);
        if (parsed != null) return parsed;
      }
      return null;
    }

    const gramKeys = ['qty_g', 'qtyG', 'quantity_g', 'quantityG'];
    for (final key in gramKeys) {
      final value = parse(row[key]);
      if (value != null) return value;
    }

    const kgKeys = ['qty_kg', 'qtyKg', 'quantity_kg', 'quantityKg'];
    for (final key in kgKeys) {
      final value = parse(row[key]);
      if (value != null) return value * 1000.0;
    }

    const genericKeys = ['qty', 'quantity'];
    for (final key in genericKeys) {
      final value = parse(row[key]);
      if (value != null) return value;
    }
    return 0;
  }

  String _formatGrams(double grams) {
    if (grams <= 0) return '';
    if ((grams - grams.round()).abs() < 0.0001) {
      return grams.round().toString();
    }
    return grams.toStringAsFixed(2);
  }

  double _convertGramsToUnit(double grams, String? unit) {
    if (grams <= 0) return 0;
    final normalized = unit?.toLowerCase().trim() ?? '';
    if (normalized.contains('кг') || normalized == 'kg') {
      return grams / 1000.0;
    }
    if (normalized.contains('тонн')) {
      return grams / 1000000.0;
    }
    return grams;
  }

  List<_FlexoPaintMeta> _prepareFlexoPaintMetas(
      List<Map<String, dynamic>> rows, WarehouseProvider warehouse) {
    final metas = <_FlexoPaintMeta>[];
    for (final row in rows) {
      final rawId = row['id'] ?? row['paint_id'] ?? row['order_paint_id'];
      final nameRaw =
          (row['name'] ?? row['paint_name'] ?? row['title'] ?? '').toString();
      final name = nameRaw.trim();
      if (rawId == null || name.isEmpty) {
        continue;
      }
      final infoRaw = (row['info'] ?? '').toString().trim();
      final grams = _readPaintGrams(row);
      final tmc = warehouse.getPaintByName(name);
      metas.add(_FlexoPaintMeta(
        rowId: rawId.toString(),
        name: name,
        info: infoRaw.isEmpty ? null : infoRaw,
        previousGrams: grams,
        tmc: tmc,
      ));
    }
    return metas;
  }

  Future<List<_FlexoPaintUsageEntry>?> _askPaintUsageDialog(
      List<_FlexoPaintMeta> metas) async {
    final controllers = <String, TextEditingController>{
      for (final meta in metas)
        meta.rowId: TextEditingController(text: _formatGrams(meta.previousGrams))
    };
    Map<String, String?> fieldErrors = {};
    try {
      final result = await showDialog<List<_FlexoPaintUsageEntry>>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            title: const Text('Фактический расход краски'),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                      'Укажите фактический расход для каждой краски (в граммах).'),
                  const SizedBox(height: 12),
                  for (final meta in metas)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(meta.name,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600)),
                          if ((meta.info ?? '').isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                meta.info!,
                                style: const TextStyle(
                                    color: Colors.black54, fontSize: 12),
                              ),
                            ),
                          TextField(
                            controller: controllers[meta.rowId],
                            keyboardType:
                                const TextInputType.numberWithOptions(decimal: true),
                            decoration: InputDecoration(
                              labelText: 'Расход, г',
                              suffixText: meta.tmc?.unit,
                              errorText: fieldErrors[meta.rowId],
                            ),
                          ),
                          if (meta.tmc == null)
                            const Padding(
                              padding: EdgeInsets.only(top: 4),
                              child: Text(
                                'Позиция не найдена на складе',
                                style: TextStyle(
                                    color: Colors.redAccent, fontSize: 12),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () {
                  final nextErrors = <String, String?>{};
                  final collected = <_FlexoPaintUsageEntry>[];
                  for (final meta in metas) {
                    final controller = controllers[meta.rowId]!;
                    final text = controller.text.trim();
                    if (text.isEmpty) {
                      nextErrors[meta.rowId] = 'Укажите расход';
                      continue;
                    }
                    final normalized = text.replaceAll(',', '.');
                    final value = double.tryParse(normalized);
                    if (value == null || value < 0) {
                      nextErrors[meta.rowId] = 'Некорректное значение';
                      continue;
                    }
                    collected
                        .add(_FlexoPaintUsageEntry(meta: meta, grams: value));
                  }
                  if (nextErrors.isNotEmpty) {
                    setState(() {
                      fieldErrors = nextErrors;
                    });
                    return;
                  }
                  Navigator.of(ctx).pop(collected);
                },
                child: const Text('Сохранить'),
              ),
            ],
          ),
        ),
      );
      return result;
    } finally {
      for (final controller in controllers.values) {
        controller.dispose();
      }
    }
  }

  Future<bool> _applyFlexoPaintUsage(TaskModel task,
      List<_FlexoPaintUsageEntry> entries, WarehouseProvider warehouse) async {
    if (entries.isEmpty) {
      return true;
    }

    final shipments = <_PaintShipmentRecord>[];
    final order = _orderById(task.orderId);
    final customerName = order?.customer ??
        (await _ordersRepository.getOrderCustomer(task.orderId)) ??
        '';
    final writeoffReason =
        customerName.isNotEmpty ? customerName : 'Заказ ${task.orderId}';
    try {
      for (final entry in entries) {
        final grams = entry.grams;
        final meta = entry.meta;
        final tmc = meta.tmc ?? warehouse.getPaintByName(meta.name);
        if (tmc == null) {
          throw Exception('paint_not_found:${meta.name}');
        }
        final qtyForUnit = _convertGramsToUnit(grams, tmc.unit);
        if (qtyForUnit > 0) {
          await warehouse.registerShipment(
            id: tmc.id,
            type: 'paint',
            qty: qtyForUnit,
            reason: writeoffReason,
          );
          shipments
              .add(_PaintShipmentRecord(itemId: tmc.id, qty: qtyForUnit));
        }
      }

      final updates = entries
          .map((e) => PaintUsageUpdate(
                paintRowId: e.rowId,
                name: e.name,
                grams: e.grams,
                info: e.info,
              ))
          .toList();
      await _ordersRepository.applyPaintUsage(
          orderId: task.orderId, usages: updates);
      try {
        await context.read<OrdersProvider>().refresh();
      } catch (_) {}
      return true;
    } catch (error) {
      for (final shipment in shipments.reversed) {
        try {
          await warehouse.registerReturn(
              id: shipment.itemId, type: 'paint', qty: shipment.qty);
        } catch (_) {}
      }
      if (!mounted) return false;
      final text = error.toString();
      String message;
      if (text.contains('paint_not_found')) {
        final name = text.split(':').last;
        message = name.isNotEmpty
            ? 'Краска $name не найдена на складе. Обновите остатки.'
            : 'Краска не найдена на складе. Обновите остатки.';
      } else if (text.contains('Недостаточно')) {
        message = text;
      } else {
        message = 'Не удалось обработать расход краски: $error';
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
      return false;
    }
  }

  Future<bool?> _handleFlexoPaintUsage(TaskModel task) async {
    final personnel = context.read<PersonnelProvider>();
    if (!_isFlexoStageId(personnel, task.stageId)) {
      return true;
    }

    List<Map<String, dynamic>> paints;
    try {
      paints = await _ordersRepository.getPaints(task.orderId);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось загрузить краски: $error')),
        );
      }
      return false;
    }

    if (paints.isEmpty) {
      return true;
    }

    final warehouse = context.read<WarehouseProvider>();
    if (warehouse.allTmc.isEmpty) {
      try {
        await warehouse.fetchTmc();
      } catch (_) {}
    }

    final metas = _prepareFlexoPaintMetas(paints, warehouse);
    if (metas.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Для заказа не найдены позиции красок на складе.')));
      }
      return false;
    }

    final entries = await _askPaintUsageDialog(metas);
    if (entries == null) {
      return null;
    }

    final success = await _applyFlexoPaintUsage(task, entries, warehouse);
    return success;
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
        return 'Начал(а) настройку станка';
      case 'setup_done':
        return 'Завершил(а) настройку станка';
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
        final normalized = comment.text.toLowerCase();
        if (normalized.contains('solo') ||
            normalized.contains('один') ||
            normalized.contains('одиноч')) {
          return 'Режим: одиночное исполнение';
        }
        if (normalized.contains('joint') || normalized.contains('совмест')) {
          return 'Режим: совместное исполнение';
        }
        return 'Режим: отдельный исполнитель';
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

    if (stageMode == ExecutionMode.solo &&
        !alreadyAssigned &&
        task.assignees.isNotEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Этап выполняется одним сотрудником. Присоединиться нельзя.')));
      }
      return;
    }

    if (stageMode == null) {
      final mode = await _askExecMode(context,
          initial: ExecutionMode.solo,
          allowSolo: task.assignees.isEmpty,
          allowJoint: true,
          allowSeparate: true);
      if (mode == null) return;
      stageMode = mode;
      await provider.addComment(
        taskId: task.id,
        type: 'exec_mode_stage',
        text: _executionModeCode(mode),
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
      // solo or separate performer immediately starts; write a 'start' comment
      await provider.addCommentAutoUser(
        taskId: task.id,
        type: 'start',
        text: 'Начал(а) этап',
        userIdOverride: userId,
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

    final media = MediaQuery.of(context);
    final bool isTablet =
        media.size.shortestSide >= 600 && media.size.shortestSide < 1100;
    final bool isCompactTablet = isTablet && media.size.shortestSide <= 850;

    // Делайте интерфейс более читаемым: чуть увеличиваем базовый масштаб
    // вместо сильного уменьшения на планшетах.
    final double layoutScale = isCompactTablet
        ? 1.0 // компактные планшеты — без даунскейла
        : (isTablet
            ? 1.05 // обычные планшеты — легкое увеличение
            : 1.1); // десктопы/веб — заметное увеличение

    // Поддерживаем крупный текст даже если системный textScaleFactor маленький.
    final double textScaleFactor = math.max(
      media.textScaleFactor,
      isCompactTablet
          ? 1.08
          : (isTablet
              ? 1.1
              : 1.15),
    );

    final double scale = layoutScale;

    double scaled(double value) => value * layoutScale;
    final double outerPadding = scaled(16);
    final double columnGap = scaled(16);
    final double cardPadding = scaled(12);
    final double cardRadius = scaled(12);
    final double sectionSpacing = scaled(12);
    final double smallSpacing = scaled(4);
    final double largeSpacing = scaled(24);
    final double chipSpacing = scaled(8);

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
      _selectedWorkplaceId = savedWid ?? _selectedWorkplaceId;
      _selectedWorkplaceId = _selectedWorkplaceId ?? workplaces.first.id;
      _persistWorkplace(_selectedWorkplaceId);
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

    final tasksForWorkplace = taskProvider.tasks
        .where((t) => t.stageId == _selectedWorkplaceId)
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

    final sectionedTasks = tasksForWorkplace
        .where((t) => _sectionForTask(t) == _selectedStatus)
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

    final scaffold = Scaffold(
      key: PageStorageKey('TasksScreen-${widget.employeeId}'),
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text('Производственный терминал'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0.5,
      ),
      body: Padding(
        padding: EdgeInsets.all(outerPadding),
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
                      padding: EdgeInsets.all(cardPadding),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(cardRadius),
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
                          Text(
                            'Список заданий',
                            style: TextStyle(
                              fontSize: scaled(18),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: smallSpacing),
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
                            style: TextStyle(
                              color: Colors.grey,
                              fontSize: scaled(13),
                            ),
                          ),
                          SizedBox(height: sectionSpacing),
                          Wrap(
                            spacing: chipSpacing,
                            runSpacing: chipSpacing,
                            children: [
                              for (final entry in _statusLabels.entries)
                                ChoiceChip(
                                  label: Text(
                                    entry.value,
                                    style: TextStyle(fontSize: scaled(13)),
                                  ),
                                  selected: _selectedStatus == entry.key,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  visualDensity: isTablet
                                      ? const VisualDensity(
                                          horizontal: -1, vertical: -1)
                                      : VisualDensity.standard,
                                  labelPadding: EdgeInsets.symmetric(
                                    horizontal: scaled(8),
                                    vertical: scaled(4),
                                  ),
                                  onSelected: (selected) {
                                    if (!selected) return;
                                    setState(() {
                                      _selectedStatus = entry.key;
                                      if (_selectedTask != null &&
                                          _sectionForTask(_selectedTask!) !=
                                              _selectedStatus) {
                                        _selectedTask = null;
                                        _persistTask(null);
                                      }
                                    });
                                  },
                                ),
                            ],
                          ),
                          SizedBox(height: sectionSpacing),
                          Expanded(
                            child: sectionedTasks.isEmpty
                                ? const Center(
                                    child: Text(
                                      'Нет заданий в этой категории',
                                      textAlign: TextAlign.center,
                                    ),
                                  )
                                : ListView(
                                    children: [
                                      for (final task in sectionedTasks)
                                        _TaskCard(
                                          task: task,
                                          order: findOrder(task.orderId),
                                          selected:
                                              _selectedTask?.id == task.id,
                                          scale: scale,
                                          onTap: () {
                                            _persistTask(task.id);
                                            setState(() {
                                              _selectedTask = task;
                                              _selectedStatus =
                                                  _sectionForTask(task);
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
                  SizedBox(height: largeSpacing),
                  Text(
                    'Рабочее место:',
                    style: TextStyle(fontSize: scaled(14)),
                  ),
                  SizedBox(height: scaled(8)),
                  DropdownButton<String>(
                    value: _selectedWorkplaceId,
                    isDense: isTablet,
                    style:
                        TextStyle(fontSize: scaled(13), color: Colors.black87),
                    itemHeight: math.max(
                      scaled(44),
                      kMinInteractiveDimension,
                    ),
                    items: [
                      for (final w in workplaces)
                        DropdownMenuItem(
                          value: w.id,
                          child: Text(w.name,
                              style: TextStyle(fontSize: scaled(13))),
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
            ),
            SizedBox(width: columnGap),

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
                      _buildDetailsPanel(
                        selectedOrder,
                        selectedWorkplace,
                        templateProvider.templates,
                        scale,
                      ),
                    if (currentTask != null && selectedWorkplace != null)
                      SizedBox(height: scaled(16)),
                    if (currentTask != null && selectedWorkplace != null)
                      _buildControlPanel(
                        currentTask,
                        selectedWorkplace,
                        taskProvider,
                        scale,
                        isTablet,
                      ),
                  ],
                ),
              ),
            ),
          ],
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

  Widget _buildDetailsPanel(OrderModel order, WorkplaceModel stage,
      List<TemplateModel> templates, double scale) {
    final product = order.product;
    final templateLabel =
        (order.stageTemplateId != null && order.stageTemplateId!.isNotEmpty)
            ? (_resolveTemplateName(order.stageTemplateId, templates) ??
                (templates.isEmpty ? 'загрузка...' : 'не найден'))
            : null;
    double scaled(double value) => value * scale;
    final double panelPadding = scaled(16);
    final double radius = scaled(12);
    final double mediumSpacing = scaled(16);
    final double smallSpacing = scaled(4);
    final double infoSpacing = scaled(6);
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
      return Padding(
        padding: EdgeInsets.only(bottom: infoSpacing),
        child: Text.rich(
          TextSpan(
            text: '$label: ',
            style: TextStyle(
              fontSize: scaled(13),
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
            children: [
              TextSpan(
                text: display,
                style: TextStyle(
                  fontSize: scaled(13),
                  fontWeight: FontWeight.w400,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
        ),
      );
    }

    Widget infoMultiline(String label, String value) {
      final display = value.isNotEmpty ? value : '—';
      return Padding(
        padding: EdgeInsets.only(bottom: infoSpacing),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: scaled(13),
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
            SizedBox(height: scaled(2)),
            Text(
              display,
              style: TextStyle(fontSize: scaled(13), color: Colors.black87),
            ),
          ],
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
                fontWeight: FontWeight.bold,
                fontSize: scaled(14),
              ),
            ),
            SizedBox(height: smallSpacing),
            ...content,
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
      generalSection.add(infoLine('Заказчик', order.customer));
    }
    if (order.manager.isNotEmpty) {
      generalSection.add(infoLine('Менеджер', order.manager));
    }
    generalSection.add(infoLine('Дата заказа', formatDate(order.orderDate)));
    generalSection.add(infoLine('Срок выполнения', formatDate(order.dueDate)));
    generalSection.add(infoLine('Статус заказа', statusLabel(order)));
    if (order.comments.isNotEmpty) {
      generalSection.add(infoMultiline('Комментарии', order.comments));
    }
    generalSection
        .add(infoLine('Договор подписан', order.contractSigned ? 'Да' : 'Нет'));
    generalSection
        .add(infoLine('Оплата', order.paymentDone ? 'Проведена' : 'Нет'));
    if (order.actualQty != null) {
      generalSection
          .add(infoLine('Фактическое количество', formatQty(order.actualQty)));
    }
    if (templateLabel != null) {
      generalSection.add(infoLine('Шаблон этапов', templateLabel));
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
      final double previewSize = scaled(110);
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
              'Форма',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: scaled(14),
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
                      orderNumber != '—' ? orderNumber : order.id,
                      style: TextStyle(
                        fontSize: scaled(18),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: smallSpacing),
                    const Text('Детали производственного задания'),
                    SizedBox(height: mediumSpacing),
                    if (generalSection.isNotEmpty)
                      section('Основное', generalSection),
                    if (productSection.isNotEmpty)
                      section('Продукт', productSection),
                    if (materialSection.isNotEmpty)
                      section('Материал', materialSection),
                    if (equipmentSection.isNotEmpty)
                      section('Комплектация', equipmentSection),
                    if (formSection.isNotEmpty) formSectionWidget(),
                    if (hasPdf)
                      section('Файлы', [
                        Row(
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
                      ]),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(height: scaled(36)),
                    const Text('Этап производства',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    Text(stage.name, style: TextStyle(fontSize: scaled(14))),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: mediumSpacing),
          _buildStageList(order, scale),
        ],
      ),
    );
  }

  /// Список этапов производства с иконками выполнено/ожидание.
  Widget _buildStageList(OrderModel order, double scale) {
    final taskProvider = context.read<TaskProvider>();
    final personnel = context.read<PersonnelProvider>();
    final tasksForOrder =
        taskProvider.tasks.where((t) => t.orderId == order.id).toList();

    double scaled(double value) => value * scale;
    final double rowPadding = scaled(2);
    final double iconSize = scaled(16);
    final double horizontalGap = scaled(4);
    final double verticalSpacing = scaled(6);
    final TextStyle stageTextStyle = TextStyle(fontSize: scaled(14));

    final stageIds = <String>{};
    for (final t in tasksForOrder) {
      stageIds.add(t.stageId);
    }
    if (stageIds.isEmpty) return const SizedBox.shrink();

    final sequence =
        taskProvider.stageSequenceForOrder(order.id) ?? const <String>[];

    final orderedStageIds = <String>[];
    if (sequence.isNotEmpty) {
      for (final id in sequence) {
        if (stageIds.contains(id)) {
          orderedStageIds.add(id);
        }
      }
      if (orderedStageIds.length != stageIds.length) {
        final extras = stageIds
            .where((id) => !orderedStageIds.contains(id))
            .toList()
          ..sort();
        orderedStageIds.addAll(extras);
      }
    } else {
      orderedStageIds.addAll(stageIds);
      orderedStageIds.sort((a, b) {
        String name(String id) {
          try {
            final w = personnel.workplaces.firstWhere((w) => w.id == id);
            return (w.name.isNotEmpty ? w.name : id).toLowerCase();
          } catch (_) {
            return id.toLowerCase();
          }
        }

        return name(a).compareTo(name(b));
      });
      _ensureFlexoOrdering(orderedStageIds, personnel);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Этапы производства',
            style:
                TextStyle(fontWeight: FontWeight.bold, fontSize: scaled(14))),
        SizedBox(height: verticalSpacing),
        for (final id in orderedStageIds)
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
                padding: EdgeInsets.symmetric(vertical: rowPadding),
                child: Row(
                  children: [
                    Icon(
                      completed ? Icons.check_circle : Icons.access_time,
                      size: iconSize,
                      color: completed ? Colors.green : Colors.orange,
                    ),
                    SizedBox(width: horizontalGap),
                    Text(stage.name, style: stageTextStyle),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _buildControlPanel(TaskModel task, WorkplaceModel stage,
      TaskProvider provider, double scale, bool isTablet) {
    // === Derived state & permissions ===
    final List<TaskModel> allRelated = _relatedTasks(provider, task);
    final int activeCount = _activeExecutorsCountForStage(provider, task);
    final bool shiftPaused = _isShiftPausedForStage(provider, task);
    final dynamic _rawCap = (stage as dynamic).maxConcurrentWorkers;
    final int capacity = (_rawCap is num ? _rawCap.toInt() : 1);
    final int effCap = capacity <= 0 ? 1 : capacity;
    final ExecutionMode? stageMode = _stageExecutionMode(task);
    final ExecutionMode myExecMode = _execModeForUser(task, widget.employeeId);
    // Consider a user an assignee only if they are explicitly assigned AND executing in
    // separate mode. Helpers (joint execution) should not gain full control over the task.
    final bool isAssignee = task.assignees.isEmpty ||
        (task.assignees.contains(widget.employeeId) &&
            (myExecMode == ExecutionMode.separate ||
                myExecMode == ExecutionMode.solo));

    // Старт возможен, если задача ждёт/на паузе/с проблемой
    double scaled(double value) => value * scale;
    final double panelPadding = scaled(12);
    final double gapSmall = scaled(6);
    final double gapMedium = scaled(12);
    final double buttonSpacing = scaled(8);
    final double spacing = scaled(8);
    final double mediumSpacing = scaled(16);
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
        stageMode != ExecutionMode.solo;
    final bool stageModeAllowsJoin =
        stageMode != ExecutionMode.solo || alreadyAssigned || isFirstAssignee;
    final bool canStart = (((isFirstAssignee ||
                alreadyAssigned ||
                canAutoAssign)) &&
            (task.status == TaskStatus.waiting ||
                task.status == TaskStatus.paused ||
                task.status == TaskStatus.problem ||
                (task.status == TaskStatus.inProgress && _slotAvailable()))) &&
        _isFirstPendingStage(context.read<TaskProvider>(),
            context.read<PersonnelProvider>(), task) &&
        stageModeAllowsJoin &&
        !shiftPaused;

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
          Text('Управление заданием',
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
                      label: const Text('Настройка станка'),
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
                      child: const Text('Завершить настройку станка'),
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
              // ⏱ Время этапа
              Align(
                alignment: Alignment.centerRight,
                child: StreamBuilder<DateTime>(
                  stream: Stream<DateTime>.periodic(
                      const Duration(seconds: 1), (_) => DateTime.now()),
                  builder: (context, _) {
                    final d = _elapsed(task);
                    String two(int n) => n.toString().padLeft(2, '0');
                    final s =
                        '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
                    return Text('Время этапа: ' + s,
                        style: TextStyle(fontSize: scaled(13)));
                  },
                ),
              ),
              SizedBox(height: gapSmall),

              // ==== Управление исполнением ===
              Builder(
                builder: (context) {
                  final ExecutionMode? stageExecMode = stageMode;
                  final separateUsers = task.assignees
                      .where((id) {
                        final mode = _execModeForUser(task, id);
                        return mode == ExecutionMode.separate ||
                            mode == ExecutionMode.solo;
                      })
                      .toList();
                  final jointUsers = task.assignees
                      .where((id) =>
                          _execModeForUser(task, id) == ExecutionMode.joint)
                      .toList();

                  Widget buildControlsFor(String? label,
                      {List<String>? jointGroup, String? userId}) {
                    final tp = context.read<TaskProvider>();
                    final activeCount = _activeExecutorsCountForStage(tp, task);
                    final stage =
                        context.read<PersonnelProvider>().workplaces.firstWhere(
                              (w) => w.id == task.stageId,
                              orElse: () => WorkplaceModel(
                                  id: '', name: '', positionIds: const []),
                            );
                    final rawCap = (stage as dynamic).maxConcurrentWorkers;
                    final effCap = (rawCap is num ? rawCap.toInt() : 1);
                    final canStartCapacity =
                        activeCount < (effCap <= 0 ? 1 : effCap);

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
                    // (разрешаем возобновление). Для чужих строк кнопка
                    // недоступна. Это предотвращает повторные старты и
                    // обнуление таймера.
                    final bool canStartButtonRow = isMyRow &&
                        canStart &&
                        (stateRowUser == UserRunState.idle ||
                            stateRowUser == UserRunState.paused ||
                            stateRowUser == UserRunState.problem);
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

                    Future<void> onStart() async {
                      // Sequential stage guard
                      if (!_isFirstPendingStage(context.read<TaskProvider>(),
                          context.read<PersonnelProvider>(), task)) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                              content: Text(
                                  'Сначала выполните предыдущий этап заказа')));
                        }
                        return;
                      }

                      ExecutionMode? selectedMode = stageExecMode;
                      final alreadyAssigned =
                          task.assignees.contains(widget.employeeId);
                      if (selectedMode == ExecutionMode.solo &&
                          !alreadyAssigned &&
                          task.assignees.isNotEmpty) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                              content: Text(
                                  'Этап выполняется одним сотрудником. Присоединиться нельзя.')));
                        }
                        return;
                      }

                      if (task.assignees.isEmpty) {
                        final mode = await _askExecMode(context,
                            initial: ExecutionMode.solo,
                            allowSolo: true,
                            allowJoint: true,
                            allowSeparate: true);
                        if (mode == null) return;
                        selectedMode = mode;
                        await context.read<TaskProvider>().addComment(
                              taskId: task.id,
                              type: 'exec_mode_stage',
                              text: _executionModeCode(mode),
                              userId: widget.employeeId,
                            );
                      } else if (selectedMode == null) {
                        final mode = await _askExecMode(context,
                            initial: ExecutionMode.separate,
                            allowSolo: false,
                            allowJoint: true,
                            allowSeparate: true);
                        if (mode == null) return;
                        selectedMode = mode;
                        await context.read<TaskProvider>().addComment(
                              taskId: task.id,
                              type: 'exec_mode_stage',
                              text: _executionModeCode(mode),
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
                    }

                    Future<void> onPause() async {
                      final comment = await _askComment('Причина паузы');
                      if (comment == null) return;
                      await context.read<TaskProvider>().addCommentAutoUser(
                          taskId: task.id,
                          type: 'pause',
                          text: comment,
                          userIdOverride: widget.employeeId);
                      if (!_anyUserActive(task,
                          exceptUserId: widget.employeeId)) {
                        await context.read<TaskProvider>().updateStatus(
                            task.id, TaskStatus.paused,
                            startedAt: null);
                      }
                    }

                    Future<void> onFinish() async {
                      final qty = await _askQuantity(context);
                      if (qty == null) return;
                      final taskProvider = context.read<TaskProvider>();
                      if (jointGroup != null) {
                        // JOINT: split quantity and COMPLETE immediately
                        final per =
                            (qty / (jointGroup.isEmpty ? 1 : jointGroup.length))
                                .floor();
                        final paintResult = await _handleFlexoPaintUsage(task);
                        if (paintResult == null) return;
                        if (!paintResult) return;
                        await taskProvider.addCommentAutoUser(
                            taskId: task.id,
                            type: 'quantity_team_total',
                            text: qty.toString(),
                            userIdOverride: widget.employeeId);
                        for (final id in jointGroup) {
                          await taskProvider.addComment(
                              taskId: task.id,
                              type: 'quantity_share',
                              text: per.toString(),
                              userId: id);
                        }
                        await taskProvider.addCommentAutoUser(
                            taskId: task.id,
                            type: 'user_done',
                            text: 'done',
                            userIdOverride: widget.employeeId);
                        final latestTask = taskProvider.tasks.firstWhere(
                          (t) => t.id == task.id,
                          orElse: () => task,
                        );
                        final _secs = _elapsed(latestTask).inSeconds;
                        await taskProvider.updateStatus(
                            task.id, TaskStatus.completed,
                            spentSeconds: _secs, startedAt: null);
                        if (!mounted) return;
                        final note = await _askFinishNote();
                        if (note != null && note.isNotEmpty) {
                          await taskProvider.addCommentAutoUser(
                              taskId: task.id,
                              type: 'finish_note',
                              text: note,
                              userIdOverride: widget.employeeId);
                        }
                        return;
                      } else {
                        // SEPARATE: write personal qty, require ALL separate-mode assignees to finish
                        await taskProvider.addCommentAutoUser(
                            taskId: task.id,
                            type: 'quantity_done',
                            text: qty.toString(),
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
                              return mode == ExecutionMode.separate ||
                                  mode == ExecutionMode.solo;
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
                          final paintResult = await _handleFlexoPaintUsage(task);
                          if (paintResult == null) return;
                          if (!paintResult) return;
                          final _secs = _elapsed(latestTask).inSeconds;
                          await taskProvider.updateStatus(
                              task.id, TaskStatus.completed,
                              spentSeconds: _secs, startedAt: null);
                          if (!mounted) return;
                          final note = await _askFinishNote();
                          if (note != null && note.isNotEmpty) {
                            await taskProvider.addCommentAutoUser(
                                taskId: task.id,
                                type: 'finish_note',
                                text: note,
                                userIdOverride: widget.employeeId);
                          }
                        } else {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text(
                                        'Ожидаем завершения остальных исполнителей (отдельный режим)…')));
                          }
                        }
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
                                      child: const Text('✓ Завершить')),
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
                        ? 'Совместное исполнение'
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
                    rows.add(buildControlsFor('Совместное исполнение',
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
              _AssignedEmployeesRow(
                  task: task, scale: scale, compact: isTablet),
              SizedBox(height: scaled(8)),
              Text('Комментарии к этапу',
                  style: TextStyle(
                      fontSize: scaled(14), fontWeight: FontWeight.bold)),
              SizedBox(height: gapSmall),
              Builder(
                builder: (context) {
                  final personnel = context.watch<PersonnelProvider>();
                  final taskProvider = context.watch<TaskProvider>();
                  final aggregated = _collectOrderComments(taskProvider, task);
                  if (aggregated.isEmpty) {
                    return const Text('Нет комментариев',
                        style: TextStyle(color: Colors.grey));
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final entry in aggregated)
                        Padding(
                          padding: EdgeInsets.symmetric(vertical: gapSmall / 2),
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
                                  case 'quantity_team_total':
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
                                    icon =
                                        Icons.settings_input_component_outlined;
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
                              SizedBox(width: scaled(4)),
                              Expanded(
                                child: Builder(
                                  builder: (_) {
                                    final headerParts = <String>[];
                                    final c = entry.comment;
                                    final ts = _formatTimestamp(c.timestamp);
                                    if (ts.isNotEmpty) headerParts.add(ts);
                                    final author = _employeeDisplayName(
                                        personnel, c.userId);
                                    if (author.isNotEmpty) {
                                      headerParts.add(author);
                                    }
                                    final stageName = _workplaceName(
                                        personnel, entry.stageId);
                                    if (stageName.isNotEmpty) {
                                      headerParts.add('Этап: $stageName');
                                    }
                                    final header = headerParts.join(' • ');
                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (header.isNotEmpty)
                                          Text(
                                            header,
                                            style: const TextStyle(
                                                fontSize: 10,
                                                color: Colors.grey),
                                          ),
                                        Text(
                                          _describeComment(entry.comment),
                                          style: const TextStyle(fontSize: 14),
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
                },
              ),
              SizedBox(height: scaled(8)),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _chatController,
                      maxLines: 1,
                      readOnly: !isAssignee,
                      decoration: const InputDecoration(
                        hintText: 'Написать комментарий…',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  SizedBox(width: spacing),
                  ElevatedButton(
                    onPressed: isAssignee
                        ? () async {
                            final txt = _chatController.text.trim();
                            if (txt.isEmpty) return;
                            await context
                                .read<TaskProvider>()
                                .addCommentAutoUser(
                                    taskId: task.id,
                                    type: 'msg',
                                    text: txt,
                                    userIdOverride: widget.employeeId);
                            _chatController.clear();
                          }
                        : null,
                    child: const Text('Отправить'),
                  ),
                ],
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
        !task.assignees.contains(widget.employeeId);
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

  Future<String?> _askJoinMode(BuildContext context) {
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Режим участия'),
        content: const Text('Выберите режим участия в этапе:'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop('joint'),
              child: const Text('Совместное исполнение')),
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

    await provider.addCommentAutoUser(
        taskId: task.id,
        type: 'pause',
        text: comment,
        userIdOverride: widget.employeeId);

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

  List<TaskModel> _relatedTasks(TaskProvider provider, TaskModel pivot) {
    return provider.tasks
        .where((t) => t.orderId == pivot.orderId && t.stageId == pivot.stageId)
        .toList();
  }

  List<_StageComment> _collectOrderComments(
      TaskProvider provider, TaskModel pivot) {
    final cache =
        _orderCommentsCache.putIfAbsent(pivot.orderId, () => <String, _StageComment>{});
    final related =
        provider.tasks.where((t) => t.orderId == pivot.orderId).toList();
    for (final task in related) {
      for (final comment in task.comments) {
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
}

class _TaskCard extends StatelessWidget {
  final TaskModel task;
  final OrderModel? order;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;
  final double scale;

  const _TaskCard({
    required this.task,
    required this.order,
    required this.onTap,
    this.selected = false,
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
      horizontal: scaled(compact ? 10 : 14),
      vertical: scaled(compact ? 6 : 10),
    );
    final double titleSize = scaled(compact ? 13 : 15);
    final double subtitleSize = scaled(compact ? 11.5 : 13);
    final double statusSize = scaled(12);

    return Card(
      margin: EdgeInsets.symmetric(vertical: scaled(compact ? 4 : 6)),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(scaled(10)),
        side:
            BorderSide(color: selected ? Colors.blue : color.withOpacity(0.5)),
      ),
      child: ListTile(
        onTap: onTap,
        dense: compact,
        visualDensity: compact
            ? const VisualDensity(horizontal: -2, vertical: -2)
            : (scale < 1
                ? const VisualDensity(horizontal: -1, vertical: -1)
                : null),
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
        subtitle: name.isNotEmpty
            ? Text(
                name,
                style: TextStyle(
                  fontSize: subtitleSize,
                  color: Colors.grey[600],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )
            : null,
        trailing: Container(
          padding: EdgeInsets.symmetric(
            horizontal: scaled(10),
            vertical: scaled(compact ? 3 : 4),
          ),
          decoration: BoxDecoration(
            color: color.withOpacity(0.15),
            borderRadius: BorderRadius.circular(scaled(12)),
          ),
          child: Text(
            _statusText(task.status),
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
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
  const _AssignedEmployeesRow(
      {required this.task, required this.scale, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final personnel = context.watch<PersonnelProvider>();
    final taskProvider = context.read<TaskProvider>();

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
        // Capacity check for manual assignment
        final personnelProv = context.read<PersonnelProvider>();
        final stage = personnelProv.workplaces.firstWhere(
          (w) => w.id == task.stageId,
          orElse: () => WorkplaceModel(id: '', name: '', positionIds: const []),
        );
        final dynamic rawCap = (stage as dynamic).maxConcurrentWorkers;
        final int cap = (rawCap is num ? rawCap.toInt() : 1);
        final int effCap = cap <= 0 ? 1 : cap;
        // active is sum of assignees across all related tasks (including this one)
        final tp = context.read<TaskProvider>();
        final int active = tp.tasks
            .where((t) =>
                t.orderId == task.orderId &&
                t.stageId == task.stageId &&
                t.status == TaskStatus.inProgress)
            .fold<int>(
                0,
                (sum, t) =>
                    sum + (t.assignees.isEmpty ? 1 : t.assignees.length));
        if (active + 1 > effCap) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Нет свободных мест на рабочем месте')),
          );
          return;
        }
        ExecutionMode? stageMode = _stageExecutionMode(task);
        if (stageMode == ExecutionMode.solo && task.assignees.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'Этап выполняется одним сотрудником. Добавить ещё исполнителя нельзя.')));
          return;
        }

        ExecutionMode? selectedMode = stageMode;
        if (task.assignees.isEmpty) {
          final mode = await _askExecMode(context,
              initial: ExecutionMode.solo,
              allowSolo: true,
              allowJoint: true,
              allowSeparate: true);
          if (mode == null) return;
          selectedMode = mode;
          await taskProvider.addComment(
            taskId: task.id,
            type: 'exec_mode_stage',
            text: _executionModeCode(mode),
            userId: selectedId!,
          );
        } else if (selectedMode == null) {
          final mode = await _askExecMode(context,
              initial: ExecutionMode.separate,
              allowSolo: false,
              allowJoint: true,
              allowSeparate: true);
          if (mode == null) return;
          selectedMode = mode;
          await taskProvider.addComment(
            taskId: task.id,
            type: 'exec_mode_stage',
            text: _executionModeCode(mode),
            userId: selectedId!,
          );
        }

        final newAssignees = List<String>.from(task.assignees)
          ..add(selectedId!);
        await taskProvider.updateAssignees(task.id, newAssignees);

        if (selectedMode != null &&
            _needsExecModeRecord(task, selectedId!, selectedMode)) {
          await taskProvider.addComment(
            taskId: task.id,
            type: 'exec_mode',
            text: _executionModeCode(selectedMode),
            userId: selectedId!,
          );
        }
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
        )
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

Future<int?> _askQuantity(BuildContext context) async {
  final controller = TextEditingController();
  final v = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Количество выполнено'),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          hintText: 'Введите количество экземпляров',
          border: OutlineInputBorder(),
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
  return n;
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
