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
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/storage_service.dart';
import 'package:url_launcher/url_launcher.dart';
import '../production_planning/compat.dart' as pcompat;
import '../orders/orders_repository.dart';
import '../orders/order_model.dart';
import '../tasks/task_model.dart';
import '../tasks/task_provider.dart';
// УДАЛЕНО: import '../production_planning/planned_stage_model.dart';
import '../personnel/employee_model.dart';
import '../personnel/personnel_provider.dart';
import '../personnel/workplace_model.dart';
import '../production_planning/template_model.dart';
import '../production_planning/template_provider.dart';
import '../../services/app_auth.dart';
import '../common/pdf_view_screen.dart'; // <= добавлено для встроенного просмотра PDF

enum _AggregatedStatus { production, paused, problem, completed, waiting }

class ProductionDetailsScreen extends StatefulWidget {
  final OrderModel order;
  const ProductionDetailsScreen({super.key, required this.order});

  @override
  State<ProductionDetailsScreen> createState() =>
      _ProductionDetailsScreenState();
}

class _ProductionDetailsScreenState extends State<ProductionDetailsScreen> {
  List<pcompat.PlannedStage> _plannedStages = [];
  bool _loadingPlan = true;

  Widget _buildOrderInfoCard(OrderModel o) {
    final dateFmt = DateFormat('dd.MM.yyyy');
    String d(DateTime? dt) => dt == null ? '—' : dateFmt.format(dt);

    final p = o.product;
    final material = o.material;
    final weight = material?.weight;
    final templateProvider =
        Provider.of<TemplateProvider?>(context, listen: true);
    final List<TemplateModel> templates =
        templateProvider?.templates ?? const <TemplateModel>[];

    String? _templateName(String? id) {
      if (id == null || id.isEmpty) return null;
      for (final tpl in templates) {
        if (tpl.id == id) return tpl.name;
      }
      return null;
    }

    Widget _tile(String label, String value, [IconData? icon]) {
      return ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: icon != null ? Icon(icon, color: Colors.blueGrey) : null,
        title: Text(label,
            style: const TextStyle(fontSize: 13, color: Colors.black54)),
        subtitle: Text(value, style: const TextStyle(fontSize: 15)),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, 4))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Информация по заказу',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),

          // Основное
          _tile('Менеджер', o.manager, Icons.person_outline),
          _tile('Заказчик', o.customer, Icons.business_outlined),
          Row(
            children: [
              Expanded(
                  child: _tile('Дата заказа', d(o.orderDate), Icons.event)),
              const SizedBox(width: 12),
              Expanded(
                  child: _tile('Срок выполнения', d(o.dueDate),
                      Icons.schedule_outlined)),
            ],
          ),

          const Divider(height: 24),

          // Комментарии менеджера
          const Text('Комментарий',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            o.comments.isEmpty ? '—' : o.comments,
            style: const TextStyle(fontSize: 15),
          ),

