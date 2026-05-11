import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const String kStartedStageQueueChangeMessage =
    'Нельзя изменить уже начатый или завершённый этап.';

const String kOutdatedProdPlanStageIdSchemaMessage =
    'Схема базы данных устарела: отсутствует prod_plan_stages.stage_id. Примените миграции Supabase';

enum OrderQueueSyncOperationType {
  keep,
  insert,
  updatePending,
  cancelOrDeletePending,
  block,
}

class OrderQueueSyncOperation {
  const OrderQueueSyncOperation({
    required this.type,
    this.current,
    this.next,
    this.reason,
  });

  final OrderQueueSyncEntry? current;
  final OrderQueueSyncEntry? next;
  final OrderQueueSyncOperationType type;
  final String? reason;
}

class OrderQueueSyncBlockedException implements Exception {
  const OrderQueueSyncBlockedException([
    this.message = kStartedStageQueueChangeMessage,
  ]);

  final String message;

  @override
  String toString() => message;
}

class OrderQueueSyncSchemaOutdatedException implements Exception {
  const OrderQueueSyncSchemaOutdatedException([
    this.message = kOutdatedProdPlanStageIdSchemaMessage,
  ]);

  final String message;

  @override
  String toString() => message;
}

class OrderQueueSyncEntry {
  const OrderQueueSyncEntry({
    this.id,
    this.physicalSeq,
    required this.stageId,
    required this.stageGroupKey,
    required this.step,
    this.status = 'waiting',
    this.row = const <String, dynamic>{},
  });

  final String? id;
  final int? physicalSeq;
  final String stageId;
  final String stageGroupKey;
  final int step;
  final String status;
  final Map<String, dynamic> row;

  String get identityKey => '$stageGroupKey::$stageId';

