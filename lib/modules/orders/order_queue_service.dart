import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'order_model.dart';
import 'order_queue_sync_service.dart';
import 'stage_queue_builder.dart';

export 'order_queue_sync_service.dart'
    show OrderQueueSyncBlockedException, OrderQueueSyncSchemaOutdatedException;

const String kCreateProductionTasksFailedMessage =
    'Не удалось создать производственные задания';

/// Source priority for a persisted order queue.
///
/// `stageTemplateId` is intentionally not an order queue source of truth. It is
/// kept on the order only as an editing hint/legacy reference; the factual queue
/// must come from the saved order queue first, then normalized plan rows, then
/// legacy `production_plans.stages`, and only then from the template as a
/// fallback for old orders that were never saved with an explicit queue.
enum SavedOrderQueueSource {
  savedOrderQueue,
  normalizedPlanRows,
  legacyProductionPlanStages,
  templateFallback,
  none,
}

class SavedOrderQueue {
  const SavedOrderQueue({
    required this.orderId,
    required this.rows,
    required this.source,
  });

  final String orderId;
  final List<Map<String, dynamic>> rows;
  final SavedOrderQueueSource source;

  bool get isEmpty => rows.isEmpty;
  bool get isNotEmpty => rows.isNotEmpty;
}

class SaveBuiltQueueResult {
  const SaveBuiltQueueResult({
    required this.productionTasksCreated,
    this.legacySchemaFallback = false,
  });

  final bool productionTasksCreated;
  final bool legacySchemaFallback;
}

class OrderQueueSaveException implements Exception {
  const OrderQueueSaveException([
    this.message = kCreateProductionTasksFailedMessage,
    this.cause,
  ]);

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

class OrderQueueService {
  OrderQueueService(this._sb);

  final SupabaseClient _sb;

  List<Map<String, dynamic>> buildPreviewQueue(
    OrderStageQueueDraft draft, {
    List<Map<String, dynamic>> existingStages = const <Map<String, dynamic>>[],
    List<Map<String, dynamic>> templateStages = const <Map<String, dynamic>>[],
  }) {
    return buildOrderStageQueue(
      productTypeId: draft.productTypeId,
      hasCutting: draft.hasTrimming,
      hasCardboard: draft.hasCardboard,
      hasFlexPrinting: draft.hasPaint,
      handleType: draft.handleType,
      requiresBobbinCutting: draft.requiresBobbinCutting,
      orderWidthB: draft.orderWidthB,
      materialWidth: draft.materialWidth,
      switchableStageKey: draft.switchableStageKey,
      selectedSwitchableStageId: draft.selectedSwitchableStageId,
      selectedSwitchableStageIdsByStageKey:
          draft.selectedSwitchableStageIdsByStageKey,
      existingStages: existingStages,
      templateStages: templateStages,
    );
  }

