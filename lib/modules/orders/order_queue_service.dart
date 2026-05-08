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
/// must come from normalized plan rows first, then saved order queue JSON, then
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

typedef OrderQueueMapLoader = Future<Map<String, dynamic>?> Function(
  String orderId,
);
typedef OrderQueueRowsLoader = Future<List<Map<String, dynamic>>> Function(
  String orderId,
);

class OrderQueueLoadSources {
  const OrderQueueLoadSources({
    required this.loadOrderQueueColumns,
    required this.loadOrderData,
    required this.loadNormalizedRows,
    required this.loadLegacyProductionPlanRows,
    required this.loadTemplateFallbackRows,
  });

  final OrderQueueMapLoader loadOrderQueueColumns;
  final OrderQueueMapLoader loadOrderData;
  final OrderQueueRowsLoader loadNormalizedRows;
  final OrderQueueRowsLoader loadLegacyProductionPlanRows;
  final OrderQueueRowsLoader loadTemplateFallbackRows;
}

class OrderQueueService {
  OrderQueueService(SupabaseClient sb)
      : _sb = sb,
        _loadSources = null;

  @visibleForTesting
  OrderQueueService.withLoadSources(OrderQueueLoadSources loadSources)
      : _sb = null,
        _loadSources = loadSources;

  final SupabaseClient? _sb;
  final OrderQueueLoadSources? _loadSources;

  SupabaseClient get _client {
    final sb = _sb;
    if (sb == null) {
      throw StateError('SupabaseClient is not available in this test service.');
    }
    return sb;
  }

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

    // 1. Normalized plan rows are the shared source of truth for active/new
    // plans. Read them before legacy order JSON so screens and task providers
    // cannot display an older queue saved on the order row.
    final normalized = await _loadNormalizedRows(id);
    if (normalized.isNotEmpty) {
      return SavedOrderQueue(
        orderId: id,
        rows: normalized,
        source: SavedOrderQueueSource.normalizedPlanRows,
      );
    }

    // 2. Explicit saved queue columns on the order row (newer schemas).
    try {
      final order = await _loadOrderQueueColumns(id);
      if (order != null) {
        final rows = _firstDecodedRows(order, const [
          'stage_queue',
          'saved_stage_queue',
          'order_stage_queue',
        ]);
        if (rows.isNotEmpty) {
          return SavedOrderQueue(
            orderId: id,
            rows: rows,
            source: SavedOrderQueueSource.savedOrderQueue,
          );
        }
      }
    } catch (_) {}

    try {
      final data = await _loadOrderData(id) ?? const <String, dynamic>{};
      final rows = _firstDecodedRows(data, const [
        'stage_queue',
        'saved_stage_queue',
        'order_stage_queue',
      ]);
      if (rows.isNotEmpty) {
        return SavedOrderQueue(
          orderId: id,
          rows: rows,
          source: SavedOrderQueueSource.savedOrderQueue,
        );
      }
    } catch (_) {}

