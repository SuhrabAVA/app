import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const String kStartedStageQueueChangeMessage =
    'Нельзя изменить уже начатый или завершённый этап.';

const String kOutdatedProdPlanStageIdSchemaMessage =
    'Схема базы данных устарела: отсутствует prod_plan_stages.stage_id. Примените миграции Supabase';

const String kMissingReplacePlanStagesMessage =
    'Схема базы данных устарела: отсутствует функция replace_plan_stages. Примените миграции Supabase';

const String kEmptyStageQueueMessage =
    'Не удалось сохранить очередь: список этапов пуст. Соберите очередь заново.';

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

  /// [force] — применить правки к уже запущенному заказу: начатые и
  /// завершённые этапы не блокируют сохранение, а просто остаются нетронутыми.
  Future<List<OrderQueueSyncOperation>> sync({
    required String orderId,
    required List<OrderQueueSyncEntry> nextQueue,
    bool completeBobbin = false,
    String? bobbinStageId,
    bool force = false,
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
    if (blocked.isNotEmpty && !force) {
      throw OrderQueueSyncBlockedException(
        blocked.first.reason ?? kStartedStageQueueChangeMessage,
      );
    }
    // force: правки заказа применяются, даже если часть этапов уже начата или
    // завершена. Такие этапы НЕ трогаем — иначе потерялись бы зафиксированные
    // время и количество (они идут в аналитику и зарплату). Обновляются только
    // ожидающие этапы, а фактически отработанные остаются в плане как есть.

    // Состав, seq и step_no плана переписывает одна транзакция на сервере.
    // Раньше это была лесенка из отдельных запросов: удаления, «парковка» в
    // отрицательные seq, обновления, вставки. Транзакции не было, и обрыв
    // после парковки (сеть, таймаут) оставлял этапы с отрицательными seq
    // навсегда — план показывался перевёрнутым, а заказ больше не сохранялся.
    //
    // Обычное сохранение заказа маршрут не меняет, а функция трогает каждую
    // строку плана. Поэтому зовём её только когда состав или порядок этапов
    // действительно разошлись: иначе каждый сейв бил бы updated_at по всему
    // плану и рассылал realtime на ровном месте.
    if (!planMatchesQueue(currentStages, nextQueue)) {
      await _runTableStep<void>(
        orderId: orderId,
        tableName: 'prod_plan_stages',
        action: () => _replacePlanStages(planId, nextQueue),
      );
    }

    // Задачи сверяем после успешной перезаписи плана: сам план к этому
    // моменту уже согласован, и падение здесь не оставит его разобранным.
    for (final op in operations.where(
      (op) => op.type == OrderQueueSyncOperationType.cancelOrDeletePending,
    )) {
      final current = op.current;
      if (current == null) continue;
      await _runTableStep<void>(
        orderId: orderId,
        tableName: 'tasks',
        action: () => _deletePendingTasks(orderId, current),
      );
    }

    for (final op in operations.where(
      (op) => op.type == OrderQueueSyncOperationType.updatePending,
    )) {
      final current = op.current;
      final next = op.next;
      if (current == null || next == null) continue;
      await _runTableStep<void>(
        orderId: orderId,
        tableName: 'tasks',
        action: () => _syncPendingTaskGroup(orderId, current, next),
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

  /// Атомарно приводит состав и порядок этапов плана к [nextQueue].
  ///
  /// `replace_plan_stages` делает трёхстороннее слияние в одной транзакции:
  /// совпавшие строки обновляет, сохраняя их `id` (а с ним историю этапа,
  /// комментарии и файлы — они ссылаются на него с ON DELETE CASCADE),
  /// исчезнувшие ожидающие удаляет, новые вставляет. Защищённые строки
  /// (status <> waiting) не двигает и возвращает списком в поле `protected`.
  /// Промежуточная «парковка» seq живёт внутри транзакции и наружу не видна.
  Future<void> _replacePlanStages(
    String planId,
    List<OrderQueueSyncEntry> nextQueue,
  ) async {
    if (nextQueue.isEmpty) {
      // Пустую очередь функция отвергает, и правильно делает: тихая
      // перезапись плана «ничем» стёрла бы весь маршрут заказа.
      throw const OrderQueueSyncBlockedException(kEmptyStageQueueMessage);
    }
    final stages = planStagesRpcPayload(nextQueue);
    final dynamic result;
    try {
      result = await _sb.rpc(
        'replace_plan_stages',
        params: <String, dynamic>{'p_plan_id': planId, 'p_stages': stages},
      );
    } catch (error) {
      _throwIfMissingReplacePlanStages(error);
      rethrow;
    }

    final protected = _protectedStageNamesFromRpcResult(result);
    if (protected.isNotEmpty) {
      // Пересечься с проверкой blocked выше это может только в гонке: статус
      // сменился между чтением плана и вызовом функции. Данные при этом целы —
      // защищённые строки функция не тронула, — поэтому здесь достаточно следа
      // в журнале, а не отката сохранения.
      debugPrint(
        'OrderQueueSyncService: план $planId сохранён, защищённые этапы '
        'оставлены как есть: ${protected.join(', ')}',
      );
    }
  }

  /// План уже совпадает с очередью: тех же этапов столько же и каждый стоит на
  /// своём шаге. Переписывать нечего.
  @visibleForTesting
  static bool planMatchesQueue(
    List<OrderQueueSyncEntry> currentStages,
    List<OrderQueueSyncEntry> nextQueue,
  ) {
    if (currentStages.length != nextQueue.length) return false;
    for (final current in currentStages) {
      if (!nextQueue.any(current.sameQueueSlot)) return false;
    }
    return true;
  }

  /// Вход `replace_plan_stages`: только состав очереди и логический порядок.
  ///
  /// Физический `seq` клиент больше не считает — его раздаёт функция, и только
  /// она видит seq, занятые защищёнными этапами. Параллельные рабочие места
  /// одного шага остаются отдельными строками с одинаковым `step_no`.
  @visibleForTesting
  static List<Map<String, dynamic>> planStagesRpcPayload(
    List<OrderQueueSyncEntry> nextQueue,
  ) {
    return <Map<String, dynamic>>[
      for (final entry in nextQueue)
        <String, dynamic>{
          'stage_id': entry.stageId,
          'stage_group_key': entry.stageGroupKey,
          'name': entry.displayName,
          'step_no': entry.step,
        },
    ];
  }

  static List<String> _protectedStageNamesFromRpcResult(dynamic result) {
    if (result is! Map) return const <String>[];
    final protected = result['protected'];
    if (protected is! List) return const <String>[];
    return protected
        .whereType<Map>()
        .map((row) => (row['name'] ?? row['stage_id'] ?? '').toString().trim())
        .where((name) => name.isNotEmpty)
        .toList(growable: false);
  }

  static void _throwIfMissingReplacePlanStages(Object error) {
    if (error is! PostgrestException) return;
    final code = (error.code ?? '').trim();
    if (code != 'PGRST202' && code != '42883') return;
    if (!error.message.contains('replace_plan_stages')) return;
    throw const OrderQueueSyncSchemaOutdatedException(
      kMissingReplacePlanStagesMessage,
    );
  }

  Future<List<OrderQueueSyncEntry>> _loadPlanStages(String planId) async {
    // Сортируем по step_no: он и есть плановый порядок. seq — уникальный
    // ключ, и при схеме step*1000+offset порядок по нему расходится с
    // фактическим (упаковка уезжала в середину списка). Вторым ключом seq
    // держит стабильный порядок внутри шага с несколькими РМ.
    final rows = await _sb
        .from('prod_plan_stages')
        .select('*')
        .eq('plan_id', planId)
        .order('step_no', ascending: true)
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

  static void _throwIfMissingProdPlanStageId(Object error) {
    if (_isMissingProdPlanStageId(error)) {
      throw const OrderQueueSyncSchemaOutdatedException();
    }
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

  /// Строки очереди рабочего места здесь НЕ трогаем намеренно.
  ///
  /// Ими занимаются триггеры базы (миграция
  /// 20260903_atomic_stage_writes_and_queue_slots): при удалении задачи её
  /// строка очереди освобождается с сохранением номера, при появлении новой
  /// задачи того же этапа — прикрепляется к ней. Так пересборка маршрута не
  /// сбивает ручной порядок в МУПЗ.
  ///
  /// Раньше очередь не чистилась вообще: строка оставалась висеть на удалённой
  /// задаче, новая задача получала ВТОРУЮ строку, и заказ с двумя строками
  /// нельзя было поднять в очереди — показ читал одну строку, перетаскивание
  /// переписывало другую (ТОО Raw на Листорезке).
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