  Future<SavedOrderQueue> loadSavedQueue(String orderId) async {
    final id = orderId.trim();
    if (id.isEmpty) {
      return const SavedOrderQueue(
        orderId: '',
        rows: <Map<String, dynamic>>[],
        source: SavedOrderQueueSource.none,
      );
    }

    // 1. Explicit saved queue columns on the order row (newer schemas).
    try {
      final order = await _sb
          .from('orders')
          .select('stage_queue, saved_stage_queue, order_stage_queue')
          .eq('id', id)
          .maybeSingle();
      if (order != null) {
        for (final key in const [
          'stage_queue',
          'saved_stage_queue',
          'order_stage_queue',
        ]) {
          final rows = _decodeRows(order[key]);
          if (rows.isNotEmpty) {
            return SavedOrderQueue(
              orderId: id,
              rows: rows,
              source: SavedOrderQueueSource.savedOrderQueue,
            );
          }
        }
      }
    } catch (_) {}

    try {
      final order =
          await _sb.from('orders').select('data').eq('id', id).maybeSingle();
      final data = order != null && order['data'] is Map
          ? Map<String, dynamic>.from(order['data'] as Map)
          : const <String, dynamic>{};
      for (final key in const [
        'stage_queue',
        'saved_stage_queue',
        'order_stage_queue',
      ]) {
        final rows = _decodeRows(data[key]);
        if (rows.isNotEmpty) {
          return SavedOrderQueue(
            orderId: id,
            rows: rows,
            source: SavedOrderQueueSource.savedOrderQueue,
          );
        }
      }
    } catch (_) {}

    // 2. Normalized plan rows are the preferred shared storage for active plans.
    final normalized = await _loadNormalizedRows(id);
    if (normalized.isNotEmpty) {
      return SavedOrderQueue(
        orderId: id,
        rows: normalized,
        source: SavedOrderQueueSource.normalizedPlanRows,
      );
    }

    // 3. Legacy JSON production_plans.stages.
    try {
      final plan = await _sb
          .from('production_plans')
          .select('stages')
          .eq('order_id', id)
          .maybeSingle();
      if (plan != null) {
        final rows = _decodeRows(plan['stages']);
        if (rows.isNotEmpty) {
          return SavedOrderQueue(
            orderId: id,
            rows: rows,
            source: SavedOrderQueueSource.legacyProductionPlanStages,
          );
        }
      }
    } catch (_) {}

    // 4. Template is only a compatibility fallback for old data.
    final templateRows = await _loadTemplateFallbackRows(id);
    if (templateRows.isNotEmpty) {
      return SavedOrderQueue(
        orderId: id,
        rows: templateRows,
        source: SavedOrderQueueSource.templateFallback,
      );
    }

    return SavedOrderQueue(
      orderId: id,
      rows: const <Map<String, dynamic>>[],
      source: SavedOrderQueueSource.none,
    );
  }

  Future<SaveBuiltQueueResult> saveBuiltQueue(
    String orderId,
    List<Map<String, dynamic>> queue,
    Map<String, String?> selections,
    Map<String, dynamic>? signature, {
    bool completeBobbin = false,
    String? bobbinStageId,
  }) async {
    final id = orderId.trim();
    if (id.isEmpty) {
      return const SaveBuiltQueueResult(productionTasksCreated: false);
    }
    final rows = queue.map((row) => Map<String, dynamic>.from(row)).toList();

    await _upsertLegacyProductionPlan(id, rows);

    try {
      await _sb.from('orders').update({
        'queue_build_status': QueueBuildStatus.built,
        'selected_v_stage': selections['selected_v_stage'],
        'selected_p_stage': selections['selected_p_stage'],
        'queue_signature': signature,
      }).eq('id', id);
    } catch (error) {
      _debugPrintQueueSyncFailure(id, 'orders', error);
    }

    try {
      await syncQueueForExistingOrder(
        id,
        rows,
        completeBobbin: completeBobbin,
        bobbinStageId: bobbinStageId,
      );
      return const SaveBuiltQueueResult(productionTasksCreated: true);
    } on OrderQueueSyncBlockedException {
      rethrow;
    } catch (error) {
      final tableName = _syncFailureTableName(error);
      _debugPrintQueueSyncFailure(id, tableName, error);
      if (_isLegacyNormalizedQueueSchemaError(error)) {
        // Older deployments may not have normalized plan tables yet; the
        // legacy saved queue above remains available for loadSavedQueue().
        return const SaveBuiltQueueResult(
          productionTasksCreated: false,
          legacySchemaFallback: true,
        );
      }
      throw OrderQueueSaveException(
        kCreateProductionTasksFailedMessage,
        error,
      );
    }
  }

  static bool _isLegacyNormalizedQueueSchemaError(Object error) {
    if (error is! PostgrestException) return false;
    final code = (error.code ?? '').trim();
    final message = error.message.toLowerCase();
    final mentionsNormalizedPlanTable =
        message.contains('prod_plans') || message.contains('prod_plan_stages');
    if (!mentionsNormalizedPlanTable) return false;
    return code == '42P01' ||
        code == '42703' ||
        code == 'PGRST204' ||
        code == 'PGRST205';
  }

