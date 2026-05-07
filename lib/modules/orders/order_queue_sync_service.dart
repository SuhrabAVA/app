import 'package:supabase_flutter/supabase_flutter.dart';

const String kStartedStageQueueChangeMessage =
    'Нельзя изменить этап, который уже находится в работе. Завершите или отмените текущий этап перед изменением очереди.';

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

class OrderQueueSyncEntry {
  const OrderQueueSyncEntry({
    this.id,
    required this.stageId,
    required this.stageGroupKey,
    required this.step,
    this.status = 'waiting',
    this.row = const <String, dynamic>{},
  });

  final String? id;
  final String stageId;
  final String stageGroupKey;
  final int step;
  final String status;
  final Map<String, dynamic> row;

  String get identityKey => '$stageGroupKey::$stageId';

  bool sameQueueSlot(OrderQueueSyncEntry other) =>
      stageId == other.stageId &&
      stageGroupKey == other.stageGroupKey &&
      step == other.step;

  OrderQueueSyncEntry copyWith({
    String? id,
    String? stageId,
    String? stageGroupKey,
    int? step,
    String? status,
    Map<String, dynamic>? row,
  }) {
    return OrderQueueSyncEntry(
      id: id ?? this.id,
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
            reason: kStartedStageQueueChangeMessage,
          ));
        } else {
          operations.add(OrderQueueSyncOperation(
            type: OrderQueueSyncOperationType.cancelOrDeletePending,
            current: current,
          ));
        }
        continue;
      }

      if (current.sameQueueSlot(next) || isProtectedStatus(current.status)) {
        operations.add(OrderQueueSyncOperation(
          type: OrderQueueSyncOperationType.keep,
          current: current,
          next: next,
        ));
      } else {
        operations.add(OrderQueueSyncOperation(
          type: OrderQueueSyncOperationType.updatePending,
          current: current,
          next: next,
        ));
      }
    }

    for (final task in currentTasks) {
      if (nextByKey.containsKey(task.identityKey)) continue;
      if (isProtectedStatus(task.status)) {
        operations.add(OrderQueueSyncOperation(
          type: OrderQueueSyncOperationType.block,
          current: task,
          reason: kStartedStageQueueChangeMessage,
        ));
      } else {
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
    final planId = await _ensurePlan(orderId);
    final currentStages = await _loadPlanStages(planId);
    final currentTasks = await _loadTasks(orderId);
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

    for (final op in operations) {
      switch (op.type) {
        case OrderQueueSyncOperationType.cancelOrDeletePending:
          final current = op.current;
          if (current != null) {
            await _deletePendingPlanStage(current);
            await _deletePendingTasks(orderId, current);
          }
          break;
        case OrderQueueSyncOperationType.updatePending:
          final current = op.current;
          final next = op.next;
          if (current != null && next != null) {
            await _updatePendingPlanStage(current, next);
            await _syncPendingTaskGroup(orderId, current, next);
          }
          break;
        case OrderQueueSyncOperationType.insert:
          final next = op.next;
          if (next != null) {
            await _insertPlanStage(planId, next);
          }
          break;
        case OrderQueueSyncOperationType.keep:
        case OrderQueueSyncOperationType.block:
          break;
      }
    }

    await _createMissingTasks(orderId, nextQueue);

    if (completeBobbin && bobbinStageId != null && bobbinStageId.trim().isNotEmpty) {
      await _markBobbinDone(planId, orderId, bobbinStageId.trim());
    }

    return operations;
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
      step: _readInt(row['seq'] ?? row['step_no'] ?? row['step']),
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

  static int _readInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<void> _deletePendingPlanStage(OrderQueueSyncEntry current) async {
    if (current.id != null && current.id!.isNotEmpty) {
      await _sb.from('prod_plan_stages').delete().eq('id', current.id!);
      return;
    }
    await _sb
        .from('prod_plan_stages')
        .delete()
        .eq('stage_id', current.stageId)
        .eq('stage_group_key', current.stageGroupKey)
        .eq('seq', current.step);
  }

  Future<void> _updatePendingPlanStage(
    OrderQueueSyncEntry current,
    OrderQueueSyncEntry next,
  ) async {
    final updates = {
      'stage_id': next.stageId,
      'stage_group_key': next.stageGroupKey,
      'seq': next.step,
      'status': 'waiting',
    };
    await _updatePlanStageWithOptionalStepNo(current, updates, next.step);
  }

  Future<void> _insertPlanStage(
    String planId,
    OrderQueueSyncEntry next,
  ) async {
    final row = {
      'plan_id': planId,
      'stage_id': next.stageId,
      'stage_group_key': next.stageGroupKey,
      'seq': next.step,
      'status': 'waiting',
    };
    try {
      await _sb
          .from('prod_plan_stages')
          .insert({...row, 'step_no': next.step});
    } catch (_) {
      await _sb.from('prod_plan_stages').insert(row);
    }
  }

  Future<void> _updatePlanStageWithOptionalStepNo(
    OrderQueueSyncEntry current,
    Map<String, dynamic> updates,
    int stepNo,
  ) async {
    Future<void> run(Map<String, dynamic> payload) async {
      if (current.id != null && current.id!.isNotEmpty) {
        await _sb
            .from('prod_plan_stages')
            .update(payload)
            .eq('id', current.id!);
        return;
      }
      await _sb
          .from('prod_plan_stages')
          .update(payload)
          .eq('stage_id', current.stageId)
          .eq('stage_group_key', current.stageGroupKey)
          .eq('seq', current.step);
    }

    try {
      await run({...updates, 'step_no': stepNo});
    } catch (_) {
      await run(updates);
    }
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

  Future<void> _createMissingTasks(
    String orderId,
    List<OrderQueueSyncEntry> nextQueue,
  ) async {
    final existing = await _loadTasks(orderId);
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
    await _sb.from('prod_plan_stages').update({
      'status': 'done',
      'finished_at': now,
    }).match({'plan_id': planId, 'stage_id': bobbinStageId});
    await _sb.from('tasks').update({
      'status': 'done',
      'completed_at': now,
    }).match({'order_id': orderId, 'stage_id': bobbinStageId});
  }
}