  String get displayName {
    for (final key in const [
      'name',
      'stageName',
      'stage_name',
      'workplaceName',
      'workplace_name',
      'title',
    ]) {
      final value = row[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return stageId;
  }

  bool sameQueueSlot(OrderQueueSyncEntry other) =>
      stageId == other.stageId &&
      stageGroupKey == other.stageGroupKey &&
      step == other.step;

  OrderQueueSyncEntry copyWith({
    String? id,
    int? physicalSeq,
    String? stageId,
    String? stageGroupKey,
    int? step,
    String? status,
    Map<String, dynamic>? row,
  }) {
    return OrderQueueSyncEntry(
      id: id ?? this.id,
      physicalSeq: physicalSeq ?? this.physicalSeq,
      stageId: stageId ?? this.stageId,
      stageGroupKey: stageGroupKey ?? this.stageGroupKey,
      step: step ?? this.step,
      status: status ?? this.status,
      row: row ?? this.row,
    );
  }
}

class OrderQueueSyncService {
  OrderQueueSyncService(this._sb);

  final SupabaseClient _sb;

  static const Set<String> protectedStatuses = <String>{
    'completed',
    'complete',
    'done',
    'in_progress',
    'inprogress',
    'started',
    'paused',
    'problem',
  };

  static const Set<String> pendingStatuses = <String>{
    '',
    'pending',
    'waiting',
    'planned',
    'todo',
    'new',
  };

  static bool isProtectedStatus(dynamic status) {
    final normalized = _normalizeStatus(status);
    return protectedStatuses.contains(normalized);
  }

  static bool isPendingStatus(dynamic status) {
    final normalized = _normalizeStatus(status);
    return pendingStatuses.contains(normalized);
  }

  static String _normalizeStatus(dynamic status) =>
      (status?.toString() ?? '').trim().toLowerCase().replaceAll('-', '_');

  static String protectedStageChangeMessage(OrderQueueSyncEntry entry) {
    final status = entry.status.trim();
    final statusSuffix = status.isEmpty ? '' : ' (статус: $status)';
    return 'Нельзя изменить уже начатый или завершённый этап '
        '«${entry.displayName}»$statusSuffix. Измените только ожидающие этапы.';
  }

  static List<OrderQueueSyncOperation> diff({
    required List<OrderQueueSyncEntry> currentStages,
    required List<OrderQueueSyncEntry> currentTasks,
    required List<OrderQueueSyncEntry> nextQueue,
  }) {
    final operations = <OrderQueueSyncOperation>[];
    final nextByKey = <String, OrderQueueSyncEntry>{
      for (final entry in nextQueue) entry.identityKey: entry,
    };
    final currentByKey = <String, OrderQueueSyncEntry>{
      for (final entry in currentStages) entry.identityKey: entry,
    };

    for (final current in currentStages) {
      final next = nextByKey[current.identityKey];
      if (next == null) {
        if (isProtectedStatus(current.status)) {
          operations.add(OrderQueueSyncOperation(
            type: OrderQueueSyncOperationType.block,
            current: current,
            reason: protectedStageChangeMessage(current),
          ));
        } else {
          operations.add(OrderQueueSyncOperation(
            type: OrderQueueSyncOperationType.cancelOrDeletePending,
            current: current,
          ));
        }
        continue;
      }

      if (current.sameQueueSlot(next)) {
        operations.add(OrderQueueSyncOperation(
          type: OrderQueueSyncOperationType.keep,
          current: current,
          next: next,
        ));
      } else if (isProtectedStatus(current.status)) {
        operations.add(OrderQueueSyncOperation(
          type: OrderQueueSyncOperationType.block,
          current: current,
          next: next,
          reason: protectedStageChangeMessage(current),
        ));
      } else {
        operations.add(OrderQueueSyncOperation(
          type: OrderQueueSyncOperationType.updatePending,
          current: current,
          next: next,
        ));
      }
    }

    bool hasEquivalentNextStage(OrderQueueSyncEntry current) {
      return nextQueue.any(
        (next) =>
            current.sameQueueSlot(next) ||
            (current.stageId == next.stageId && current.step == next.step),
      );
    }

    bool hasProtectedPlanStageKeptForTask(OrderQueueSyncEntry task) {
      return currentStages.any(
        (stage) =>
            isProtectedStatus(stage.status) &&
            stage.stageId == task.stageId &&
            hasEquivalentNextStage(stage),
      );
    }

    for (final task in currentTasks) {
      final next = nextByKey[task.identityKey];
      if (next != null && task.sameQueueSlot(next)) continue;
      if (isProtectedStatus(task.status)) {
        if (hasProtectedPlanStageKeptForTask(task)) continue;
        operations.add(OrderQueueSyncOperation(
          type: OrderQueueSyncOperationType.block,
          current: task,
          next: next,
          reason: protectedStageChangeMessage(task),
        ));
      } else if (next == null) {
        operations.add(OrderQueueSyncOperation(
          type: OrderQueueSyncOperationType.cancelOrDeletePending,
          current: task,
        ));
      }
    }

    for (final next in nextQueue) {
      if (currentByKey.containsKey(next.identityKey)) continue;
      operations.add(OrderQueueSyncOperation(
        type: OrderQueueSyncOperationType.insert,
        next: next,
      ));
    }

    return operations;
  }

  Future<List<OrderQueueSyncOperation>> sync({
    required String orderId,
    required List<OrderQueueSyncEntry> nextQueue,
    bool completeBobbin = false,
    String? bobbinStageId,
  }) async {
    final planId = await _runTableStep(
      orderId: orderId,
      tableName: 'prod_plans',
      action: () => _ensurePlan(orderId),
    );
    final loadedStages = await _runTableStep(
      orderId: orderId,
      tableName: 'prod_plan_stages',
      action: () => _loadPlanStages(planId),
    );
    final currentStages = await _runTableStep(
      orderId: orderId,
      tableName: 'prod_plan_stages',
      action: () => _deleteDuplicatePendingPlanStages(loadedStages),
    );
    final currentTasks = await _runTableStep(
      orderId: orderId,
      tableName: 'tasks',
      action: () => _loadTasks(orderId),
    );
    final operations = diff(
      currentStages: currentStages,
      currentTasks: currentTasks,
      nextQueue: nextQueue,
    );

    final blocked = operations.where(
      (op) => op.type == OrderQueueSyncOperationType.block,
    );
    if (blocked.isNotEmpty) {
      throw OrderQueueSyncBlockedException(
        blocked.first.reason ?? kStartedStageQueueChangeMessage,
      );
    }

    for (final op in operations.where(
      (op) => op.type == OrderQueueSyncOperationType.cancelOrDeletePending,
    )) {
      final current = op.current;
      if (current == null) continue;
      await _runTableStep<void>(
        orderId: orderId,
        tableName: 'prod_plan_stages',
        action: () => _deletePendingPlanStage(current),
      );
      await _runTableStep<void>(
        orderId: orderId,
        tableName: 'tasks',
        action: () => _deletePendingTasks(orderId, current),
      );
    }

    final updateOperations = operations
        .where((op) => op.type == OrderQueueSyncOperationType.updatePending)
        .toList(growable: false);
    final parkedUpdates = await _runTableStep<Map<String, OrderQueueSyncEntry>>(
      orderId: orderId,
      tableName: 'prod_plan_stages',
      action: () => _parkPendingPlanStageUpdates(updateOperations),
    );

    final physicalSeqByKey = physicalSeqByIdentityKey(nextQueue);

    for (final op in updateOperations) {
      final current = op.current;
      final next = op.next;
      if (current == null || next == null) continue;
      final parkedCurrent = parkedUpdates[current.identityKey] ?? current;
      await _runTableStep<void>(
        orderId: orderId,
        tableName: 'prod_plan_stages',
        action: () => _updatePendingPlanStage(
          parkedCurrent,
          next,
          physicalSeqByKey[next.identityKey] ?? next.step,
        ),
      );
      await _runTableStep<void>(
        orderId: orderId,
        tableName: 'tasks',
        action: () => _syncPendingTaskGroup(orderId, current, next),
      );
    }

    for (final op in operations.where(
      (op) => op.type == OrderQueueSyncOperationType.insert,
    )) {
      final next = op.next;
      if (next == null) continue;
      await _runTableStep<void>(
        orderId: orderId,
        tableName: 'prod_plan_stages',
        action: () => _insertPlanStage(
          planId,
          next,
          physicalSeqByKey[next.identityKey] ?? next.step,
        ),
      );
    }

    await _runTableStep<void>(
      orderId: orderId,
      tableName: 'tasks',
      action: () => _createMissingTasks(orderId, nextQueue),
    );

    if (completeBobbin &&
        bobbinStageId != null &&
        bobbinStageId.trim().isNotEmpty) {
      await _runTableStep<void>(
        orderId: orderId,
        tableName: 'prod_plan_stages/tasks',
        action: () => _markBobbinDone(planId, orderId, bobbinStageId.trim()),
      );
    }

    return operations;
  }

  Future<T> _runTableStep<T>({
    required String orderId,
    required String tableName,
    required Future<T> Function() action,
  }) async {
    try {
      return await action();
    } catch (error) {
      debugPrint(
        'OrderQueueSyncService.sync failed: orderId=$orderId '
        'table=$tableName error=$error',
      );
      rethrow;
    }
  }

  Future<String> _ensurePlan(String orderId) async {
    final planRow = await _sb
        .from('prod_plans')
        .select('id')
        .eq('order_id', orderId)
        .maybeSingle();
    if (planRow != null && planRow['id'] != null) {
      return planRow['id'].toString();
    }
    final inserted = await _sb
        .from('prod_plans')
        .insert({'order_id': orderId})
        .select('id')
        .single();
    return inserted['id'].toString();
  }

  Future<List<OrderQueueSyncEntry>> _loadPlanStages(String planId) async {
    final rows = await _sb
        .from('prod_plan_stages')
        .select('*')
        .eq('plan_id', planId)
        .order('seq', ascending: true);
    if (rows is! List) return const <OrderQueueSyncEntry>[];
    return rows
        .whereType<Map>()
        .map((row) => _entryFromPlanRow(Map<String, dynamic>.from(row)))
        .whereType<OrderQueueSyncEntry>()
        .toList(growable: false);
  }

  Future<List<OrderQueueSyncEntry>> _loadTasks(String orderId) async {
    final rows = await _sb
        .from('tasks')
        .select('*')
        .eq('order_id', orderId);
    if (rows is! List) return const <OrderQueueSyncEntry>[];
    return rows
        .whereType<Map>()
        .map((row) => _entryFromTaskRow(Map<String, dynamic>.from(row)))
        .whereType<OrderQueueSyncEntry>()
        .toList(growable: false);
  }

  OrderQueueSyncEntry? _entryFromPlanRow(Map<String, dynamic> row) {
    final stageId = (row['stage_id'] ?? row['stageId'])?.toString().trim();
    if (stageId == null || stageId.isEmpty) return null;
    final groupKey = (row['stage_group_key'] ?? row['stageGroupKey'])
            ?.toString()
            .trim() ??
        stageId;
    return OrderQueueSyncEntry(
      id: row['id']?.toString(),
      stageId: stageId,
      stageGroupKey: groupKey.isEmpty ? stageId : groupKey,
      step: _readInt(row['step_no'] ?? row['step'] ?? row['seq']),
      physicalSeq: _readNullableInt(row['seq']),
      status: (row['status'] ?? 'waiting').toString(),
      row: row,
    );
  }

  OrderQueueSyncEntry? _entryFromTaskRow(Map<String, dynamic> row) {
    final stageId = (row['stage_id'] ?? row['stageId'])?.toString().trim();
    if (stageId == null || stageId.isEmpty) return null;
    final groupKey = (row['stage_group_key'] ?? row['stageGroupKey'])
            ?.toString()
            .trim() ??
        stageId;
    return OrderQueueSyncEntry(
      id: row['id']?.toString(),
      stageId: stageId,
      stageGroupKey: groupKey.isEmpty ? stageId : groupKey,
      step: _readInt(row['step'] ?? row['step_no'] ?? row['seq']),
      status: (row['status'] ?? 'waiting').toString(),
      row: row,
    );
  }

  static int _readInt(dynamic value) => _readNullableInt(value) ?? 0;

  static int? _readNullableInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  @visibleForTesting
  static Map<String, int> physicalSeqByIdentityKey(
    List<OrderQueueSyncEntry> queue,
  ) {
    final stepCounts = <int, int>{};
    for (final entry in queue) {
      stepCounts[entry.step] = (stepCounts[entry.step] ?? 0) + 1;
    }

    final stepOffsets = <int, int>{};
    final usedSeqs = <int>{};
    final result = <String, int>{};
    for (final entry in queue) {
      final count = stepCounts[entry.step] ?? 0;
      if (count <= 1) {
        result[entry.identityKey] = entry.step;
        usedSeqs.add(entry.step);
        continue;
      }

      var offset = stepOffsets[entry.step] ?? 0;
      var candidate = entry.step * 1000 + offset;
      while (usedSeqs.contains(candidate) ||
          stepCounts.containsKey(candidate)) {
        offset += 1;
        candidate = entry.step * 1000 + offset;
      }
      stepOffsets[entry.step] = offset + 1;
      usedSeqs.add(candidate);
      result[entry.identityKey] = candidate;
    }
    return result;
  }

  static bool _isMissingProdPlanStageGroupKey(Object error) {
    if (error is! PostgrestException) return false;
    final message = error.message.toLowerCase();
    return error.code == 'PGRST204' &&
        message.contains('stage_group_key') &&
        message.contains('prod_plan_stages');
  }

  static bool _isMissingProdPlanStageId(Object error) {
    if (error is! PostgrestException) return false;
    final message = error.message.toLowerCase();
    return error.code == 'PGRST204' &&
        message.contains('stage_id') &&
        message.contains('prod_plan_stages');
  }

  static bool _isMissingProdPlanStageName(Object error) {
    if (error is! PostgrestException) return false;
    final message = error.message.toLowerCase();
    return error.code == 'PGRST204' &&
        message.contains('name') &&
        message.contains('prod_plan_stages');
  }

  static void _throwIfMissingProdPlanStageId(Object error) {
    if (_isMissingProdPlanStageId(error)) {
      throw const OrderQueueSyncSchemaOutdatedException();
    }
  }

  static Map<String, dynamic> _withoutStageGroupKey(
    Map<String, dynamic> payload,
  ) {
    return Map<String, dynamic>.from(payload)..remove('stage_group_key');
  }

  static Map<String, dynamic> _withoutStageName(
    Map<String, dynamic> payload,
  ) {
    return Map<String, dynamic>.from(payload)..remove('name');
  }

  Future<List<OrderQueueSyncEntry>> _deleteDuplicatePendingPlanStages(
    List<OrderQueueSyncEntry> existing,
  ) async {
    final seen = <String>{};
    final kept = <OrderQueueSyncEntry>[];
    for (final entry in existing) {
      if (seen.add(entry.identityKey)) {
        kept.add(entry);
        continue;
      }
      if (!isPendingStatus(entry.status)) {
        kept.add(entry);
        continue;
      }
      await _deletePendingPlanStage(entry);
    }
    return kept;
  }

  Future<void> _deletePlanStageByQueueSlot(
    OrderQueueSyncEntry current, {
    required bool includeStageGroupKey,
  }) async {
    final query = _sb
        .from('prod_plan_stages')
        .delete()
        .eq('stage_id', current.stageId);
    if (includeStageGroupKey) {
      query.eq('stage_group_key', current.stageGroupKey);
    }
    try {
      await query.eq('seq', current.physicalSeq ?? current.step);
    } catch (error) {
      _throwIfMissingProdPlanStageId(error);
      rethrow;
    }
  }

  Future<void> _deletePendingPlanStage(OrderQueueSyncEntry current) async {
    if (current.id != null && current.id!.isNotEmpty) {
      await _sb.from('prod_plan_stages').delete().eq('id', current.id!);
      return;
    }
    try {
      await _deletePlanStageByQueueSlot(current, includeStageGroupKey: true);
    } catch (error) {
      if (!_isMissingProdPlanStageGroupKey(error)) rethrow;
      await _deletePlanStageByQueueSlot(current, includeStageGroupKey: false);
    }
  }

  Future<void> _updatePendingPlanStage(
    OrderQueueSyncEntry current,
    OrderQueueSyncEntry next,
    int physicalSeq,
  ) async {
    final updates = {
      'stage_id': next.stageId,
      'stage_group_key': next.stageGroupKey,
      'name': next.displayName,
      'seq': physicalSeq,
      'status': 'waiting',
    };
    await _updatePlanStageWithOptionalStepNo(current, updates, next.step);
  }

  Future<void> _insertPlanStage(
    String planId,
    OrderQueueSyncEntry next,
    int physicalSeq,
  ) async {
    final row = {
      'plan_id': planId,
      'stage_id': next.stageId,
      'stage_group_key': next.stageGroupKey,
      'name': next.displayName,
      'seq': physicalSeq,
      'status': 'waiting',
    };
    try {
      await _insertPlanStageWithOptionalStepNo(row, next.step);
    } catch (error) {
      _throwIfMissingProdPlanStageId(error);
      if (_isMissingProdPlanStageGroupKey(error)) {
        await _insertPlanStageWithoutStageGroupKey(row, next.step);
        return;
      }
      if (_isMissingProdPlanStageName(error)) {
        await _insertPlanStageWithoutStageName(row, next.step);
        return;
      }
      rethrow;
    }
  }

  Future<void> _insertPlanStageWithOptionalStepNo(
    Map<String, dynamic> row,
    int stepNo,
  ) async {
    try {
      await _sb
          .from('prod_plan_stages')
          .insert({...row, 'step_no': stepNo});
    } catch (error) {
      _throwIfMissingProdPlanStageId(error);
      if (_isMissingProdPlanStageGroupKey(error) ||
          _isMissingProdPlanStageName(error)) {
        rethrow;
      }
      await _sb.from('prod_plan_stages').insert(row);
    }
  }

  Future<void> _insertPlanStageWithoutStageGroupKey(
    Map<String, dynamic> row,
    int stepNo,
  ) async {
    final legacyRow = _withoutStageGroupKey(row);
    try {
      await _insertPlanStageWithOptionalStepNo(legacyRow, stepNo);
    } catch (error) {
      _throwIfMissingProdPlanStageId(error);
      if (!_isMissingProdPlanStageName(error)) rethrow;
      await _insertPlanStageWithOptionalStepNo(
        _withoutStageName(legacyRow),
        stepNo,
      );
    }
  }

  Future<void> _insertPlanStageWithoutStageName(
    Map<String, dynamic> row,
    int stepNo,
  ) async {
    final legacyRow = _withoutStageName(row);
    try {
      await _insertPlanStageWithOptionalStepNo(legacyRow, stepNo);
    } catch (error) {
      _throwIfMissingProdPlanStageId(error);
      if (!_isMissingProdPlanStageGroupKey(error)) rethrow;
      await _insertPlanStageWithOptionalStepNo(
        _withoutStageGroupKey(legacyRow),
        stepNo,
      );
    }
  }

  Future<void> _updatePlanStageWithOptionalStepNo(
    OrderQueueSyncEntry current,
    Map<String, dynamic> updates,
    int stepNo,
  ) async {
    Future<void> run(
      Map<String, dynamic> payload, {
      required bool includeStageGroupKeyFilter,
    }) async {
      if (current.id != null && current.id!.isNotEmpty) {
        await _sb
            .from('prod_plan_stages')
            .update(payload)
            .eq('id', current.id!);
        return;
      }
      final query = _sb
          .from('prod_plan_stages')
          .update(payload)
          .eq('stage_id', current.stageId);
      if (includeStageGroupKeyFilter) {
        query.eq('stage_group_key', current.stageGroupKey);
      }
      await query.eq('seq', current.physicalSeq ?? current.step);
    }

    try {
      await run(
        {...updates, 'step_no': stepNo},
        includeStageGroupKeyFilter: true,
      );
    } catch (error) {
      _throwIfMissingProdPlanStageId(error);
      if (_isMissingProdPlanStageGroupKey(error)) {
        await run(
          _withoutStageGroupKey(updates),
          includeStageGroupKeyFilter: false,
        );
        return;
      }
      try {
        await run(updates, includeStageGroupKeyFilter: true);
      } catch (fallbackError) {
        _throwIfMissingProdPlanStageId(fallbackError);
        if (!_isMissingProdPlanStageGroupKey(fallbackError)) rethrow;
        await run(
          _withoutStageGroupKey(updates),
          includeStageGroupKeyFilter: false,
        );
      }
    }
  }

  Future<Map<String, OrderQueueSyncEntry>> _parkPendingPlanStageUpdates(
    List<OrderQueueSyncOperation> updateOperations,
  ) async {
    if (updateOperations.length < 2) {
      return const <String, OrderQueueSyncEntry>{};
    }
    final parked = <String, OrderQueueSyncEntry>{};
    var offset = 0;
    for (final op in updateOperations) {
      final current = op.current;
      if (current == null) continue;
      final tempStep = -1000000 - offset;
      offset += 1;
      await _updatePlanStageWithOptionalStepNo(
        current,
        {'seq': tempStep},
        tempStep,
      );
      parked[current.identityKey] = current.copyWith(
        step: tempStep,
        physicalSeq: tempStep,
      );
    }
    return parked;
  }

  Future<void> _deletePendingTasks(
    String orderId,
    OrderQueueSyncEntry current,
  ) async {
    await _sb
        .from('tasks')
        .delete()
        .eq('order_id', orderId)
        .eq('stage_id', current.stageId)
        .eq('stage_group_key', current.stageGroupKey)
        .inFilter(
          'status',
          pendingStatuses.where((s) => s.isNotEmpty).toList(),
        );
  }

  Future<void> _syncPendingTaskGroup(
    String orderId,
    OrderQueueSyncEntry current,
    OrderQueueSyncEntry next,
  ) async {
    await _sb
        .from('tasks')
        .update({
          'stage_id': next.stageId,
          'stage_group_key': next.stageGroupKey,
          'status': 'waiting',
        })
        .eq('order_id', orderId)
        .eq('stage_id', current.stageId)
        .eq('stage_group_key', current.stageGroupKey)
        .inFilter(
          'status',
          pendingStatuses.where((s) => s.isNotEmpty).toList(),
        );
  }

  Future<void> _deleteDuplicatePendingTasks(
    List<OrderQueueSyncEntry> existing,
  ) async {
    final seen = <String>{};
    for (final entry in existing) {
      if (seen.add(entry.identityKey)) continue;
      if (!isPendingStatus(entry.status)) continue;
      final id = entry.id?.trim() ?? '';
      if (id.isEmpty) continue;
      await _sb.from('tasks').delete().eq('id', id);
    }
  }

  Future<void> _createMissingTasks(
    String orderId,
    List<OrderQueueSyncEntry> nextQueue,
  ) async {
    final existing = await _loadTasks(orderId);
    await _deleteDuplicatePendingTasks(existing);
    final existingKeys = existing.map((entry) => entry.identityKey).toSet();
    for (final next in nextQueue) {
      if (!existingKeys.add(next.identityKey)) continue;
      await _sb.from('tasks').insert({
        'order_id': orderId,
        'stage_id': next.stageId,
        'stage_group_key': next.stageGroupKey,
        'status': 'waiting',
        'assignees': [],
        'comments': [],
      });
    }
  }

  Future<void> _markBobbinDone(
    String planId,
    String orderId,
    String bobbinStageId,
  ) async {
    final now = DateTime.now().toIso8601String();
    try {
      await _sb.from('prod_plan_stages').update({
        'status': 'done',
        'finished_at': now,
      }).match({'plan_id': planId, 'stage_id': bobbinStageId});
    } catch (error) {
      _throwIfMissingProdPlanStageId(error);
      rethrow;
    }
    await _sb.from('tasks').update({
      'status': 'done',
      'completed_at': now,
    }).match({'order_id': orderId, 'stage_id': bobbinStageId});
  }
}
