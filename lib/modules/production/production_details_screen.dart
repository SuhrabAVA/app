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
import '../../utils/kostanay_time.dart';
import '../production_planning/compat.dart' as pcompat;
import '../orders/orders_repository.dart';
import '../orders/order_model.dart';
import '../orders/order_queue_service.dart';
import '../orders/stage_queue_builder.dart';
import '../common/pulsing_dot.dart';
import '../tasks/quantity_status_service.dart'
    show formatQuantityNumber, getQuantityStatusColor;
import '../tasks/stage_participant_output.dart';
import '../tasks/stage_quantity_deviation.dart';
import '../tasks/task_buttons_state.dart' show UserRunState;
import '../tasks/stage_status_colors.dart';
import '../tasks/task_model.dart';
import '../tasks/task_run_state.dart';
import '../tasks/task_provider.dart';
import '../tasks/task_completion_rules.dart';
// УДАЛЕНО: import '../production_planning/planned_stage_model.dart';
import '../personnel/personnel_provider.dart';
import '../orders/order_comments_timeline.dart';
import '../orders/order_comment_attachment.dart';
import '../orders/order_comments_repository.dart';
import '../../services/app_auth.dart';
import '../orders/order_details_card.dart';
import '../orders/order_manager_comment_banner.dart';
import '../orders/paper_usage_rules.dart';
import '../orders/order_shipment_rules.dart';
import '../orders/order_timeline_dialog.dart';
import '../orders/orders_provider.dart';
import '../orders/restart_history_service.dart';
import '../orders/order_generation_switcher.dart';
import '../orders/order_restart_history_repository.dart';
import '../tasks/workspace_design.dart';
import '../../utils/auth_helper.dart';
import 'stage_skip_rules.dart';

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

  /// Открыть карточку сразу на ленте истории заказа (архив приходит именно
  /// за ней), а не на комментариях этапов.
  final bool showHistoryFirst;

  /// Разрешены ли действия над этапами — пропуск и возобновление. Включено
  /// только в модуле управления производственными заданиями: из оформления
  /// заказа карточка открывается для просмотра, там маршрутом не управляют.
  final bool allowStageActions;

  const ProductionDetailsScreen({
    super.key,
    required this.order,
    this.showHistoryFirst = false,
    this.allowStageActions = false,
  });

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
  List<Map<String, dynamic>> _formFiles = const [];
  List<Map<String, dynamic>> _paints = const [];
  String? _stageTemplateName;
  Map<String, dynamic>? _formDetails;
  String _selectedCommentsOrderId = '';
  List<OrderGenerationEntry> _restartAncestors = const [];
  bool _loadingRestartHistory = false;
  // Правая нижняя панель: комментарии этапов или история заказа. Раньше
  // история открывалась «часами» из списка заказов — теперь она живёт здесь.
  bool _showOrderHistory = false;

  /// Партии отгрузки заказа — показываем в карточке, в том числе в архиве.
  List<OrderShipment> _shipments = const <OrderShipment>[];
  PaperUsageState? _paperUsage;
  bool _reopeningStage = false;
  // Вложения комментариев: comment_id -> файлы; запрошенные id кэшируем,
  // чтобы не дёргать запрос на каждый rebuild.
  final Map<String, List<OrderCommentAttachment>> _attachmentsByComment = {};
  final Set<String> _requestedAttachmentCommentIds = <String>{};

  void _ensureCommentAttachments(Iterable<String> commentIds) {
    final missing = commentIds
        .map((id) => id.trim())
        .where((id) =>
            id.isNotEmpty && !_requestedAttachmentCommentIds.contains(id))
        .toList(growable: false);
    if (missing.isEmpty) return;
    _requestedAttachmentCommentIds.addAll(missing);
    Future.microtask(() async {
      try {
        final rows = await OrderCommentsRepository()
            .loadAttachmentsByCommentIds(missing);
        if (!mounted || rows.isEmpty) return;
        setState(() {
          for (final a in rows) {
            _attachmentsByComment
                .putIfAbsent(a.commentId, () => <OrderCommentAttachment>[])
                .add(a);
          }
        });
      } catch (_) {
        // Вложения не критичны для read-only просмотра.
      }
    });
  }

  List<String> _decodeStringList(dynamic raw) {
    if (raw == null) return const [];
    if (raw is List) {
      return raw
          .map((e) => e?.toString() ?? '')
          .where((e) => e.isNotEmpty)
          .toList();
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
    final repository = OrdersRepository();

    // Кто и почему пропустил этап. Раньше отметка и завершение писались от
    // `system` без причины, и разобрать заказ потом было невозможно.
    final reason = await _askSkipReason(
      planned.stageName,
      skipStageWarnings(<String>{
        ...stageIds,
        ...stageTasks.map((t) => t.stageId),
      }),
    );
    if (reason == null || !mounted) return;
    final actorName = AuthHelper.currentUserName;
    final testComment = skipStageNote(reason: reason, actorName: actorName);
    final actorUserId = (AuthHelper.currentUserId ?? '').trim().isEmpty
        ? 'system'
        : AuthHelper.currentUserId!.trim();
    String taskId;
    String stageId;

    // Тестовый режим использует тот же атомарный RPC завершения, что и
    // нормальный режим. Это сохраняет финализацию заказа и складские эффекты.
    if (stageTasks.isEmpty) {
      final now = DateTime.now().millisecondsSinceEpoch;
      stageId = stageIds.isNotEmpty ? stageIds.first : planned.stageId.trim();
      final stageGroupKey = _stageGroupKeyForPlannedStage(planned, stageIds);
      final inserted = await Supabase.instance.client
          .from('tasks')
          .insert({
            'order_id': widget.order.id,
            'stage_id': stageId,
            'stage_group_key': stageGroupKey,
            'status': TaskStatus.waiting.name,
            'spent_seconds': 0,
            'assignees': <String>[],
            'comments': {
              'skip_stage_test_$now': {
                'type': 'skip_stage_test',
                'text': testComment,
                'userId': actorUserId,
                'timestamp': now,
              },
            },
          })
          .select('id')
          .single();
      taskId = (inserted['id'] ?? '').toString();
    } else {
      final incompleteTasks = stageTasks
          .where((candidate) => candidate.status != TaskStatus.completed)
          .toList(growable: false);
      if (incompleteTasks.isEmpty) return;
      final task = incompleteTasks.first;
      taskId = task.id;
      stageId = task.stageId;
      for (final incompleteTask in incompleteTasks) {
        final noted = await provider.addComment(
          taskId: incompleteTask.id,
          type: 'skip_stage_test',
          text: testComment,
          userId: actorUserId,
        );
        // Без отметки пропуск не делаем: иначе этап закроется, а причина и
        // автор нигде не останутся.
        if (!noted) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(provider.lastStageWriteError ??
                'Не удалось записать причину пропуска. Этап не пропущен.'),
          ));
          return;
        }
      }
    }

    // employeeId остаётся `system`: пропускающий не исполнитель этапа, и RPC
    // иначе отказал бы («Сотрудник не назначен исполнителем»). Имя идёт в
    // actor — оно попадает в журнал склада, если этап списывает бумагу.
    await repository.completeTaskStage(
      taskId: taskId,
      orderId: widget.order.id,
      stageId: stageId,
      employeeId: 'system',
      actor: skipStageActor(actorName),
    );
    await provider.refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Этап пропущен, переход к следующему этапу')),
    );
  }

  /// Диалог пропуска этапа: последствия и обязательная причина.
  /// null — пропуск отменён.
  Future<String?> _askSkipReason(String stageLabel, List<String> warnings) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final valid = isValidSkipReason(controller.text);
          return AlertDialog(
            title: Text('Пропустить этап «$stageLabel»?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final warning in warnings)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.warning_amber_rounded,
                            size: 18, color: WorkspaceColors.danger),
                        const SizedBox(width: 6),
                        Expanded(child: Text(warning)),
                      ],
                    ),
                  ),
                TextField(
                  controller: controller,
                  autofocus: true,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Причина пропуска',
                    hintText: 'Например: заказу этот этап не нужен',
                  ),
                  onChanged: (_) => setDialogState(() {}),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Отмена'),
              ),
              ElevatedButton(
                onPressed: valid
                    ? () => Navigator.pop(ctx, controller.text.trim())
                    : null,
                child: const Text('Пропустить'),
              ),
            ],
          );
        },
      ),
    );
    // controller не освобождаем в whenComplete: диалог ещё анимирует закрытие
    // и держит TextField — dispose в этот момент роняет кадр.
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
    _selectedCommentsOrderId = widget.order.id;
    _showOrderHistory = widget.showHistoryFirst;
    _loadPlan();
    _loadOrderDetails();
    _loadShipments();
    _loadPaperUsage();
    _loadRestartHistory();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  String get _currentOrderId => widget.order.id;
  bool get _isHistoryReadOnly =>
      _selectedCommentsOrderId.trim() != _currentOrderId.trim();

  Future<void> _loadRestartHistory() async {
    setState(() => _loadingRestartHistory = true);
    try {
      final service = RestartHistoryService(
        SupabaseOrderRestartHistoryRepository(),
      );
      final history = await service.loadGenerationChain(_currentOrderId);
      if (!mounted) return;
      setState(() => _restartAncestors = history);
    } catch (_) {
      if (!mounted) return;
      setState(() => _restartAncestors = const []);
    } finally {
      if (mounted) setState(() => _loadingRestartHistory = false);
    }
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
      List<Map<String, dynamic>> formFiles = const [];
      final formId = formDetails?['id']?.toString() ?? '';
      if (formId.isNotEmpty) {
        try {
          formFiles = await storage.listFormFiles(formId);
        } catch (_) {}
      }
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
        _formFiles = formFiles;
        _stageTemplateName = stageTemplateName;
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
              rows:
                  rows.whereType<Map>().map(Map<String, dynamic>.from).toList(),
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

  /// ФИО исполнителей этапа. В tasks.assignees лежат id сотрудников —
  /// показывать их пользователю бессмысленно. Если сотрудник не найден
  /// (удалён из справочника), оставляем id: лучше сырой идентификатор,
  /// чем пустая строка, по нему хотя бы можно найти запись.
  String _assigneeNames(List<String> assignees, PersonnelProvider personnel) {
    if (assignees.isEmpty) return '—';
    final names = assignees.map((id) {
      try {
        final e = personnel.employees.firstWhere((x) => x.id == id);
        final full = [e.lastName, e.firstName, e.patronymic]
            .where((part) => part.trim().isNotEmpty)
            .join(' ')
            .trim();
        if (full.isNotEmpty) return full;
        return e.login.trim().isNotEmpty ? e.login.trim() : id;
      } catch (_) {
        return id;
      }
    }).toList();
    return names.join(', ');
  }

  /// Цвет и подпись этапа — общие с рабочим пространством и модулем
  /// производства (`stage_status_colors.dart`).
  ///
  /// Своя палитра по `TaskStatus` знала пять состояний из семи: пересмену
  /// показывала паузой, а «доступен к началу» не отличала от «не начат». Цех
  /// и мастер смотрят на одни и те же этапы, и одинаковый этап должен быть
  /// одного цвета на всех трёх экранах.
  Color _stageStatusBackground(Color accent) => accent.withValues(alpha: 0.12);

  /// Панель этапов — на месте кнопок управления из рабочего пространства.
  /// Задание отсюда не запускают: карточка только показывает, где заказ.
  Widget _buildStagesPanel({
    required Map<String, List<TaskModel>> tasksByStage,
    required PersonnelProvider personnel,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: workspaceCardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.route_outlined,
                  size: 18, color: Color(0xFFFF7448)),
              const SizedBox(width: 7),
              const Text(
                'Этапы производства',
                style: TextStyle(
                  color: WorkspaceColors.foreground,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (!_loadingPlan && _plannedStages.isNotEmpty)
                Text(
                  _stagesProgressLabel(tasksByStage),
                  style: const TextStyle(
                    color: WorkspaceColors.mutedForeground,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (_loadingPlan)
            const LinearProgressIndicator(minHeight: 2)
          else if (_plannedStages.isEmpty)
            const Text(
              'План этапов отсутствует',
              style: TextStyle(
                color: WorkspaceColors.mutedForeground,
                fontSize: 12,
              ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                const gap = 6.0;
                // Плитки узкие: маршрут из десятка этапов должен читаться
                // целиком, не выдавливая комментарии вниз.
                const minTileWidth = 190.0;
                final columns = math.max(
                  1,
                  ((constraints.maxWidth + gap) / (minTileWidth + gap))
                      .floor(),
                );
                final tileWidth =
                    (constraints.maxWidth - gap * (columns - 1)) / columns;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (final entry in _plannedStages.asMap().entries)
                      SizedBox(
                        width: tileWidth,
                        child: _buildStageTile(
                          index: entry.key,
                          planned: entry.value,
                          tasksByStage: tasksByStage,
                          personnel: personnel,
                        ),
                      ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }

  String _stagesProgressLabel(Map<String, List<TaskModel>> tasksByStage) {
    var done = 0;
    for (final planned in _plannedStages) {
      final stageTasks = <TaskModel>[];
      for (final id in _plannedStageIds(planned)) {
        stageTasks.addAll(tasksByStage[id] ?? const <TaskModel>[]);
      }
      if (_groupStatus(stageTasks) == TaskStatus.completed) done += 1;
    }
    return 'Пройдено $done из ${_plannedStages.length}';
  }

  /// Начат ли предыдущий этап маршрута — от этого зависит, доступен ли
  /// текущий. Первый этап доступен всегда.
  ///
  /// Правило то же, что разблокирует кнопку «Начать» у сотрудника: предыдущему
  /// достаточно быть НАЧАТЫМ, завершения не требуется.
  bool _previousStageUnlocks(
    int index,
    Map<String, List<TaskModel>> tasksByStage,
  ) {
    if (index <= 0) return true;
    final previous = _plannedStages[index - 1];
    final previousTasks = <TaskModel>[];
    for (final id in _plannedStageIds(previous)) {
      previousTasks.addAll(tasksByStage[id] ?? const <TaskModel>[]);
    }
    return stageUnlocksNextStage(stageRunStatusForTasks(previousTasks));
  }

  /// Кто работал на этапе и сколько каждый сделал, плюс общий тираж этапа.
  ///
  /// Заменяет прежнюю строку с именами исполнителей: она показывала только
  /// `assignees.first` и ничего не говорила о выработке, хотя на этапе почти
  /// всегда работают несколько человек и вопрос «кто сколько сделал» — первый,
  /// который задают о завершённом этапе.
  Widget? _buildStageOutput(
    List<TaskModel> stageTasks,
    PersonnelProvider personnel,
  ) {
    if (stageTasks.isEmpty) return null;
    // Правило рабочего места: на станках, где тираж делает машина, а бригада её
    // обслуживает, отрезок между собой не делят — каждому идёт полное
    // количество. Умолчание совпадает с серверным (`coalesce(..., true)`).
    var splitByTime = true;
    for (final workplace in personnel.workplaces) {
      if (workplace.id != stageTasks.first.stageId) continue;
      splitByTime = workplace.splitQuantityByTime;
      break;
    }
    final output = stageOutputForTasks(stageTasks, splitByTime: splitByTime);
    if (output.participants.isEmpty && !output.hasTotal) return null;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final participant in output.participants)
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Tooltip(
                      message: participantRunStateLabel(participant.state),
                      child: Text(
                        _assigneeNames([participant.userId], personnel),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          height: 1.15,
                          fontWeight: participant.state == UserRunState.active
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: participantRunStateColor(participant.state),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    formatStageQty(participant.qty),
                    style: TextStyle(
                      fontSize: 10.5,
                      height: 1.15,
                      fontWeight: participant.hasQty
                          ? FontWeight.w600
                          : FontWeight.normal,
                      color: participant.hasQty
                          ? WorkspaceColors.foreground
                          : WorkspaceColors.mutedForeground,
                    ),
                  ),
                ],
              ),
            ),
          if (output.hasTotal) ...[
            const SizedBox(height: 3),
            const Divider(height: 1, thickness: 0.6),
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Итого',
                      style: TextStyle(
                        fontSize: 10.5,
                        height: 1.15,
                        color: WorkspaceColors.mutedForeground,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    formatStageQty(output.totalQty),
                    style: const TextStyle(
                      fontSize: 11,
                      height: 1.15,
                      fontWeight: FontWeight.w700,
                      color: WorkspaceColors.foreground,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStageTile({
    required int index,
    required pcompat.PlannedStage planned,
    required Map<String, List<TaskModel>> tasksByStage,
    required PersonnelProvider personnel,
  }) {
    final stageIds = _plannedStageIds(planned);
    final stageLabel = _plannedStageLabel(planned, stageIds, personnel);
    final stageTasks = <TaskModel>[];
    for (final id in stageIds) {
      stageTasks.addAll(tasksByStage[id] ?? const <TaskModel>[]);
    }
    final status = _groupStatus(stageTasks);
    final runStatus = stageRunStatusForTasks(
      stageTasks,
      availableToStart: _previousStageUnlocks(index, tasksByStage),
    );
    final accent = stageRunStatusColor(runStatus);
    final background = _stageStatusBackground(accent);

    DateTime? start;
    DateTime? end;
    for (final t in stageTasks) {
      if (t.startedAt == null) continue;
      // started_at — абсолютный UTC-epoch; показываем в Костанайском времени.
      final st = toKostanayTime(
          DateTime.fromMillisecondsSinceEpoch(t.startedAt!, isUtc: true));
      if (start == null || st.isBefore(start)) start = st;
      final spent = _elapsed(t);
      if (spent.inSeconds > 0) {
        final en = st.add(spent);
        if (end == null || en.isAfter(end)) end = en;
      }
    }

    final commentsCount =
        stageTasks.fold<int>(0, (sum, t) => sum + t.comments.length);

    // Плитка держится компактной: номер, название, статус и время — по одной
    // строке каждое. Действия (пропуск/возобновление) живут иконкой в углу,
    // отдельная кнопка-строка растила плитку вдвое.
    final canSkip = widget.allowStageActions && status != TaskStatus.completed;
    final canReopen =
        widget.allowStageActions && status == TaskStatus.completed;

    final stageOutput = _buildStageOutput(stageTasks, personnel);

    // Сверка тиража с планом — только у завершённых этапов. Пока этап идёт,
    // количество меньше плана по определению, и точка горела бы у всех.
    final quantityCheck = status == TaskStatus.completed
        ? checkStageQuantity(
            order: widget.order,
            stageTasks: stageTasks,
            unit: personnel.workplaceById(stageTasks.first.stageId)?.unit,
            splitByTime: personnel
                    .workplaceById(stageTasks.first.stageId)
                    ?.splitQuantityByTime ??
                true,
          )
        : null;

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 7, 6, 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 16,
                height: 16,
                alignment: Alignment.center,
                decoration:
                    BoxDecoration(color: accent, shape: BoxShape.circle),
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9.5,
                    height: 1,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  stageLabel,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.15,
                    fontWeight: FontWeight.w600,
                    color: WorkspaceColors.foreground,
                  ),
                ),
              ),
              if (quantityCheck != null && quantityCheck.isProblem)
                PulsingDot(
                  color: getQuantityStatusColor(quantityCheck.status),
                  size: 7,
                  tooltip: 'Количество разошлось с планом: '
                      '${formatQuantityNumber(quantityCheck.actual)} '
                      'из ${formatQuantityNumber(quantityCheck.expected)} '
                      '(${quantityCheck.signedPercentLabel})',
                ),
              if (canSkip)
                _stageActionIcon(
                  icon: Icons.skip_next,
                  tooltip: 'Пропустить этап',
                  onPressed: _loadingPlan
                      ? null
                      : () =>
                          _skipStageForTesting(planned, stageTasks, stageIds),
                )
              else if (canReopen)
                _stageActionIcon(
                  icon: Icons.restart_alt,
                  tooltip: 'Возобновить этап',
                  onPressed: _reopeningStage
                      ? null
                      : () => _confirmReopenStage(stageLabel, stageTasks),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  stageRunStatusLabel(runStatus),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.1,
                    fontWeight: FontWeight.w600,
                    color: accent,
                  ),
                ),
              ),
              if (commentsCount > 0) ...[
                const Icon(Icons.chat_bubble_outline,
                    size: 11, color: WorkspaceColors.mutedForeground),
                const SizedBox(width: 2),
                Text(
                  '$commentsCount',
                  style: const TextStyle(
                    fontSize: 10.5,
                    height: 1.1,
                    color: WorkspaceColors.mutedForeground,
                  ),
                ),
              ],
            ],
          ),
          if (stageOutput != null) stageOutput,
          if (start != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '${_formatTime(start)} → ${end != null ? _formatTime(end) : '…'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 10,
                  height: 1.1,
                  color: WorkspaceColors.mutedForeground,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _stageActionIcon({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Icon(
            icon,
            size: 15,
            color: onPressed == null
                ? WorkspaceColors.disabledForeground
                : WorkspaceColors.mutedForeground,
          ),
        ),
      ),
    );
  }

  /// Возобновление завершённого этапа: спрашиваем подтверждение — операция
  /// меняет состояние заказа, а не только карточку.
  Future<void> _confirmReopenStage(
    String stageLabel,
    List<TaskModel> stageTasks,
  ) async {
    if (stageTasks.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Возобновить этап?'),
        content: Text(
          'Этап «$stageLabel» вернётся в работу. Время, количество и '
          'комментарии сохранятся — после возобновления они дополняются.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Возобновить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _reopeningStage = true);
    final messenger = ScaffoldMessenger.of(context);
    final provider = context.read<TaskProvider>();
    String? error;
    try {
      error = await provider.reopenStageGroup(
        task: stageTasks.first,
        actorUserId: 'system',
      );
    } catch (e) {
      error = 'Не удалось возобновить этап: $e';
    }
    if (!mounted) return;
    setState(() => _reopeningStage = false);
    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    await _loadPlan();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text('Этап «$stageLabel» возобновлён')),
    );
  }

  Widget _buildCommentsPanel({
    required List<TaskModel> commentsTasks,
    required PersonnelProvider personnel,
  }) {
    final comments = <TaskComment>[];
    // time_event — интервальный дубль пауз/проблем (сырой JSON-пейлоад),
    // в ленте не показываем, как и служебные флаги состояния.
    const hiddenTypes = <String>{
      'shift_pause_state',
      'exec_mode',
      'exec_mode_stage',
      'time_event',
    };
    final stageNamesByCommentId = <String, String>{};
    for (final t in commentsTasks) {
      final stageName = _resolveStageName(t.stageId, personnel);
      for (final comment in t.comments) {
        if (hiddenTypes.contains(comment.type.trim().toLowerCase())) continue;
        comments.add(comment);
        if (stageName.isNotEmpty) {
          stageNamesByCommentId[comment.id] = stageName;
        }
      }
    }
    comments.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    _ensureCommentAttachments(comments.map((c) => c.id));

    final ordersProvider = context.read<OrdersProvider>();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: workspaceCardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.forum_outlined,
                size: 20,
                color: WorkspaceColors.mutedForeground,
              ),
              const SizedBox(width: 8),
              Text(
                _showOrderHistory ? 'История заказа' : 'Комментарии',
                style: const TextStyle(
                  color: WorkspaceColors.foreground,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              _buildFeedSwitch(),
            ],
          ),
          const SizedBox(height: 10),
          if (_showOrderHistory)
            // Без внешнего SingleChildScrollView: ленту прокручивает её
            // собственный список. Два вложенных скролла не работали — жест
            // забирал внутренний ListView, а прокручиваться он не мог.
            Expanded(
              child: OrderHistoryView(
                order: widget.order,
                loadEvents: ordersProvider.fetchOrderHistory,
              ),
            )
          else ...[
            OrderGenerationSwitcher(
              generations: _restartAncestors,
              currentOrderId: _currentOrderId,
              selectedOrderId: _selectedCommentsOrderId,
              loading: _loadingRestartHistory,
              onSelected: (orderId) =>
                  setState(() => _selectedCommentsOrderId = orderId),
            ),
            Expanded(
              child: OrderCommentsTimeline(
                comments: comments,
                attachmentsByComment: _attachmentsByComment,
                stageNamesByCommentId: stageNamesByCommentId,
                // Плотность как в рабочем пространстве (эталон ~0.7-0.76).
                tileScale: 0.85,
                emptyLabel: _isHistoryReadOnly
                    ? 'Комментариев по этому заказу нет'
                    : 'Комментариев пока нет',
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Переключатель ленты: комментарии этапов ↔ история заказа. История
  /// раньше открывалась «часами» из списка заказов — кнопку убрали, а
  /// содержимое переехало сюда.
  Widget _buildFeedSwitch() {
    Widget item(String label, bool active, VoidCallback onTap) {
      return Material(
        color: active ? WorkspaceColors.surface : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                color: active
                    ? WorkspaceColors.foreground
                    : WorkspaceColors.mutedForeground,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: WorkspaceColors.secondaryBackground,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          item(
            'Комментарии',
            !_showOrderHistory,
            () => setState(() => _showOrderHistory = false),
          ),
          item(
            'История',
            _showOrderHistory,
            () => setState(() => _showOrderHistory = true),
          ),
        ],
      ),
    );
  }

  /// Расход бумаги по факту — для «Длина: 3000 м · списано 1200 м».
  Future<void> _loadPaperUsage() async {
    try {
      final state =
          await OrdersRepository().getPaperUsageState(widget.order.id);
      if (!mounted) return;
      setState(() => _paperUsage = state);
    } catch (e) {
      debugPrint('⚠️ не удалось загрузить расход бумаги заказа: $e');
    }
  }

  Future<void> _loadShipments() async {
    try {
      final rows = await context
          .read<OrdersProvider>()
          .fetchOrderShipments(widget.order.id);
      if (!mounted) return;
      setState(() => _shipments = rows);
    } catch (e) {
      debugPrint('⚠️ не удалось загрузить отгрузки заказа: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final taskProvider = context.watch<TaskProvider>();
    final personnel = context.watch<PersonnelProvider>();
    final tasks =
        taskProvider.tasks.where((t) => t.orderId == _currentOrderId).toList();
    final commentsTasks = taskProvider.tasks
        .where((t) => t.orderId == _selectedCommentsOrderId)
        .toList();

    final Map<String, List<TaskModel>> tasksByStage = {};
    for (final t in tasks) {
      tasksByStage.putIfAbsent(t.stageId, () => []).add(t);
    }

    final size = MediaQuery.of(context).size;
    final dialogHeight = size.height - 32;
    final dialogWidth = math.min(size.width - 32, 1280.0);

    // Раскладка повторяет рабочее пространство: слева — карточка заказа тем
    // же компоновщиком (OrderDetailsCard в workspace-режиме), справа сверху
    // вместо кнопок управления — этапы, снизу — комментарии и история.
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      backgroundColor: WorkspaceColors.background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(WorkspaceMetrics.cardRadius),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: dialogHeight,
          maxWidth: dialogWidth,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildDialogHeader(),
            const Divider(height: 1, color: WorkspaceColors.border),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final detailsPanel = _detailsCard(
                    child: OrderDetailsCard(
                      order: widget.order,
                      paints: _paints,
                      files: _files,
                      formFiles: _formFiles,
                      filesLoading: _loadingFiles,
                      stageTemplateName: _stageTemplateName,
                      formDetails: _formDetails,
                      shipments: _shipments,
                      workspaceStyle: true,
                      paperUsage: _paperUsage,
                    ),
                  );
                  final stagesPanel = _buildStagesPanel(
                    tasksByStage: tasksByStage,
                    personnel: personnel,
                  );
                  final commentsPanel = _buildCommentsPanel(
                    commentsTasks: commentsTasks,
                    personnel: personnel,
                  );
                  // Комментарий менеджера — отдельным красным блоком над
                  // карточкой заказа, вне её рамки.
                  final managerComment = widget.order.comments;
                  final hasManagerComment =
                      OrderManagerCommentBanner.hasComment(managerComment);

                  if (constraints.maxWidth >= 900) {
                    return Padding(
                      padding: const EdgeInsets.all(
                        WorkspaceMetrics.outerPadding,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: 392,
                            child: Scrollbar(
                              controller: _scrollController,
                              thumbVisibility: true,
                              child: SingleChildScrollView(
                                controller: _scrollController,
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    if (hasManagerComment) ...[
                                      OrderManagerCommentBanner(
                                        comment: managerComment,
                                      ),
                                      const SizedBox(
                                        height: WorkspaceMetrics.columnGap,
                                      ),
                                    ],
                                    detailsPanel,
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: WorkspaceMetrics.columnGap),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // Длинный маршрут не должен выдавливать
                                // комментарии: панель этапов ограничена
                                // половиной высоты и скроллится сама.
                                ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxHeight: constraints.maxHeight * 0.5,
                                  ),
                                  child: SingleChildScrollView(
                                    child: stagesPanel,
                                  ),
                                ),
                                const SizedBox(
                                  height: WorkspaceMetrics.columnGap,
                                ),
                                Expanded(child: commentsPanel),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  }

                  // Свой контроллер узкой раскладке не нужен: он один на
                  // экран, а при смене раскладки два ScrollView успели бы
                  // повиснуть на нём одновременно.
                  return SingleChildScrollView(
                    padding: const EdgeInsets.all(
                      WorkspaceMetrics.outerPadding,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (hasManagerComment) ...[
                          OrderManagerCommentBanner(comment: managerComment),
                          const SizedBox(height: WorkspaceMetrics.columnGap),
                        ],
                        detailsPanel,
                        const SizedBox(height: WorkspaceMetrics.columnGap),
                        stagesPanel,
                        const SizedBox(height: WorkspaceMetrics.columnGap),
                        SizedBox(height: 460, child: commentsPanel),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDialogHeader() {
    return Container(
      color: WorkspaceColors.surface,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Заказ ${widget.order.assignmentId ?? widget.order.id}',
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: WorkspaceColors.foreground,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: 'Обновить данные',
            color: WorkspaceColors.mutedForeground,
            onPressed: (_loadingFiles || _loadingPlan) ? null : _reloadAll,
            icon: const Icon(Icons.refresh, size: 18),
          ),
          IconButton(
            tooltip: 'Закрыть',
            color: WorkspaceColors.mutedForeground,
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }

  /// Белая карточка с тонкой рамкой — общий контейнер разделов экрана.
  Widget _detailsCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: workspaceCardDecoration(),
      child: child,
    );
  }
}
