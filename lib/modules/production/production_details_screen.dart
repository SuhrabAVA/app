// lib/modules/production/production_details_screen.dart
//
// Полный файл без урезаний. НИЧЕГО лишнего не создаю.
// Исправление: загрузка этапов использует общий источник очереди
// OrderQueueService.loadSavedQueue / TaskProvider._loadStageSequence:
// нормализованные prod_plan_stages -> сохранённая очередь -> legacy JSON ->
// шаблонный фоллбек старых заказов. public.v_order_plan_stages остаётся только
// низкоприоритетным фоллбеком, как в TaskProvider.
// Плюс обязательная авторизация перед запросами (RLS).
//
// Требуется: services/app_auth.dart с AppAuth.ensureSignedIn().
//
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/storage_service.dart' as storage;
import '../production_planning/compat.dart' as pcompat;
import '../orders/orders_repository.dart';
import '../orders/order_model.dart';
import '../orders/order_queue_service.dart';
import '../orders/stage_queue_builder.dart';
import '../tasks/task_model.dart';
import '../tasks/task_provider.dart';
import '../tasks/task_completion_rules.dart';
// УДАЛЕНО: import '../production_planning/planned_stage_model.dart';
import '../personnel/employee_model.dart';
import '../personnel/personnel_provider.dart';
import '../orders/order_comments_timeline.dart';
import '../../services/app_auth.dart';
import '../orders/order_details_card.dart';

@visibleForTesting
List<pcompat.PlannedStage>
    productionDetailsPlannedStagesFromQueueRowsForTesting({
  required List<Map<String, dynamic>> rows,
  Map<String, String> workplaceNames = const <String, String>{},
}) {
  final normalizedRows = normalizeBuiltOrderStageQueue(rows);
  final planned = <pcompat.PlannedStage>[];

  for (final row in normalizedRows) {
    final stageIds = OrderQueueMapper.stageIdsFromRow(row);
    final stageId = stageIds.isNotEmpty
        ? stageIds.first
        : (row['stageId'] ?? row['stage_id'] ?? row['workplaceId'] ?? row['id'])
            ?.toString()
            .trim();
    if (stageId == null || stageId.isEmpty) continue;

    final label = _productionDetailsStageLabelFromRow(
      row,
      stageId,
      workplaceNames,
    );
    final allStageIds = stageIds.isNotEmpty ? stageIds : <String>[stageId];
    planned.add(
      pcompat.PlannedStage(
        stageId: stageId,
        stageName: label,
        order: planned.length + 1,
        extra: <String, dynamic>{
          ...row,
          'stage_id': stageId,
          'stageId': stageId,
          'stage_name': label,
          'stageName': label,
          'workplaceIds': allStageIds,
          if (allStageIds.length > 1)
            'alternativeStageIds': allStageIds.skip(1).toList(),
        },
      ),
    );
  }

  return planned;
}

String _productionDetailsStageLabelFromRow(
  Map<String, dynamic> row,
  String stageId,
  Map<String, String> workplaceNames,
) {
  for (final key in const <String>[
    'stageName',
    'stage_name',
    'workplaceName',
    'workplace_name',
    'label',
    'title',
    'name',
  ]) {
    final value = row[key]?.toString().trim();
    if (value != null && value.isNotEmpty) return value;
  }
  final workplaceName = workplaceNames[stageId]?.trim();
  if (workplaceName != null && workplaceName.isNotEmpty) return workplaceName;
  return stageId;
}

class ProductionDetailsScreen extends StatefulWidget {
  final OrderModel order;
  const ProductionDetailsScreen({super.key, required this.order});

  @override
  State<ProductionDetailsScreen> createState() =>
      _ProductionDetailsScreenState();
}

class _ProductionDetailsScreenState extends State<ProductionDetailsScreen> {
  final ScrollController _scrollController = ScrollController();
  List<pcompat.PlannedStage> _plannedStages = [];
  bool _loadingPlan = true;
  bool _loadingFiles = false;
  List<Map<String, dynamic>> _files = const [];
  List<Map<String, dynamic>> _paints = const [];
  String? _stageTemplateName;
  String? _formImageUrl;
  Map<String, dynamic>? _formDetails;