    // 3. Legacy JSON production_plans.stages.
    try {
      final rows = await _loadLegacyProductionPlanRows(id);
      if (rows.isNotEmpty) {
        return SavedOrderQueue(
          orderId: id,
          rows: rows,
          source: SavedOrderQueueSource.legacyProductionPlanStages,
        );
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
      await _updateOrderBuildMetadata(id, rows, selections, signature);
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

  Future<void> _updateOrderBuildMetadata(
    String orderId,
    List<Map<String, dynamic>> rows,
    Map<String, String?> selections,
    Map<String, dynamic>? signature,
  ) async {
    final basePayload = <String, dynamic>{
      'queue_build_status': QueueBuildStatus.built,
      'selected_v_stage': selections['selected_v_stage'],
      'selected_p_stage': selections['selected_p_stage'],
      'queue_signature': signature,
    };
    final attempts = <Map<String, dynamic>>[
      {
        ...basePayload,
        'stage_queue': rows,
        'saved_stage_queue': rows,
        'order_stage_queue': rows,
      },
      {...basePayload, 'stage_queue': rows},
      {...basePayload, 'saved_stage_queue': rows},
      {...basePayload, 'order_stage_queue': rows},
      basePayload,
    ];

    Object? lastError;
    for (final payload in attempts) {
      try {
        await _client.from('orders').update(payload).eq('id', orderId);
        return;
      } catch (error) {
        lastError = error;
        if (!_isMissingColumnError(error)) rethrow;
      }
    }
    if (lastError != null) throw lastError;
  }

  static bool _isMissingColumnError(Object error) {
    if (error is! PostgrestException) return false;
    final code = (error.code ?? '').trim();
    final message = error.message.toLowerCase();
    return code == '42703' ||
        code == 'PGRST204' ||
        message.contains('column') ||
        message.contains('schema cache');
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
    return OrderQueueSyncService(_client).sync(
      orderId: orderId,
      nextQueue: OrderQueueMapper.toSyncEntries(newQueue),
      completeBobbin: completeBobbin,
      bobbinStageId: bobbinStageId,
    );
  }

  /// Persists queue edits for an order that has already been launched.
  ///
  /// The normalized plan/task sync intentionally runs before legacy JSON and
  /// order metadata updates. That keeps already-started/completed stages
  /// protected by [OrderQueueSyncService.diff] and prevents the UI from saving
  /// a new queue signature when the normalized queue could not be reconciled.
  Future<SaveBuiltQueueResult> saveLaunchedOrderQueue(
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

    try {
      await syncQueueForExistingOrder(
        id,
        rows,
        completeBobbin: completeBobbin,
        bobbinStageId: bobbinStageId,
      );
    } on OrderQueueSyncBlockedException {
      rethrow;
    } catch (error) {
      final tableName = _syncFailureTableName(error);
      _debugPrintQueueSyncFailure(id, tableName, error);
      throw OrderQueueSaveException(
        kCreateProductionTasksFailedMessage,
        error,
      );
    }

    await _upsertLegacyProductionPlan(id, rows);
    await _updateOrderBuildMetadata(id, rows, selections, signature);

    return const SaveBuiltQueueResult(productionTasksCreated: true);
  }

  Future<void> createTasksFromSavedQueue(String orderId) async {
    final saved = await loadSavedQueue(orderId);
    if (saved.rows.isEmpty) {
      throw StateError('Не найдена сохранённая очередь этапов заказа.');
    }
    await OrderQueueSyncService(_client).sync(
      orderId: orderId,
      nextQueue: OrderQueueMapper.toSyncEntries(saved.rows),
    );
    await _restoreCompletedSavedStages(orderId, saved.rows);
  }

  Future<Map<String, dynamic>?> _loadOrderQueueColumns(String orderId) async {
    final loadSources = _loadSources;
    if (loadSources != null) {
      return loadSources.loadOrderQueueColumns(orderId);
    }
    final order = await _client
        .from('orders')
        .select('stage_queue, saved_stage_queue, order_stage_queue')
        .eq('id', orderId)
        .maybeSingle();
    return order != null ? Map<String, dynamic>.from(order) : null;
  }

  Future<Map<String, dynamic>?> _loadOrderData(String orderId) async {
    final loadSources = _loadSources;
    if (loadSources != null) {
      return loadSources.loadOrderData(orderId);
    }
    final order = await _client
        .from('orders')
        .select('data')
        .eq('id', orderId)
        .maybeSingle();
    return order != null && order['data'] is Map
        ? Map<String, dynamic>.from(order['data'] as Map)
        : null;
  }

  Future<List<Map<String, dynamic>>> _loadLegacyProductionPlanRows(
    String orderId,
  ) async {
    final loadSources = _loadSources;
    if (loadSources != null) {
      return loadSources.loadLegacyProductionPlanRows(orderId);
    }
    final plan = await _client
        .from('production_plans')
        .select('stages')
        .eq('order_id', orderId)
        .maybeSingle();
    return plan != null
        ? _decodeRows(plan['stages'])
        : const <Map<String, dynamic>>[];
  }

  Future<List<Map<String, dynamic>>> _loadNormalizedRows(String orderId) async {
    final loadSources = _loadSources;
    if (loadSources != null) {
      final rows = await loadSources.loadNormalizedRows(orderId);
      return _groupNormalizedPlanRows(rows);
    }
    try {
      final plan = await _client
          .from('prod_plans')
          .select('id')
          .eq('order_id', orderId)
          .maybeSingle();
      final planId = plan != null ? plan['id']?.toString() : null;
      if (planId == null || planId.isEmpty) {
        return const <Map<String, dynamic>>[];
      }
      return await _selectPlanStageRows(planId);
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  Future<List<Map<String, dynamic>>> _selectPlanStageRows(String planId) async {
    const attempts = <({String columns, String orderColumn})>[
      (
        columns: 'stage_id,stage_group_key,name,stage_name,step_no,seq,status,'
            'started_at,finished_at,completed_at,executor_id,'
            'assigned_employee_id',
        orderColumn: 'seq',
      ),
      (
        columns: 'stage_id,stage_group_key,name,stage_name,step_no,seq,status,'
            'started_at,finished_at,executor_id,assigned_employee_id',
        orderColumn: 'seq',
      ),
      (
        columns: 'stage_id,stage_group_key,name,stage_name,step_no,seq,status',
        orderColumn: 'seq',
      ),
      (
        columns: 'stage_id,stage_group_key,stage_name,step_no,seq,status',
        orderColumn: 'seq',
      ),
      (
        columns: 'stage_id,stage_group_key,name,step_no,seq,status',
        orderColumn: 'seq',
      ),
      (
        columns: 'stage_id,stage_group_key,stage_name,step_no,status',
        orderColumn: 'step_no',
      ),
      (
        columns: 'stage_id,stage_group_key,name,seq,status',
        orderColumn: 'seq',
      ),
    ];

    for (final attempt in attempts) {
      try {
        final rows = await _client
            .from('prod_plan_stages')
            .select(attempt.columns)
            .eq('plan_id', planId)
            .order(attempt.orderColumn, ascending: true);
        final decoded = _decodeRows(rows);
        if (decoded.isNotEmpty) return _groupNormalizedPlanRows(decoded);
      } catch (_) {}
    }
    return const <Map<String, dynamic>>[];
  }

  static List<Map<String, dynamic>> _groupNormalizedPlanRows(
    List<Map<String, dynamic>> rows,
  ) {
    if (rows.isEmpty) return const <Map<String, dynamic>>[];
    final grouped = <_NormalizedPlanGroup>[];
    final byKey = <String, _NormalizedPlanGroup>{};

    for (var i = 0; i < rows.length; i++) {
      final row = Map<String, dynamic>.from(rows[i]);
      final stageIds = OrderQueueMapper.stageIdsFromRow(row);
      if (stageIds.isEmpty) continue;
      final stageId = stageIds.first;
      final groupKey = OrderQueueMapper.stageGroupKeyFromRow(row, stageIds);
      final effectiveGroupKey = groupKey.isEmpty ? stageId : groupKey;
      final step = OrderQueueMapper.readStep(row, i + 1);
      final key = effectiveGroupKey;

      final group = byKey.putIfAbsent(key, () {
        final created = _NormalizedPlanGroup(
          key: key,
          firstRow: row,
          firstIndex: i,
          step: step,
        );
        grouped.add(created);
        return created;
      });
      group.addRow(row, stageId, step);
    }

    grouped.sort((a, b) {
      final byStep = a.step.compareTo(b.step);
      if (byStep != 0) return byStep;
      return a.firstIndex.compareTo(b.firstIndex);
    });

    return grouped.map((group) => group.toRow()).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _loadTemplateFallbackRows(
    String orderId,
  ) async {
    final loadSources = _loadSources;
    if (loadSources != null) {
      return loadSources.loadTemplateFallbackRows(orderId);
    }
    try {
      final order = await _client
          .from('orders')
          .select('stage_template_id')
          .eq('id', orderId)
          .maybeSingle();
      final templateId = order != null
          ? (order['stage_template_id'] ?? '').toString().trim()
          : '';
      if (templateId.isEmpty) return const <Map<String, dynamic>>[];
      final tpl = await _client
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
    final existing = await _client
        .from('production_plans')
        .select('id')
        .eq('order_id', orderId)
        .maybeSingle();
    if (existing != null && existing['id'] != null) {
      await _client
          .from('production_plans')
          .update({'stages': rows})
          .eq('id', existing['id']);
    } else {
      await _client.from('production_plans').insert({
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
      await _client.from('tasks').update({
        'status': 'done',
        'completed_at': DateTime.now().toIso8601String(),
      })
          .eq('order_id', orderId)
          .eq('stage_group_key', entry.stageGroupKey)
          .eq('stage_id', entry.stageId);
    }
  }

  static List<Map<String, dynamic>> _firstDecodedRows(
    Map<String, dynamic> source,
    List<String> keys,
  ) {
    for (final key in keys) {
      final rows = _decodeRows(source[key]);
      if (rows.isNotEmpty) return rows;
    }
    return const <Map<String, dynamic>>[];
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

class _NormalizedPlanGroup {
  _NormalizedPlanGroup({
    required this.key,
    required Map<String, dynamic> firstRow,
    required this.firstIndex,
    required this.step,
  }) : row = Map<String, dynamic>.from(firstRow);

  final String key;
  final Map<String, dynamic> row;
  final int firstIndex;
  int step;
  final List<String> stageIds = <String>[];

  void addRow(Map<String, dynamic> source, String stageId, int rowStep) {
    if (!stageIds.contains(stageId)) stageIds.add(stageId);
    if (rowStep > 0 && (step <= 0 || rowStep < step)) step = rowStep;

    final sourceStatus = source['status']?.toString().trim();
    final currentStatus = row['status']?.toString().trim();
    if (_statusRank(sourceStatus) > _statusRank(currentStatus)) {
      row['status'] = sourceStatus;
    }

    for (final key in const <String>[
      'started_at',
      'startedAt',
      'finished_at',
      'finishedAt',
      'completed_at',
      'completedAt',
      'executor_id',
      'assigned_employee_id',
    ]) {
      row[key] ??= source[key];
    }
  }

  Map<String, dynamic> toRow() {
    final result = Map<String, dynamic>.from(row);
    result['stage_group_key'] = key;
    result['stageGroupKey'] = key;
    result['stageId'] =
        stageIds.isNotEmpty ? stageIds.first : result['stageId'];
    result['stage_id'] =
        stageIds.isNotEmpty ? stageIds.first : result['stage_id'];
    result['workplaceId'] = result['stageId'];
    result['workplaceIds'] = List<String>.from(stageIds);
    if (stageIds.length > 1) {
      result['alternativeStageIds'] = stageIds.skip(1).toList(growable: false);
    }
    result['step'] = step;
    result['step_no'] = step;
    result['seq'] = step;
    result['order'] = step;
    return result;
  }

  static int _statusRank(String? status) {
    switch ((status ?? '').toLowerCase().replaceAll('-', '_')) {
      case 'completed':
      case 'complete':
      case 'done':
        return 5;
      case 'inprogress':
      case 'in_progress':
      case 'started':
        return 4;
      case 'paused':
      case 'problem':
        return 3;
      case 'available':
      case 'ready':
        return 2;
      case 'waiting':
      case 'pending':
      default:
        return 1;
    }
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
    var lastGroupStep = 0;
    String? currentGroupKey;
    var currentGroupStep = 0;

    for (final entry in entries) {
      final isSameGroup = entry.stageGroupKey == currentGroupKey;
      final requestedStep = entry.step > 0 ? entry.step : lastGroupStep + 1;
      final effectiveStep = isSameGroup
          ? currentGroupStep
          : (requestedStep <= lastGroupStep
              ? lastGroupStep + 1
              : requestedStep);

      normalized.add(
        effectiveStep == entry.step
            ? entry
            : entry.copyWith(step: effectiveStep),
      );

      if (!isSameGroup) {
        currentGroupKey = entry.stageGroupKey;
        currentGroupStep = effectiveStep;
        lastGroupStep = effectiveStep;
      }
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

    final isSwitchable = row['isSwitchable'] == true ||
        row['is_switchable'] == true ||
        row['isSwitchable']?.toString().toLowerCase().trim() == 'true' ||
        row['is_switchable']?.toString().toLowerCase().trim() == 'true';
    if (isSwitchable) {
      add(row['selectedWorkplaceId'] ??
          row['selected_workplace_id'] ??
          row['stageId'] ??
          row['stage_id'] ??
          row['stageid'] ??
          row['workplaceId'] ??
          row['workplace_id'] ??
          row['id']);
      return result;
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
