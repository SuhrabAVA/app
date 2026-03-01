// lib/modules/production/production_details_screen.dart
//
// Полный файл без урезаний. НИЧЕГО лишнего не создаю.
// Исправление: загрузка этапов теперь основана на СУЩЕСТВУЮЩИХ таблицах
//   1) public.prod_plans -> public.prod_plan_stages  (основной путь)
//   2) public.v_order_plan_stages                     (если есть)
//   3) public.production_plans.stages (JSON, старый вариант) — фоллбек
// Плюс обязательная авторизация перед запросами (RLS).
//
// Требуется: services/app_auth.dart с AppAuth.ensureSignedIn().
//
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/storage_service.dart' as storage;
import '../production_planning/compat.dart' as pcompat;
import '../orders/orders_repository.dart';
import '../orders/order_model.dart';
import '../tasks/task_model.dart';
import '../tasks/task_provider.dart';
// УДАЛЕНО: import '../production_planning/planned_stage_model.dart';
import '../personnel/employee_model.dart';
import '../personnel/personnel_provider.dart';
import '../../services/app_auth.dart';
import '../orders/order_details_card.dart';

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
    final primary = planned.stageId.trim();
    if (primary.isNotEmpty) ids.add(primary);
    final extra = planned.extra;
    final altIds = _decodeStringList(
      extra['alternativeStageIds'] ?? extra['alternative_stage_ids'],
    );
    ids.addAll(altIds.where((id) => id.trim().isNotEmpty));
    return ids.toList();
  }

  int _readStageOrder(Map<String, dynamic> row) {
    const keys = ['step', 'step_no', 'seq', 'order', 'position', 'idx'];
    for (final key in keys) {
      final value = row[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) {
        final parsed = int.tryParse(value.trim());
        if (parsed != null) return parsed;
      }
    }
    return 0;
  }

  List<String> _plannedStageNames(pcompat.PlannedStage planned) {
    final names = <String>{};
    final base = planned.stageName.trim();
    if (base.isNotEmpty) names.add(base);
    final extra = planned.extra;
    final altNames = _decodeStringList(
      extra['alternativeStageNames'] ?? extra['alternative_stage_names'],
    );
    for (final name in altNames) {
      final trimmed = name.trim();
      if (trimmed.isNotEmpty) names.add(trimmed);
    }
    return names.toList();
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
    final names = _plannedStageNames(planned);
    if (names.isNotEmpty) {
      return names.join(' / ');
    }
    if (stageIds.isEmpty) return planned.stageName;
    final resolved = stageIds
        .map((id) => _resolveStageName(id, personnel))
        .where((name) => name.trim().isNotEmpty)
        .toList();
    return resolved.isEmpty ? planned.stageName : resolved.toSet().join(' / ');
  }

  TaskStatus? _groupStatus(List<TaskModel> stageTasks) {
    if (stageTasks.isEmpty) return null;

    bool isEffectivelyCompleted(TaskModel task) {
      if (task.status == TaskStatus.completed) return true;
      for (final comment in task.comments) {
        final type = comment.type.trim().toLowerCase();
        if (type == 'user_done' || type == 'finish_note') {
          return true;
        }

        final text = comment.text.trim().toLowerCase();
        if (text == 'done' || text == 'finish' || text == 'finished') {
          return true;
        }

        if (text.startsWith('{') && text.contains('"endtime"')) {
          return true;
        }
      }
      return false;
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
    if (stageTasks.any(isEffectivelyCompleted)) {
      return TaskStatus.completed;
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

  Future<void> _loadOrderDetails() async {
    setState(() => _loadingFiles = true);
    try {
      final repo = OrdersRepository();
      final paints = await repo.getPaints(widget.order.id);
      final files = await storage.listOrderFiles(widget.order.id);
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

      // ========== ПУТЬ 1: prod_plans -> prod_plan_stages ==========
      List<pcompat.PlannedStage> stages = [];
      try {
        final plan = await sb
            .from('prod_plans')
            .select('id')
            .eq('order_id', orderId)
            .maybeSingle();

        if (plan != null && plan is Map && plan['id'] != null) {
          final String planId = plan['id'] as String;
          final rows = await sb
              .from('prod_plan_stages')
              .select('stage_id, stage_name, workplace_name, name, step, step_no, seq')
              .eq('plan_id', planId);

          if (rows is List && rows.isNotEmpty) {
            final normalizedRows = rows
                .whereType<Map>()
                .map((r) => Map<String, dynamic>.from(r))
                .toList()
              ..sort((a, b) => _readStageOrder(a).compareTo(_readStageOrder(b)));
            for (final m in normalizedRows) {
              final id =
                  (m['stage_id'] ?? m['id'] ?? m['workplace_id'] ?? '').toString();
              final name =
                  (m['stage_name'] ?? m['workplace_name'] ?? m['name'] ?? 'Этап')
                      .toString();
              if (id.isNotEmpty) {
                stages.add(pcompat.PlannedStage(stageId: id, stageName: name));
              }
            }
          }
        }
      } catch (_) {
        // игнорируем и перейдём к следующему источнику
      }

      // ========== ПУТЬ 2: public.v_order_plan_stages (если есть) ==========
      if (stages.isEmpty) {
        try {
          final rows = await sb
              .from('v_order_plan_stages')
              .select('stage_id, stage_name, step_no, order_id, order_code')
              .or('order_id.eq.$orderId,order_code.eq.$orderCode')
              .order('step_no', ascending: true);

          if (rows is List && rows.isNotEmpty) {
            for (final r in rows) {
              final m = (r as Map<String, dynamic>);
              final id = (m['stage_id'] ?? '').toString();
              final name = (m['stage_name'] ?? 'Этап').toString();
              if (id.isNotEmpty) {
                stages.add(pcompat.PlannedStage(stageId: id, stageName: name));
              }
            }
          }
        } catch (_) {
          // нет представления — идём дальше
        }
      }

      // ========== ПУТЬ 3: production_plans.stages (JSON, старый) ==========
      if (stages.isEmpty) {
        try {
          final planJson = await sb
              .from('production_plans')
              .select('stages')
              .eq('order_id', orderId)
              .maybeSingle();

          if (planJson != null &&
              planJson is Map &&
              planJson['stages'] != null) {
            stages = pcompat.decodePlannedStages(planJson['stages']);
          }
        } catch (_) {}
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
    for (final t in tasks) {
      comments.addAll(t.comments);
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
            if (comments.isEmpty)
              const Text(
                'Нет комментариев',
                style: TextStyle(color: Colors.grey),
              )
            else
              Column(
                children: [
                  for (final c in comments)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            c.type == 'problem'
                                ? Icons.error_outline
                                : c.type == 'pause'
                                    ? Icons.pause_circle_outline
                                    : Icons.info_outline,
                            size: 18,
                            color: c.type == 'problem'
                                ? Colors.redAccent
                                : c.type == 'pause'
                                    ? Colors.orange
                                    : Colors.blueGrey,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildCommentMeta(c, personnel.employees),
                                Text(
                                  c.text,
                                  style: const TextStyle(fontSize: 14),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
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
                            loadingFiles: _loadingFiles,
                            stageTemplateName: _stageTemplateName,
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