  static String _syncFailureTableName(Object error) {
    if (error is PostgrestException) {
      final message = error.message.toLowerCase();
      for (final table in const <String>[
        'prod_plan_stages',
        'prod_plans',
        'tasks',
        'orders',
        'production_plans',
      ]) {
        if (message.contains(table)) return table;
      }
    }
    return 'prod_plan_stages/tasks';
  }

  static void _debugPrintQueueSyncFailure(
    String orderId,
    String tableName,
    Object error,
  ) {
    debugPrint(
      'OrderQueueService.saveBuiltQueue failed: orderId=$orderId '
      'table=$tableName error=$error',
    );
  }

  Future<List<OrderQueueSyncOperation>> syncQueueForExistingOrder(
    String orderId,
    List<Map<String, dynamic>> newQueue, {
    bool completeBobbin = false,
    String? bobbinStageId,
  }) {
    return OrderQueueSyncService(_sb).sync(
      orderId: orderId,
      nextQueue: OrderQueueMapper.toSyncEntries(newQueue),
      completeBobbin: completeBobbin,
      bobbinStageId: bobbinStageId,
    );
  }

  Future<void> createTasksFromSavedQueue(String orderId) async {
    final saved = await loadSavedQueue(orderId);
    if (saved.rows.isEmpty) {
      throw StateError('Не найдена сохранённая очередь этапов заказа.');
    }
    await OrderQueueSyncService(_sb).sync(
      orderId: orderId,
      nextQueue: OrderQueueMapper.toSyncEntries(saved.rows),
    );
    await _restoreCompletedSavedStages(orderId, saved.rows);
  }

