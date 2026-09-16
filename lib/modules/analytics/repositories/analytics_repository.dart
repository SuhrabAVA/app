import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../utils/kostanay_time.dart';
import '../models/analytics_day_comment.dart';
import '../models/analytics_event.dart';
import '../models/analytics_month.dart';
import 'task_analytics_mapper.dart';

class AnalyticsRepository {
  AnalyticsRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// Типы, собираемые только для отображения в лентах дня.
  /// НЕ пересекаются с расчётными типами TaskAnalyticsMapper и не влияют на
  /// зарплату/КПД — это отдельный слой отображения.
  static const _displayCommentTypes = {
    'comment',
    'msg',
    'problem',
    'pause',
    'resume',
    'start',
    'user_done',
    'joined',
    'finish_note',
    'helper_removed',
    'helper_removed_qty',
    'paper_change',
    'paint_change',
    'setup_start',
    'setup_resume',
    'shift_pause',
    'shift_resume',
    'skip_stage_test',
    'ink_writeoff',
  };

  /// Loads both current-month events and previous-month speed baselines
  /// in a single database round-trip (with full pagination — no 1000-row cap).
  ///
  /// Построение событий делегировано TaskAnalyticsMapper: он гарантирует,
  /// что каждое количество учитывается ровно один раз, а количества без
  /// парного production-интервала (например, quantity_team_total, который
  /// RPC пишет уже после закрытия интервала) не теряются — для них
  /// создаётся минутный fallback-event на своём рабочем месте.
  Future<
      ({
        List<AnalyticsEvent> events,
        Map<String, List<double>> prevSpeeds,
        List<AnalyticsDayComment> dayComments,
        Map<String, double> workplaceStageTotals,
      })> loadAllMonthData(AnalyticsMonth month, {DateTime? now}) async {
    final monthStart = month.firstDay.toUtc();
    final monthEnd = month.nextMonthFirstDay.toUtc();
    final reference = (now ?? DateTime.now()).toUtc();

    final taskMaps = await _fetchAllTaskRows();
    final orderIds = taskMaps
        .map((row) => (row['order_id'] ?? '').toString().trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    final customersByOrderId = await _loadCustomersByOrderId(orderIds);

    // Single pass — split comments into current-month and previous buckets.
    final currentRows = <TaskCommentRow>[];
    final prevRows = <TaskCommentRow>[];
    // Отображаемые события дня (не участвуют в расчётах зарплаты/КПД).
    final dayComments = <AnalyticsDayComment>[];
    // taskId -> сотрудники, работавшие помощниками (не основной исполнитель).
    final helpersByTask = <String, Set<String>>{};

    for (int i = 0; i < taskMaps.length; i++) {
      // Yield to the event loop every 100 tasks to keep the UI responsive.
      if (i > 0 && i % 100 == 0) await Future.delayed(Duration.zero);

      final task = taskMaps[i];
      final taskId = (task['id'] ?? '').toString();
      final orderId = (task['order_id'] ?? '').toString();
      final stageId = (task['stage_id'] ?? '').toString();
      final capturedBy =
          (task['captured_by_workplace_id'] ?? '').toString().trim();
      final customer = customersByOrderId[orderId];

      // Основной исполнитель совместной работы — первый в assignees: это же
      // правило действует в рабочем пространстве («Добавлять помощников
      // может только основной исполнитель»).
      final assignees = <String>[
        if (task['assignees'] is List)
          for (final raw in (task['assignees'] as List))
            if ((raw?.toString().trim() ?? '').isNotEmpty) raw.toString().trim(),
      ];
      final mainOperator = assignees.isEmpty ? '' : assignees.first;

      for (final comment
          in TaskAnalyticsMapper.normalizeComments(task['comments'])) {
        final type = (comment['type'] ?? '').toString();

        // Помощников собираем по ВСЕМ комментариям задачи, а не только за
        // выбранный месяц: этап мог начаться в прошлом месяце, и тогда
        // «joined» в текущую выборку не попал бы, а помощник считался бы
        // основным исполнителем и получил полную ставку.
        if (type == 'joined' && mainOperator.isNotEmpty) {
          final userId =
              (comment['userId'] ?? comment['user_id'] ?? '').toString().trim();
          if (userId.isNotEmpty && userId != mainOperator) {
            helpersByTask.putIfAbsent(taskId, () => <String>{}).add(userId);
          }
        }
        final timestamp =
            TaskAnalyticsMapper.parseCommentTimestamp(comment['timestamp']);
        if (timestamp == null) continue;

        if (_displayCommentTypes.contains(type)) {
          if (!timestamp.isBefore(monthStart) &&
              timestamp.isBefore(monthEnd)) {
            dayComments.add(AnalyticsDayComment(
              id: (comment['id'] ?? '').toString(),
              type: type,
              text: (comment['text'] ?? '').toString(),
              userId:
                  (comment['userId'] ?? comment['user_id'] ?? '').toString(),
              // Метка для показа/группировки по дню — в Костанайском времени
              // (UTC+5). Фильтрация месяца выше идёт по исходному UTC.
              timestamp: toKostanayTime(timestamp),
              taskId: taskId,
              orderId: orderId,
              workplaceId: stageId,
              customer: customer,
            ));
          }
          continue;
        }

        if (!TaskAnalyticsMapper.isAnalyticsCommentType(type)) continue;

        final row = TaskCommentRow(
          id: (comment['id'] ?? '').toString(),
          type: type,
          text: (comment['text'] ?? '').toString(),
          userId: (comment['userId'] ?? comment['user_id'] ?? '').toString(),
          timestamp: timestamp,
          taskId: taskId,
          stageId: stageId,
          orderId: orderId,
          capturedByWorkplaceId: capturedBy.isEmpty ? null : capturedBy,
          customer: customer,
        );

        if (!timestamp.isBefore(monthStart) && timestamp.isBefore(monthEnd)) {
          currentRows.add(row);
        } else if (timestamp.isBefore(monthStart)) {
          prevRows.add(row);
        }
      }
    }

    currentRows.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    prevRows.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    dayComments.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    final events = TaskAnalyticsMapper.buildEvents(
        currentRows, monthStart, monthEnd, reference,
        helpersByTask: helpersByTask);
    final prevSpeeds =
        TaskAnalyticsMapper.buildPreviousSpeeds(prevRows, monthStart, reference);
    // Тираж по рабочим местам — отдельной величиной: суммировать выработку
    // людей нельзя, на станках у каждого записан полный тираж.
    final workplaceStageTotals = TaskAnalyticsMapper.buildWorkplaceStageTotals(
        currentRows, monthStart, monthEnd);

    return (
      events: events,
      prevSpeeds: prevSpeeds,
      dayComments: dayComments,
      workplaceStageTotals: workplaceStageTotals,
    );
  }

  Future<List<AnalyticsEvent>> loadEventsForMonth(AnalyticsMonth month,
      {DateTime? now}) async {
    return (await loadAllMonthData(month, now: now)).events;
  }

  Future<Map<String, List<double>>> loadPreviousWorkplaceMonthSpeeds(
      AnalyticsMonth month,
      {DateTime? now}) async {
    return (await loadAllMonthData(month, now: now)).prevSpeeds;
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  /// Fetches ALL tasks with pagination — bypasses Supabase's default 1 000-row limit.
  Future<List<Map<String, dynamic>>> _fetchAllTaskRows() async {
    final allRows = <dynamic>[];
    int offset = 0;
    const pageSize = 1000;
    while (true) {
      final List<dynamic> page = await _client
          .from('tasks')
          .select(
              'id, stage_id, order_id, captured_by_workplace_id, assignees, comments')
          .order('created_at', ascending: true)
          .range(offset, offset + pageSize - 1);
      if (page.isEmpty) break;
      allRows.addAll(page);
      if (page.length < pageSize) break;
      offset += pageSize;
    }
    return allRows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
  }

  Future<Map<String, String>> _loadCustomersByOrderId(
    Set<String> orderIds,
  ) async {
    if (orderIds.isEmpty) return const <String, String>{};

    // Чанки по 100 id: длинный in-фильтр упирается в лимит длины URL.
    final ids = orderIds.toList(growable: false);
    final customers = <String, String>{};
    const chunkSize = 100;
    for (var i = 0; i < ids.length; i += chunkSize) {
      final chunk = ids.sublist(
          i, i + chunkSize > ids.length ? ids.length : i + chunkSize);
      final List<dynamic> rows = await _client
          .from('orders')
          .select('id, customer')
          .inFilter('id', chunk);
      for (final row in rows.whereType<Map>()) {
        final id = (row['id'] ?? '').toString();
        if (id.isEmpty) continue;
        final customer = row['customer']?.toString();
        if (customer != null && customer.isNotEmpty) {
          customers[id] = customer;
        }
      }
    }
    return customers;
  }
}
