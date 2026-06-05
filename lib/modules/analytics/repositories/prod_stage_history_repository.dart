import 'package:supabase_flutter/supabase_flutter.dart';

import '../../personnel/workplace_model.dart';
import '../models/analytics_event.dart';
import '../models/analytics_month.dart';

/// Derives [AnalyticsEvent]s from [prod_stage_history] status transitions.
///
/// Used as a fallback for months that pre-date the task-comment tracking
/// system (time_event / quantity_done comments). For each stage that
/// transitioned waiting→inProgress→completed in the requested month, one
/// work event is emitted with:
///   • startTime  = the inProgress transition timestamp
///   • endTime    = the completed transition timestamp
///   • employeeId = changed_by on the inProgress transition
///   • workplaceId = best-match of the prod_plan_stage name against workplaces
class ProdStageHistoryRepository {
  ProdStageHistoryRepository({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Future<List<AnalyticsEvent>> loadEventsForMonth(
    AnalyticsMonth month,
    List<WorkplaceModel> workplaces,
  ) async {
    final monthStart = month.firstDay.toUtc();
    final monthEnd = month.nextMonthFirstDay.toUtc();

    // ── 1. Stage history rows in the requested month ─────────────────────
    final dynamic historyRaw = await _client
        .from('prod_stage_history')
        .select('id, stage_id, old_status, new_status, changed_at, changed_by')
        .gte('changed_at', monthStart.toIso8601String())
        .lt('changed_at', monthEnd.toIso8601String());

    if (historyRaw is! List || historyRaw.isEmpty) return const [];

    final historyRows =
        historyRaw.whereType<Map>().map(Map<String, dynamic>.from).toList();

    final stageIds = historyRows
        .map((r) => (r['stage_id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();

    if (stageIds.isEmpty) return const [];

    // ── 2. Resolve stage names and plan IDs ──────────────────────────────
    final dynamic planStageRaw = await _client
        .from('prod_plan_stages')
        .select('id, name, plan_id')
        .inFilter('id', stageIds);

    final stageInfo = <String, _StageInfo>{};
    final planIds = <String>[];
    if (planStageRaw is List) {
      for (final row in planStageRaw) {
        if (row is! Map) continue;
        final id = (row['id'] ?? '').toString();
        final name = (row['name'] ?? '').toString();
        final planId = (row['plan_id'] ?? '').toString();
        stageInfo[id] = _StageInfo(name: name, planId: planId);
        if (planId.isNotEmpty) planIds.add(planId);
      }
    }

    // ── 3. Resolve order IDs ─────────────────────────────────────────────
    final orderByPlanId = <String, String>{};
    if (planIds.isNotEmpty) {
      final dynamic planRaw = await _client
          .from('production_plans')
          .select('id, order_id')
          .inFilter('id', planIds.toSet().toList());
      if (planRaw is List) {
        for (final row in planRaw) {
          if (row is! Map) continue;
          orderByPlanId[(row['id'] ?? '').toString()] =
              (row['order_id'] ?? '').toString();
        }
      }
    }

    // ── 4. Build workplace name → ID lookup ──────────────────────────────
    final wpByName = <String, String>{};
    for (final wp in workplaces) {
      wpByName[_norm(wp.name)] = wp.id;
    }

    // ── 5. Group history rows by stage_id and emit work intervals ────────
    final byStage = <String, List<Map<String, dynamic>>>{};
    for (final row in historyRows) {
      byStage
          .putIfAbsent((row['stage_id'] ?? '').toString(), () => [])
          .add(row);
    }

    final events = <AnalyticsEvent>[];

    byStage.forEach((stageId, rows) {
      rows.sort((a, b) {
        final at = _parseTs(a['changed_at']) ?? DateTime.utc(1970);
        final bt = _parseTs(b['changed_at']) ?? DateTime.utc(1970);
        return at.compareTo(bt);
      });

      DateTime? startTime;
      String? employeeId;

      for (final row in rows) {
        final oldStatus = (row['old_status'] ?? '').toString();
        final newStatus = (row['new_status'] ?? '').toString();
        final changedAt = _parseTs(row['changed_at']);
        final changedBy = (row['changed_by'] ?? '').toString();

        if (newStatus == 'inProgress') {
          startTime = changedAt;
          employeeId = changedBy.isEmpty ? null : changedBy;
        } else if (newStatus == 'completed' &&
            oldStatus == 'inProgress' &&
            startTime != null &&
            changedAt != null) {
          final info = stageInfo[stageId];
          final stageName = _norm(info?.name ?? '');
          final planId = info?.planId ?? '';
          final orderId = orderByPlanId[planId] ?? '';

          // Fuzzy-match stage name to a workplace.
          String workplaceId = '';
          for (final entry in wpByName.entries) {
            if (stageName.isNotEmpty &&
                (stageName.contains(entry.key) ||
                    entry.key.contains(stageName))) {
              workplaceId = entry.value;
              break;
            }
          }

          events.add(AnalyticsEvent(
            id: 'hist_${row['id']}',
            type: AnalyticsEventType.work,
            startTime: startTime!.toLocal(),
            endTime: changedAt.toLocal(),
            employeeId: employeeId ?? '',
            workplaceId: workplaceId,
            taskId: stageId,
            orderId: orderId,
            qty: 0,
            setupQty: 0,
            isActive: false,
          ));

          startTime = null;
          employeeId = null;
        }
      }
    });

    return events;
  }

  static String _norm(String s) => s.toLowerCase().trim();

  static DateTime? _parseTs(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v.toUtc();
    return DateTime.tryParse(v.toString())?.toUtc();
  }
}

class _StageInfo {
  const _StageInfo({required this.name, required this.planId});
  final String name;
  final String planId;
}