  Future<List<Map<String, dynamic>>> _loadNormalizedRows(String orderId) async {
    try {
      final plan = await _sb
          .from('prod_plans')
          .select('id')
          .eq('order_id', orderId)
          .maybeSingle();
      final planId = plan != null ? plan['id']?.toString() : null;
      if (planId == null || planId.isEmpty) {
        return const <Map<String, dynamic>>[];
      }
      final rows = await _sb
          .from('prod_plan_stages')
          .select('*')
          .eq('plan_id', planId)
          .order('seq', ascending: true);
      return _decodeRows(rows);
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  Future<List<Map<String, dynamic>>> _loadTemplateFallbackRows(
    String orderId,
  ) async {
    try {
      final order = await _sb
          .from('orders')
          .select('stage_template_id')
          .eq('id', orderId)
          .maybeSingle();
      final templateId = order != null
          ? (order['stage_template_id'] ?? '').toString().trim()
          : '';
      if (templateId.isEmpty) return const <Map<String, dynamic>>[];
      final tpl = await _sb
          .from('plan_templates')
          .select('stages')
          .eq('id', templateId)
          .maybeSingle();
      return tpl != null
          ? _decodeRows(tpl['stages'])
          : const <Map<String, dynamic>>[];
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  Future<void> _upsertLegacyProductionPlan(
    String orderId,
    List<Map<String, dynamic>> rows,
  ) async {
    final existing = await _sb
        .from('production_plans')
        .select('id')
        .eq('order_id', orderId)
        .maybeSingle();
    if (existing != null && existing['id'] != null) {
      await _sb
          .from('production_plans')
          .update({'stages': rows})
          .eq('id', existing['id']);
    } else {
      await _sb.from('production_plans').insert({
        'order_id': orderId,
        'stages': rows,
      });
    }
  }

  Future<void> _restoreCompletedSavedStages(
    String orderId,
    List<Map<String, dynamic>> rows,
  ) async {
    for (final entry in OrderQueueMapper.toSyncEntries(rows)) {
      final status = entry.status.toLowerCase().trim();
      if (status != 'done' && status != 'completed') continue;
      await _sb.from('tasks').update({
        'status': 'done',
        'completed_at': DateTime.now().toIso8601String(),
      })
          .eq('order_id', orderId)
          .eq('stage_group_key', entry.stageGroupKey)
          .eq('stage_id', entry.stageId);
    }
  }

  static List<Map<String, dynamic>> _decodeRows(dynamic rows) {
    if (rows is List) {
      return rows
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
    }
    if (rows is Map) {
      final entries = rows.entries.toList()
        ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
      return entries
          .where((entry) => entry.value is Map)
          .map((entry) => Map<String, dynamic>.from(entry.value as Map))
          .toList(growable: false);
    }
    return const <Map<String, dynamic>>[];
  }
}

class OrderQueueMapper {
  const OrderQueueMapper._();

  static List<OrderQueueSyncEntry> toSyncEntries(
    List<Map<String, dynamic>> rows,
  ) {
    final result = <OrderQueueSyncEntry>[];
    final createdKeys = <String>{};
    var fallbackStep = 1;
    String? previousGroupKey;

    for (final row in rows) {
      final stageIds = stageIdsFromRow(row);
      if (stageIds.isEmpty) continue;
      final groupKey = stageGroupKeyFromRow(row, stageIds);
      if (groupKey.isNotEmpty && groupKey == previousGroupKey) {
        continue;
      }
      previousGroupKey = groupKey;
      final step = readStep(row, fallbackStep);
      final status = (row['status'] ?? 'waiting').toString();

      for (final stageId in stageIds) {
        final effectiveGroupKey = groupKey.isEmpty ? stageId : groupKey;
        final key = '$effectiveGroupKey::$stageId';
        if (!createdKeys.add(key)) continue;
        result.add(OrderQueueSyncEntry(
          stageId: stageId,
          stageGroupKey: effectiveGroupKey,
          step: step,
          status: status,
          row: row,
        ));
      }
      fallbackStep += 1;
    }

    return _withUniqueSteps(result);
  }

  static List<OrderQueueSyncEntry> _withUniqueSteps(
    List<OrderQueueSyncEntry> entries,
  ) {
    final normalized = <OrderQueueSyncEntry>[];
    var lastStep = 0;
    for (final entry in entries) {
      final requestedStep = entry.step > 0 ? entry.step : lastStep + 1;
      final uniqueStep =
          requestedStep <= lastStep ? lastStep + 1 : requestedStep;
      normalized.add(
        uniqueStep == entry.step ? entry : entry.copyWith(step: uniqueStep),
      );
      lastStep = uniqueStep;
    }
    return normalized;
  }

  static List<String> stageIdsFromRow(Map<String, dynamic> row) {
    final result = <String>[];

    void add(dynamic value) {
      final id = value?.toString().trim() ?? '';
      if (id.isEmpty || result.contains(id)) return;
      result.add(id);
    }

    void addAll(dynamic value) {
      if (value is List) {
        for (final item in value) {
          add(item);
        }
      } else if (value is String) {
        for (final token in value.split(',')) {
          add(token);
        }
      }
    }

    addAll(row['workplaceIds'] ?? row['workplace_ids']);
    if (result.isEmpty) {
      add(row['selectedWorkplaceId'] ??
          row['stageId'] ??
          row['stage_id'] ??
          row['stageid'] ??
          row['workplaceId'] ??
          row['workplace_id'] ??
          row['id']);
    }
    addAll(row['alternativeStageIds'] ??
        row['alternative_stage_ids'] ??
        row['stageIds'] ??
        row['stage_ids'] ??
        row['allStageIds'] ??
        row['all_stage_ids']);

    return result;
  }

  static String stageGroupKeyFromRow(
    Map<String, dynamic> row,
    List<String> stageIds,
  ) {
    final explicit = (row['stage_group_key'] ??
            row['stageGroupKey'] ??
            row['queue_stage_key'] ??
            row['queueStageKey'] ??
            row['stageKey'] ??
            row['stage_key'] ??
            row['group_key'])
        ?.toString()
        .trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final canonical = List<String>.from(stageIds)..sort();
    return canonical.join('|');
  }

  static int readStep(Map<String, dynamic> row, int fallback) {
    final raw = row['step'] ??
        row['step_no'] ??
        row['stepNo'] ??
        row['seq'] ??
        row['order'] ??
        row['position'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '') ?? fallback;
  }
}