          // Продукт
          const Text('Продукт',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          _tile('Наименование изделия', p.type, Icons.widgets_outlined),
          Row(children: [
            Expanded(
                child: _tile('Тираж', p.quantity.toString(), Icons.numbers)),
            const SizedBox(width: 12),
            Expanded(
                child: _tile('Параметры',
                    p.parameters.isEmpty ? '—' : p.parameters, Icons.tune)),
          ]),
          Row(children: [
            Expanded(
                child: _tile('Ширина (мм)', p.width.toStringAsFixed(0),
                    Icons.straighten)),
            const SizedBox(width: 12),
            Expanded(
                child: _tile('Высота (мм)', p.height.toStringAsFixed(0),
                    Icons.straighten)),
            const SizedBox(width: 12),
            Expanded(
                child: _tile('Глубина (мм)', p.depth.toStringAsFixed(0),
                    Icons.straighten)),
          ]),
          Row(children: [
            Expanded(
                child: _tile('Ролл', p.roll?.toStringAsFixed(2) ?? '—',
                    Icons.view_stream)),
            const SizedBox(width: 12),
            Expanded(
                child: _tile('Ширина b', p.widthB?.toStringAsFixed(2) ?? '—',
                    Icons.swap_horiz)),
            const SizedBox(width: 12),
            Expanded(
                child: _tile('Количество',
                    p.blQuantity ?? '—', Icons.numbers)),
            const SizedBox(width: 12),
            Expanded(
                child: _tile('Длина L', p.length?.toStringAsFixed(2) ?? '—',
                    Icons.swap_vert)),
          ]),
          Row(children: [
            Expanded(
                child: _tile('Отход',
                    p.leftover == null ? '—' : p.leftover!.toStringAsFixed(2),
                    Icons.delete_outline)),
            const SizedBox(width: 12),
            Expanded(
                child: _tile('Фактический выпуск',
                    o.actualQty == null
                        ? '—'
                        : (o.actualQty! % 1 == 0
                            ? o.actualQty!.toInt().toString()
                            : o.actualQty!.toStringAsFixed(2)),
                    Icons.speed_outlined)),
          ]),

          const Divider(height: 24),

          // Формы и шаблон этапов
          const Text('Форма и этапы',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          _tile('Код формы', o.formCode ?? '—', Icons.confirmation_number),
          Row(
            children: [
              Expanded(
                  child: _tile('Серия', o.formSeries ?? '—', Icons.tag)),
              const SizedBox(width: 12),
              Expanded(
                  child: _tile('Номер',
                      o.newFormNo != null ? '${o.newFormNo}' : '—',
                      Icons.numbers)),
            ],
          ),
          _tile('Старая форма', o.isOldForm ? 'Да' : 'Нет', Icons.history),
          _tile(
            'Шаблон этапов',
            _templateName(o.stageTemplateId) ??
                (o.stageTemplateId == null || o.stageTemplateId!.isEmpty
                    ? '—'
                    : o.stageTemplateId!),
            Icons.account_tree_outlined,
          ),

          const Divider(height: 24),

          // Материал
          const Text('Материал',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          _tile('Материал', material?.name ?? '—', Icons.layers_outlined),
          Row(children: [
            Expanded(
                child:
                    _tile('Формат', material?.format ?? '—', Icons.crop_5_4)),
            const SizedBox(width: 12),
            Expanded(
                child: _tile(
                    'Плотность', material?.grammage ?? '—', Icons.texture)),
          ]),
          Row(children: [
            Expanded(
                child: _tile(
                    'Кол-во',
                    material == null
                        ? '—'
                        : (material.quantity % 1 == 0
                            ? material.quantity.toInt().toString()
                            : material.quantity.toStringAsFixed(2)),
                    Icons.scale)),
            const SizedBox(width: 12),
            Expanded(
                child:
                    _tile('Ед. изм.', material?.unit ?? '—', Icons.category)),
            const SizedBox(width: 12),
            Expanded(
                child: _tile(
                    'Вес',
                    weight == null ? '—' : weight.toStringAsFixed(2),
                    Icons.fitness_center)),
          ]),

          const Divider(height: 24),

          // Краски
          const Text('Краски',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: OrdersRepository().getPaints(o.id),
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const SizedBox.shrink();
              }
              final items = snap.data ?? const [];
              if (items.isEmpty) {
                return const Text('Не указаны',
                    style: TextStyle(color: Colors.black54));
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: items.map((m) {
                  final name =
                      (m['name'] ?? m['paint_name'] ?? 'краска').toString();
                  final info = (m['info'] ?? '').toString();
                  final qty = (m['qty'] ?? m['quantity'] ?? '').toString();
                  final parts = [
                    name,
                    if (info.isNotEmpty) info,
                    if (qty.isNotEmpty) 'x$qty'
                  ];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        const Icon(Icons.color_lens_outlined, size: 18),
                        const SizedBox(width: 8),
                        Expanded(child: Text(parts.join(' · '))),
                      ],
                    ),
                  );
                }).toList(),
              );
            },
          ),

          const Divider(height: 24),
          // Прочее
          _tile('Ручки', o.handle.isEmpty ? '-' : o.handle,
              Icons.handyman_outlined),
          _tile('Картон', o.cardboard, Icons.inbox_outlined),
          Row(children: [
            Expanded(
                child: _tile('Приладка', o.makeready.toStringAsFixed(2),
                    Icons.calculate_outlined)),
            const SizedBox(width: 12),
            Expanded(
                child: _tile(
                    'ВАЛ', o.val.toStringAsFixed(2), Icons.calculate_outlined)),
          ]),
          if (o.additionalParams.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text('Дополнительные параметры',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children:
                  o.additionalParams.map((s) => Chip(label: Text(s))).toList(),
            ),
          ],

          const SizedBox(height: 8),

          // PDF и вложения
          Builder(builder: (context) {
            final hasPdf = (o.pdfUrl != null && o.pdfUrl!.isNotEmpty);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Вложения',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                if (hasPdf)
                  Row(
                    children: [
                      const Icon(Icons.picture_as_pdf_outlined,
                          color: Colors.redAccent),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(o.pdfUrl!.split('/').last,
                              overflow: TextOverflow.ellipsis)),
                      TextButton.icon(
                        onPressed: () async {
                          final url = await getSignedUrl(o.pdfUrl!);
                          if (!mounted) return;
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  PdfViewScreen(url: url, title: 'PDF заказа'),
                            ),
                          );
                        },
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('Открыть'),
                      ),
                    ],
                  )
                else
                  const Text('PDF не прикреплён',
                      style: TextStyle(color: Colors.black54)),
                const SizedBox(height: 4),
                // Дополнительные файлы из метаданных, если есть
                FutureBuilder<List<Map<String, dynamic>>>(
                  future: listOrderFiles(o.id),
                  builder: (context, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const SizedBox.shrink();
                    }
                    final items = snap.data ?? const [];
                    if (items.isEmpty) return const SizedBox.shrink();
                    return Column(
                      children: items.map((it) {
                        final fname =
                            (it['fileName'] ?? it['name'] ?? 'file').toString();
                        final path =
                            (it['path'] ?? it['objectPath'] ?? '').toString();
                        return Row(
                          children: [
                            const Icon(Icons.attachment_outlined),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Text(fname,
                                    overflow: TextOverflow.ellipsis)),
                            TextButton.icon(
                              onPressed: path.isEmpty
                                  ? null
                                  : () async {
                                      final url = await getSignedUrl(path);
                                      if (!mounted) return;
                                      Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => PdfViewScreen(
                                              url: url, title: 'Вложение'),
                                        ),
                                      );
                                    },
                              icon: const Icon(Icons.open_in_new),
                              label: const Text('Открыть'),
                            ),
                          ],
                        );
                      }).toList(),
                    );
                  },
                ),
              ],
            );
          }),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadPlan();
  }

  Future<void> _loadPlan() async {
    try {
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
              .select('id, name, seq')
              .eq('plan_id', planId)
              .order('seq', ascending: true);

          if (rows is List && rows.isNotEmpty) {
            for (final r in rows) {
              final m = (r as Map<String, dynamic>);
              final id = (m['id'] ?? '').toString();
              final name = (m['name'] ?? 'Этап').toString();
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

  _AggregatedStatus _computeAggregatedStatus(List<TaskModel> tasks) {
    if (tasks.isEmpty) return _AggregatedStatus.waiting;
    final hasProblem = tasks.any((t) => t.status == TaskStatus.problem);
    if (hasProblem) return _AggregatedStatus.problem;
    final hasPaused = tasks.any((t) => t.status == TaskStatus.paused);
    final allCompleted = tasks.isNotEmpty &&
        tasks.every((t) => t.status == TaskStatus.completed);
    if (allCompleted) return _AggregatedStatus.completed;
    if (hasPaused) return _AggregatedStatus.paused;
    final hasInProgress = tasks.any((t) => t.status == TaskStatus.inProgress);
    if (hasInProgress) return _AggregatedStatus.production;
    final hasWaiting = tasks.any((t) => t.status == TaskStatus.waiting);
    if (hasWaiting) return _AggregatedStatus.production;
    return _AggregatedStatus.production;
  }

  Widget _buildStatusBadge({
    required String label,
    required Color color,
    required _AggregatedStatus targetStatus,
    required _AggregatedStatus currentStatus,
  }) {
    final bool active = currentStatus == targetStatus;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Container(
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? color.withOpacity(0.15) : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active ? color : Colors.grey.shade300,
              width: active ? 1.5 : 1,
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: active ? color : Colors.grey.shade700,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
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

  String _statusLabel(_AggregatedStatus status) {
    switch (status) {
      case _AggregatedStatus.production:
        return 'Производство';
      case _AggregatedStatus.paused:
        return 'На паузе';
      case _AggregatedStatus.problem:
        return 'Проблема';
      case _AggregatedStatus.completed:
        return 'Завершено';
      case _AggregatedStatus.waiting:
        return 'Ожидание запуска';
    }
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

    final aggStatus = _computeAggregatedStatus(tasks);
    final highlightStatus = aggStatus == _AggregatedStatus.waiting
        ? _AggregatedStatus.production
        : aggStatus;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.order.customer),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _loadingPlan
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Информация по заказу (для сотрудника)
                    _buildOrderInfoCard(widget.order),
                    const SizedBox(height: 16),
                    // Карточка с общей информацией и управлением статусом
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.grey.withOpacity(0.2),
                            blurRadius: 6,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.order.customer,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            widget.order.customer,
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.order.product.type,
                            style: const TextStyle(fontSize: 16),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Icon(
                                Icons.layers,
                                size: 16,
                                color: Colors.grey,
                              ),
                              const SizedBox(width: 4),
                              Text('${widget.order.product.quantity} шт.'),
                              const SizedBox(width: 16),
                              const Icon(
                                Icons.calendar_today,
                                size: 16,
                                color: Colors.grey,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                widget.order.dueDate == null
                                    ? 'без срока'
                                    : 'до ${DateFormat('dd.MM.yyyy').format(widget.order.dueDate!)}',
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Текущее состояние: ${_statusLabel(aggStatus)}',
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.black54,
                            ),
                          ),
                          const SizedBox(height: 6),
                          // Управление статусом заказа
                          Row(
                            children: [
                              _buildStatusBadge(
                                label: 'Производство',
                                color: Colors.blue,
                                targetStatus: _AggregatedStatus.production,
                                currentStatus: highlightStatus,
                              ),
                              _buildStatusBadge(
                                label: 'На паузе',
                                color: Colors.orange,
                                targetStatus: _AggregatedStatus.paused,
                                currentStatus: highlightStatus,
                              ),
                              _buildStatusBadge(
                                label: 'Проблема',
                                color: Colors.redAccent,
                                targetStatus: _AggregatedStatus.problem,
                                currentStatus: highlightStatus,
                              ),
                              _buildStatusBadge(
                                label: 'Завершено',
                                color: Colors.green,
                                targetStatus: _AggregatedStatus.completed,
                                currentStatus: highlightStatus,
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          // Список комментариев к заказу
                          const Text(
                            'Комментарии',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Builder(
                            builder: (context) {
                              final comments = <TaskComment>[];
                              for (final t in tasks) {
                                comments.addAll(t.comments);
                              }
                              comments.sort(
                                (a, b) => a.timestamp.compareTo(b.timestamp),
                              );
                              if (comments.isEmpty) {
                                return const Text(
                                  'Нет комментариев',
                                  style: TextStyle(color: Colors.grey),
                                );
                              }
                              return Column(
                                children: [
                                  for (final c in comments)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 2,
                                      ),
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
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
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                _buildCommentMeta(
                                                  c,
                                                  personnel.employees,
                                                ),
                                                Text(
                                                  c.text,
                                                  style: const TextStyle(
                                                    fontSize: 14,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Этапы производства
                    const Text(
                      'Этапы производства',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_plannedStages.isEmpty)
                      const Text(
                        'План этапов отсутствует',
                        style: TextStyle(color: Colors.grey),
                      )
                    else
                      Column(
                        children: [
                          for (final planned in _plannedStages)
                            Builder(
                              builder: (context) {
                                final stageId = planned.stageId;
                                final stage = personnel.workplaces.firstWhere(
                                  (s) => s.id == stageId,
                                  orElse: () => WorkplaceModel(
                                    id: stageId,
                                    name: planned.stageName,
                                    positionIds: [],
                                  ),
                                );
                                final stageTasks = tasksByStage[stageId] ?? [];
                                TaskStatus? stageStatus;
                                if (stageTasks.isEmpty) {
                                  stageStatus = null;
                                } else if (stageTasks.every(
                                  (t) => t.status == TaskStatus.completed,
                                )) {
                                  stageStatus = TaskStatus.completed;
                                } else if (stageTasks.any(
                                  (t) => t.status == TaskStatus.problem,
                                )) {
                                  stageStatus = TaskStatus.problem;
                                } else if (stageTasks.any(
                                  (t) => t.status == TaskStatus.inProgress,
                                )) {
                                  stageStatus = TaskStatus.inProgress;
                                } else if (stageTasks.any(
                                  (t) => t.status == TaskStatus.paused,
                                )) {
                                  stageStatus = TaskStatus.paused;
                                } else {
                                  stageStatus = TaskStatus.waiting;
                                }
                                Color bgColor;
                                switch (stageStatus) {
                                  case TaskStatus.completed:
                                    bgColor = Colors.green.withOpacity(0.2);
                                    break;
                                  case TaskStatus.inProgress:
                                    bgColor = Colors.blue.withOpacity(0.2);
                                    break;
                                  case TaskStatus.paused:
                                    bgColor = Colors.orange.withOpacity(0.2);
                                    break;
                                  case TaskStatus.problem:
                                    bgColor = Colors.redAccent.withOpacity(0.2);
                                    break;
                                  case TaskStatus.waiting:
                                  default:
                                    bgColor = Colors.yellow.withOpacity(0.2);
                                    break;
                                }
                                DateTime? start;
                                DateTime? end;
                                if (stageTasks.isNotEmpty) {
                                  for (final t in stageTasks) {
                                    if (t.startedAt != null) {
                                      final st =
                                          DateTime.fromMillisecondsSinceEpoch(
                                        t.startedAt!,
                                      );
                                      if (start == null ||
                                          st.isBefore(start!)) {
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
                                  margin: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: bgColor,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      CircleAvatar(
                                        radius: 12,
                                        backgroundColor: Colors.white,
                                        child: Text(
                                          '${_plannedStages.indexOf(planned) + 1}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              stage.name,
                                              style: const TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            Text(
                                              stageTasks.isNotEmpty
                                                  ? 'Исполнители: ${stageTasks.first.assignees.join(', ')}'
                                                  : '',
                                              style: const TextStyle(
                                                fontSize: 14,
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
                                                  : stageStatus ==
                                                          TaskStatus.completed
                                                      ? 'Завершено'
                                                      : stageStatus ==
                                                              TaskStatus
                                                                  .inProgress
                                                          ? 'В процессе'
                                                          : 'Плановое завершение: —',
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
                                          padding: const EdgeInsets.only(
                                            left: 8.0,
                                          ),
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
            ),
    );
  }
}