  List<String> _decodeStringList(dynamic raw) {
    if (raw == null) return const [];
    if (raw is List) {
      return raw.map((e) => e?.toString() ?? '').where((e) => e.isNotEmpty).toList();
    }
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return decoded
              .map((e) => e?.toString() ?? '')
              .where((e) => e.isNotEmpty)
              .toList();
        }
      } catch (_) {}
    }
    return const [];
  }

  List<String> _plannedStageIds(pcompat.PlannedStage planned) {
    final ids = <String>{};
    final extra = planned.extra;
    final workplaceIds = _decodeStringList(
      extra['workplaceIds'] ?? extra['workplace_ids'],
    );
    if (workplaceIds.isNotEmpty) {
      ids.addAll(workplaceIds.where((id) => id.trim().isNotEmpty));
    } else {
      final primary = planned.stageId.trim();
      if (primary.isNotEmpty) ids.add(primary);
    }
    final altIds = _decodeStringList(
      extra['alternativeStageIds'] ?? extra['alternative_stage_ids'],
    );
    ids.addAll(altIds.where((id) => id.trim().isNotEmpty));
    return ids.toList();
  }

  List<String> _plannedStageNames(pcompat.PlannedStage planned) {
    final ordered = <String>[];
    final seen = <String>{};
    void addName(String value) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return;
      final key = trimmed.toLowerCase();
      if (!seen.add(key)) return;
      ordered.add(trimmed);
    }

    final base = planned.stageName.trim();
    addName(base);
    final extra = planned.extra;
    final altNames = _decodeStringList(
      extra['alternativeStageNames'] ?? extra['alternative_stage_names'],
    );
    for (final name in altNames) {
      addName(name);
    }
    return ordered;
  }

  String _resolveStageName(
    String stageId,
    PersonnelProvider personnel,
  ) {
    try {
      final stage = personnel.workplaces.firstWhere((s) => s.id == stageId);
      if (stage.name.trim().isNotEmpty) return stage.name.trim();
    } catch (_) {}
    return stageId;
  }

  String _plannedStageLabel(
    pcompat.PlannedStage planned,
    List<String> stageIds,
    PersonnelProvider personnel,
  ) {
    final normalized = <String>[];
    final seen = <String>{};

    void addParts(Iterable<String> values) {
      for (final value in values) {
        for (final rawPart in value.split(RegExp(r'[/,]'))) {
          final cleaned = rawPart.trim().replaceAll(RegExp(r'^\(+|\)+$'), '');
          if (cleaned.isEmpty) continue;
          final key = cleaned.toLowerCase();
          if (!seen.add(key)) continue;
          normalized.add(cleaned);
        }
      }
    }

    addParts(_plannedStageNames(planned));
    if (normalized.isNotEmpty) {
      return normalized.join(' / ');
    }

    if (stageIds.isEmpty) return planned.stageName;
    addParts(stageIds.map((id) => _resolveStageName(id, personnel)));
    return normalized.isEmpty ? planned.stageName : normalized.join(' / ');
  }

  String _stageGroupKeyForPlannedStage(
    pcompat.PlannedStage planned,
    List<String> stageIds,
  ) {
    for (final key in const <String>[
      'stageGroupKey',
      'stage_group_key',
      'queueStageKey',
      'queue_stage_key',
      'groupKey',
      'group_key',
      'stageKey',
      'stage_key',
    ]) {
      final value = planned.extra[key]?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return stageIds.isNotEmpty ? stageIds.first : planned.stageId.trim();
  }

  Future<void> _skipStageForTesting(
    pcompat.PlannedStage planned,
    List<TaskModel> stageTasks,
    List<String> stageIds,
  ) async {
    if (stageTasks.isEmpty && stageIds.isEmpty) return;
    final provider = context.read<TaskProvider>();
    // Тестовый режим: помечаем текущий этап завершённым и передаём заказ дальше.
    if (stageTasks.isEmpty) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final stageId =
          stageIds.isNotEmpty ? stageIds.first : planned.stageId.trim();
      final stageGroupKey = _stageGroupKeyForPlannedStage(planned, stageIds);
      await Supabase.instance.client.from('tasks').insert({
        'order_id': widget.order.id,
        'stage_id': stageId,
        'stage_group_key': stageGroupKey,
        'status': TaskStatus.completed.name,
        'spent_seconds': 0,
        'assignees': <String>[],
        'comments': {
          'skip_stage_test_$now': {
            'type': 'skip_stage_test',
            'text': 'Этап пропущен в тестовом режиме',
            'userId': 'system',
            'timestamp': now,
          },
        },
      });
    } else {
      for (final task in stageTasks) {
        await provider.addComment(
          taskId: task.id,
          type: 'skip_stage_test',
          text: 'Этап пропущен в тестовом режиме',
          userId: 'system',
        );
        await provider.updateStatus(task.id, TaskStatus.completed);
      }
    }
    await provider.refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Этап пропущен, переход к следующему этапу')),
    );
  }

  TaskStatus? _groupStatus(List<TaskModel> stageTasks) {
    if (stageTasks.isEmpty) return null;
    if (isStageGroupFinallyCompleted(stageTasks)) {
      return TaskStatus.completed;
    }

    if (stageTasks.any((t) => t.status == TaskStatus.problem)) {
      return TaskStatus.problem;
    }
    if (stageTasks.any((t) => t.status == TaskStatus.inProgress)) {
      return TaskStatus.inProgress;
    }
    if (stageTasks.any((t) => t.status == TaskStatus.paused)) {
      return TaskStatus.paused;
    }
    return TaskStatus.waiting;
  }

  @override
  void initState() {
    super.initState();
    _loadPlan();
    _loadOrderDetails();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
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

  Future<Map<String, dynamic>?> _loadFormDetails() async {
    final formCode = widget.order.formCode?.trim();
    final formSeries = widget.order.formSeries?.trim();
    final formNo = widget.order.newFormNo;
    if (formCode != null && formCode.isNotEmpty) {
      final res = await Supabase.instance.client
          .from('forms')
          .select()
          .eq('code', formCode)
          .maybeSingle();
      if (res != null && res is Map) return Map<String, dynamic>.from(res);
    }
    if (formSeries != null && formSeries.isNotEmpty && formNo != null) {
      final res = await Supabase.instance.client
          .from('forms')
          .select()
          .eq('series', formSeries)
          .eq('number', formNo)
          .maybeSingle();
      if (res != null && res is Map) return Map<String, dynamic>.from(res);
    }
    return null;
  }

  Future<void> _loadOrderDetails() async {
    setState(() => _loadingFiles = true);
    try {
      final repo = OrdersRepository();
      final paints = await repo.getPaints(widget.order.id);
      final files = await storage.listOrderFiles(widget.order.id);
      final formDetails = await _loadFormDetails();
      final formImageUrl = _buildFormImageUrl(
        formDetails?['image_url']?.toString(),
        updatedAt: formDetails?['updated_at']?.toString(),
      );
      String? stageTemplateName;
      final tplId = widget.order.stageTemplateId;
      if (tplId != null && tplId.isNotEmpty) {
        final tpl = await Supabase.instance.client
            .from('plan_templates')
            .select('name')
            .eq('id', tplId)
            .maybeSingle();
        final name = tpl?['name']?.toString();
        if (name != null && name.isNotEmpty) stageTemplateName = name;
      }
      if (!mounted) return;
      setState(() {
        _paints = paints;
        _files = files;
        _stageTemplateName = stageTemplateName;
        _formImageUrl = formImageUrl;
        _formDetails = formDetails;
      });
    } catch (_) {
      // ignore errors in read-only view
    } finally {
      if (mounted) setState(() => _loadingFiles = false);
    }
  }

  Future<void> _reloadAll() async {
    await Future.wait([
      _loadPlan(),
      _loadOrderDetails(),
    ]);
  }

  Future<void> _loadPlan() async {
    try {
      if (mounted) {
        setState(() => _loadingPlan = true);
      }
      final sb = Supabase.instance.client;
      await AppAuth.ensureSignedIn(); // важно для RLS

      final orderId = widget.order.id;
      final orderCode = widget.order.assignmentId ?? orderId;
      final workplaceNames = <String, String>{
        for (final workplace in context.read<PersonnelProvider>().workplaces)
          workplace.id: workplace.name,
      };

      List<pcompat.PlannedStage> stages = [];
      final savedQueue = await OrderQueueService(sb).loadSavedQueue(orderId);
      if (savedQueue.isNotEmpty) {
        stages = productionDetailsPlannedStagesFromQueueRowsForTesting(
          rows: savedQueue.rows,
          workplaceNames: workplaceNames,
        );
      }

      // Derived/public view is kept only as the same low-priority fallback as in
      // TaskProvider._loadStageSequence; saved queue / normalized rows from
      // OrderQueueService remain the source of truth for persisted plans.
      if (stages.isEmpty) {
        try {
          final rows = await sb
              .from('v_order_plan_stages')
              .select(
                'stage_id, stage_group_key, stage_name, step_no, order_id, order_code',
              )
              .or('order_id.eq.$orderId,order_code.eq.$orderCode')
              .order('step_no', ascending: true);

          if (rows is List && rows.isNotEmpty) {
            stages = productionDetailsPlannedStagesFromQueueRowsForTesting(
              rows: rows
                  .whereType<Map>()
                  .map(Map<String, dynamic>.from)
                  .toList(),
              workplaceNames: workplaceNames,
            );
          }
        } catch (_) {
          // нет представления — показываем пустой план
        }
      }

      if (mounted) {
        setState(() {
          _plannedStages = stages;
          _loadingPlan = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _plannedStages = [];
          _loadingPlan = false;
        });
      }
    }
  }

  Duration _elapsed(TaskModel task) {
    var seconds = task.spentSeconds;
    if (task.status == TaskStatus.inProgress && task.startedAt != null) {
      seconds +=
          (DateTime.now().millisecondsSinceEpoch - task.startedAt!) ~/ 1000;
    }
    return Duration(seconds: seconds);
  }

  String _formatTime(DateTime? dt) {
    if (dt == null) return '';
    final formatter = DateFormat('yyyy-MM-dd HH:mm');
    return formatter.format(dt);
  }

  String _formatCommentTimestamp(int timestamp) {
    if (timestamp <= 0) return '';
    try {
      final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
      return DateFormat('dd.MM.yyyy HH:mm').format(dt);
    } catch (_) {
      return '';
    }
  }

  String _commentAuthorName(String userId, List<EmployeeModel> employees) {
    if (userId.isEmpty) return 'Неизвестный сотрудник';
    EmployeeModel? found;
    for (final emp in employees) {
      if (emp.id == userId ||
          (emp.login.isNotEmpty && emp.login == userId) ||
          (emp.iin.isNotEmpty && emp.iin == userId)) {
        found = emp;
        break;
      }
    }
    if (found == null) return userId;
    final parts = [found.lastName, found.firstName, found.patronymic]
        .where((s) => s.trim().isNotEmpty)
        .toList();
    if (parts.isEmpty) return userId;
    return parts.join(' ');
  }

  Widget _buildCommentMeta(TaskComment comment, List<EmployeeModel> employees) {
    final timestampText = _formatCommentTimestamp(comment.timestamp);
    final authorText = _commentAuthorName(comment.userId, employees);
    final meta = [timestampText, authorText]
        .where((s) => s.trim().isNotEmpty)
        .join(' • ');
    if (meta.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        meta,
        style: const TextStyle(
          fontSize: 12,
          color: Colors.black54,
        ),
      ),
    );
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

  String _formatQuantityDisplay(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '0';
    final value = double.tryParse(trimmed.replaceAll(',', '.'));
    if (value == null) return trimmed;
    if ((value - value.round()).abs() < 0.0001) {
      return value.round().toString();
    }
    return value.toStringAsFixed(2);
  }

  String _renderCommentText(TaskComment comment, List<EmployeeModel> employees) {
    final rawText = comment.text.trim();
    if (rawText.isEmpty) {
      switch (comment.type) {
        case 'shift_pause':
          return 'Пересмена: этап приостановлен';
        case 'shift_resume':
          return 'Пересмена: работа возобновлена';
        case 'ink_writeoff':
          return 'Зафиксировано списание краски';
        default:
          return 'Без комментария';
      }
    }

    final parsed = TaskTimeEvent.fromPayload(
      rawText,
      comment.id,
      comment.timestamp,
      comment.userId,
    );
    if (parsed != null) {
      final periodStart = DateFormat('dd.MM.yyyy HH:mm')
          .format(parsed.startTime.toLocal());
      final periodEnd = parsed.endTime == null
          ? 'в процессе'
          : DateFormat('dd.MM.yyyy HH:mm').format(parsed.endTime!.toLocal());
      final subject = _commentAuthorName(parsed.subjectUserId, employees);
      final note = parsed.note?.trim();
      final notePart = (note != null && note.isNotEmpty) ? ' · $note' : '';
      return '${_timeTypeLabel(parsed.type)}: $periodStart — $periodEnd · $subject$notePart';
    }

    switch (comment.type) {
      case 'start':
        return 'Начал(а) этап';
      case 'pause':
        return 'Пауза: $rawText';
      case 'problem':
        return 'Проблема: $rawText';
      case 'setup_start':
        return 'Начал(а) наладку';
      case 'setup_resume':
        return 'Продолжил(а) наладку';
      case 'setup_done':
        return 'Завершил(а) наладку';
      case 'quantity_done':
        return 'Выполнил(а): ${_formatQuantityDisplay(rawText)} шт.';
      case 'quantity_team_total':
        return 'Команда выполнила: ${_formatQuantityDisplay(rawText)} шт.';
      case 'quantity_share':
        return 'Личный вклад: ${_formatQuantityDisplay(rawText)} шт.';
      case 'shift_pause':
      case 'shift_resume':
      case 'finish_note':
      case 'ink_writeoff':
        return rawText;
      case 'shift_pause_state':
      case 'exec_mode':
      case 'exec_mode_stage':
        return 'Служебная отметка этапа';
    }

    if (rawText.startsWith('{') && rawText.endsWith('}')) {
      return 'Служебный комментарий';
    }
    return rawText;
  }

  String _stageStatusLabel(TaskStatus? status) {
    switch (status) {
      case TaskStatus.completed:
        return 'Завершено';
      case TaskStatus.inProgress:
        return 'В процессе';
      case TaskStatus.paused:
        return 'На паузе';
      case TaskStatus.problem:
        return 'Проблема';
      case TaskStatus.waiting:
      default:
        return 'Ожидание запуска';
    }
  }

  Color _stageStatusColor(TaskStatus? status) {
    switch (status) {
      case TaskStatus.completed:
        return Colors.green;
      case TaskStatus.inProgress:
        return Colors.blue;
      case TaskStatus.paused:
        return Colors.orange;
      case TaskStatus.problem:
        return Colors.redAccent;
      case TaskStatus.waiting:
      default:
        return Colors.yellow.shade700;
    }
  }

  Widget _buildProductionCard({
    required List<TaskModel> tasks,
    required Map<String, List<TaskModel>> tasksByStage,
    required PersonnelProvider personnel,
  }) {
    final comments = <TaskComment>[];
    const hiddenTypes = <String>{
      'shift_pause_state',
      'exec_mode',
      'exec_mode_stage',
    };
    for (final t in tasks) {
      comments.addAll(
        t.comments.where(
          (comment) => !hiddenTypes.contains(comment.type.trim().toLowerCase()),
        ),
      );
    }
    comments.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Комментарии',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 220,
              child: OrderCommentsTimeline(
                comments: comments,
                attachmentsByComment: const {},
              ),
            ),
            const Divider(height: 24),
            const Text(
              'Этапы производства',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            if (_loadingPlan)
              const LinearProgressIndicator()
            else if (_plannedStages.isEmpty)
              const Text(
                'План этапов отсутствует',
                style: TextStyle(color: Colors.grey),
              )
            else
              Column(
                children: [
                  for (final entry in _plannedStages.asMap().entries)
                    Builder(
                      builder: (context) {
                        final planned = entry.value;
                        final stageIds = _plannedStageIds(planned);
                        final stageLabel =
                            _plannedStageLabel(planned, stageIds, personnel);
                        final stageTasks = <TaskModel>[];
                        for (final id in stageIds) {
                          stageTasks.addAll(
                              tasksByStage[id] ?? const <TaskModel>[]);
                        }
                        final stageStatus = _groupStatus(stageTasks);
                        final statusColor = _stageStatusColor(stageStatus);
                        DateTime? start;
                        DateTime? end;
                        if (stageTasks.isNotEmpty) {
                          for (final t in stageTasks) {
                            if (t.startedAt != null) {
                              final st = DateTime.fromMillisecondsSinceEpoch(
                                t.startedAt!,
                              );
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
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: statusColor.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: statusColor.withOpacity(0.4),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              CircleAvatar(
                                radius: 12,
                                backgroundColor: Colors.white,
                                child: Text(
                                  '${entry.key + 1}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      stageLabel,
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _stageStatusLabel(stageStatus),
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: statusColor,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    if (stageTasks.isNotEmpty)
                                      Text(
                                        'Исполнители: ${stageTasks.first.assignees.join(', ')}',
                                        style: const TextStyle(
                                          fontSize: 13,
                                          color: Colors.black87,
                                        ),
                                      ),
                                    const SizedBox(height: 4),
                                    Text(
                                      start != null
                                          ? 'Начало: ${_formatTime(start)}'
                                          : 'Начало: —',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.black54,
                                      ),
                                    ),
                                    Text(
                                      end != null
                                          ? 'Завершение: ${_formatTime(end)}'
                                          : 'Завершение: —',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.black54,
                                      ),
                                    ),
                                    if (stageStatus != TaskStatus.completed) ...[
                                      const SizedBox(height: 6),
                                      OutlinedButton.icon(
                                        onPressed: _loadingPlan
                                            ? null
                                            : () => _skipStageForTesting(
                                                  planned,
                                                  stageTasks,
                                                  stageIds,
                                                ),
                                        icon: const Icon(Icons.skip_next, size: 16),
                                        label: const Text('Пропустить этап'),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              if (stageTasks.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(left: 8),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.message_outlined,
                                        size: 16,
                                        color: Colors.grey,
                                      ),
                                      const SizedBox(width: 2),
                                      Text(
                                        '${stageTasks.fold<int>(0, (p, t) => p + t.comments.length)}',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Colors.black54,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final taskProvider = context.watch<TaskProvider>();
    final personnel = context.watch<PersonnelProvider>();
    final tasks =
        taskProvider.tasks.where((t) => t.orderId == widget.order.id).toList();

    final Map<String, List<TaskModel>> tasksByStage = {};
    for (final t in tasks) {
      tasksByStage.putIfAbsent(t.stageId, () => []).add(t);
    }

    final size = MediaQuery.of(context).size;
    final dialogHeight = size.height - 32;
    final dialogWidth = math.min(size.width - 32, 1100.0);

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: dialogHeight,
          maxWidth: dialogWidth,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Заказ ${widget.order.assignmentId ?? widget.order.id}',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Обновить данные',
                    onPressed:
                        (_loadingFiles || _loadingPlan) ? null : _reloadAll,
                    icon: const Icon(Icons.refresh),
                  ),
                  IconButton(
                    tooltip: 'Закрыть',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Scrollbar(
                controller: _scrollController,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Card(
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: OrderDetailsCard(
                            order: widget.order,
                            paints: _paints,
                            files: _files,
                            stageTemplateName: _stageTemplateName,
                            formImageUrl: _formImageUrl,
                            formDetails: _formDetails,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildProductionCard(
                        tasks: tasks,
                        tasksByStage: tasksByStage,
                        personnel: personnel,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
