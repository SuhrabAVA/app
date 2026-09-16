import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/app_auth.dart';
import '../../services/realtime_sync_service.dart';

@visibleForTesting
Future<T> afterProductionQueueBootstrap<T>(
  Future<void>? bootstrap,
  Future<T> Function() read,
) async {
  if (bootstrap != null) await bootstrap;
  return read();
}

class WorkplaceQueuePosition {
  final String id;
  final String workplaceId;
  final String? taskId;
  final String orderId;
  final String stageId;
  final String? stageGroupKey;
  final int queuePosition;
  final bool hasQueuePosition;

  const WorkplaceQueuePosition({
    required this.id,
    required this.workplaceId,
    required this.taskId,
    required this.orderId,
    required this.stageId,
    required this.stageGroupKey,
    required this.queuePosition,
    this.hasQueuePosition = true,
  });

  String get queueKey => ProductionQueueProvider.queueKeyFor(
        workplaceId: workplaceId,
        taskId: taskId,
        orderId: orderId,
        stageId: stageId,
        stageGroupKey: stageGroupKey,
      );

  /// Тождество элемента очереди — БЕЗ task_id.
  ///
  /// [queueKey] строится по-разному в зависимости от того, известна ли задача
  /// (`wp::task::T` против `wp::order::O::stage::S::group::G`), а в таблице
  /// позиций лежат строки обоих видов: часть завели из рабочего пространства
  /// без task_id, часть — из производства с ним. Сопоставлять их строгим
  /// ключом нельзя: один и тот же элемент выглядит как два разных.
  String get semanticKey => ProductionQueueProvider.queueSemanticKeyFor(
        workplaceId: workplaceId,
        orderId: orderId,
        stageId: stageId,
        stageGroupKey: stageGroupKey,
      );

  static WorkplaceQueuePosition fromMap(Map<String, dynamic> map) {
    return WorkplaceQueuePosition(
      id: (map['id'] ?? '').toString(),
      workplaceId: (map['workplace_id'] ?? '').toString(),
      taskId: _nullableTrimmed(map['task_id']),
      orderId: (map['order_id'] ?? '').toString(),
      stageId: (map['stage_id'] ?? '').toString(),
      stageGroupKey: _nullableTrimmed(map['stage_group_key']),
      queuePosition: _intFrom(map['queue_position']) ?? (1 << 30),
      hasQueuePosition: _intFrom(map['queue_position']) != null,
    );
  }

  static String? _nullableTrimmed(dynamic value) {
    final trimmed = value?.toString().trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  static int? _intFrom(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }
}

@visibleForTesting
class WorkplaceQueuePositionInsertPlan {
  const WorkplaceQueuePositionInsertPlan({
    required this.entry,
    required this.queuePosition,
  });

  final WorkplaceQueueEntry entry;
  final int queuePosition;
}

@visibleForTesting
class WorkplaceQueuePositionPlanner {
  const WorkplaceQueuePositionPlanner._();

  static int comparePositions(
    WorkplaceQueuePosition left,
    WorkplaceQueuePosition right,
  ) {
    if (left.hasQueuePosition != right.hasQueuePosition) {
      return left.hasQueuePosition ? -1 : 1;
    }
    final byPosition = left.queuePosition.compareTo(right.queuePosition);
    if (byPosition != 0) return byPosition;
    return left.id.compareTo(right.id);
  }

  /// Какая из двух строк одного и того же элемента главная.
  ///
  /// В таблице встречаются пары строк на один заказ+этап: одна заведена с
  /// task_id (из производства), другая без него (из рабочего пространства).
  /// Пока показ и перестановка выбирали разные строки, заказ после
  /// перетаскивания вставал на позицию «второй» строки. Правило одно на обе
  /// стороны: выигрывает строка с task_id, при равенстве — меньшая позиция,
  /// затем id (чтобы выбор не зависел от порядка обхода карты).
  static WorkplaceQueuePosition preferredPosition(
    WorkplaceQueuePosition left,
    WorkplaceQueuePosition right,
  ) {
    final leftHasTask = (left.taskId ?? '').trim().isNotEmpty;
    final rightHasTask = (right.taskId ?? '').trim().isNotEmpty;
    if (leftHasTask != rightHasTask) return leftHasTask ? left : right;
    if (left.hasQueuePosition != right.hasQueuePosition) {
      return left.hasQueuePosition ? left : right;
    }
    if (left.queuePosition != right.queuePosition) {
      return left.queuePosition < right.queuePosition ? left : right;
    }
    return left.id.compareTo(right.id) <= 0 ? left : right;
  }

  /// Строки рабочего места по тождеству элемента, задвоения свёрнуты по
  /// [preferredPosition].
  static Map<String, WorkplaceQueuePosition> canonicalBySemanticKey(
    Iterable<WorkplaceQueuePosition> positions,
  ) {
    final result = <String, WorkplaceQueuePosition>{};
    for (final position in positions) {
      final key = position.semanticKey;
      final existing = result[key];
      result[key] =
          existing == null ? position : preferredPosition(existing, position);
    }
    return result;
  }

  /// Строка, по которой показывается позиция элемента очереди.
  ///
  /// Ровно та же, которую выберет перестановка ([reorderedQueueKeys] через
  /// [canonicalBySemanticKey]). Инвариант обязателен: пока показ и запись
  /// выбирали разные строки одного заказа, поднять его в очереди было
  /// невозможно — drag присваивал номер одной строке, а список читал вторую.
  static WorkplaceQueuePosition? positionForSemanticKey(
    Iterable<WorkplaceQueuePosition> positions,
    String semanticKey,
  ) {
    WorkplaceQueuePosition? best;
    for (final position in positions) {
      if (position.semanticKey != semanticKey) continue;
      best = best == null ? position : preferredPosition(best, position);
    }
    return best;
  }

  static List<WorkplaceQueuePosition> sortedPositions(
    Iterable<WorkplaceQueuePosition> positions,
  ) {
    final sorted = positions.toList(growable: false);
    sorted.sort(comparePositions);
    return sorted;
  }

  static int maxAssignedPosition(Iterable<WorkplaceQueuePosition> positions) {
    var maxPosition = 0;
    for (final position in positions) {
      if (!position.hasQueuePosition) continue;
      if (position.queuePosition > maxPosition) {
        maxPosition = position.queuePosition;
      }
    }
    return maxPosition;
  }

  static List<WorkplaceQueueEntry> missingEntries({
    required Iterable<WorkplaceQueuePosition> existing,
    required Iterable<WorkplaceQueueEntry> entries,
    required String workplaceId,
  }) {
    final normalizedWorkplace = workplaceId.trim();
    final existingKeys = {
      for (final position in existing)
        if (position.workplaceId.trim() == normalizedWorkplace)
          position.queueKey,
    };
    final existingSemanticKeys = {
      for (final position in existing)
        if (position.workplaceId.trim() == normalizedWorkplace)
          ProductionQueueProvider.queueSemanticKeyFor(
            workplaceId: position.workplaceId,
            orderId: position.orderId,
            stageId: position.stageId,
            stageGroupKey: position.stageGroupKey,
          ),
    };
    final missing = <WorkplaceQueueEntry>[];
    final seen = <String>{};
    for (final entry in entries) {
      if (entry.workplaceId.trim() != normalizedWorkplace) continue;
      if (entry.orderId.trim().isEmpty || entry.stageId.trim().isEmpty) {
        continue;
      }
      if (existingKeys.contains(entry.queueKey)) continue;
      final semanticKey = ProductionQueueProvider.queueSemanticKeyFor(
        workplaceId: entry.workplaceId,
        orderId: entry.orderId,
        stageId: entry.stageId,
        stageGroupKey: entry.stageGroupKey,
      );
      if (existingSemanticKeys.contains(semanticKey)) continue;
      if (!seen.add(entry.queueKey)) continue;
      missing.add(entry);
    }
    return missing;
  }

  static List<WorkplaceQueuePositionInsertPlan> appendMissingAfterMax({
    required Iterable<WorkplaceQueuePosition> existing,
    required Iterable<WorkplaceQueueEntry> entries,
    required String workplaceId,
  }) {
    final missing = missingEntries(
      existing: existing,
      entries: entries,
      workplaceId: workplaceId,
    );
    var nextPosition = maxAssignedPosition(existing) + 1;
    return [
      for (final entry in missing)
        WorkplaceQueuePositionInsertPlan(
          entry: entry,
          queuePosition: nextPosition++,
        ),
    ];
  }

  /// Сплошная нумерация 1..N для ВСЕХ строк рабочего места.
  ///
  /// [nextKeys] задаёт порядок элементов очереди, но строк у элемента может
  /// быть две (задвоение: одна с task_id, другая без). Пропущенная строка
  /// сохранила бы прежний номер и столкнулась бы с новым — очередь снова
  /// стала бы неоднозначной. Поэтому всё, что не попало в [nextKeys],
  /// дописывается следом, в текущем порядке.
  static List<WorkplaceQueuePosition> renumber({
    required Iterable<WorkplaceQueuePosition> current,
    required Iterable<String> nextKeys,
  }) {
    final byKey = <String, WorkplaceQueuePosition>{
      for (final position in current) position.queueKey: position,
    };
    final result = <WorkplaceQueuePosition>[];
    final assignedIds = <String>{};

    void assign(WorkplaceQueuePosition position) {
      if (!assignedIds.add(position.id)) return;
      result.add(WorkplaceQueuePosition(
        id: position.id,
        workplaceId: position.workplaceId,
        taskId: position.taskId,
        orderId: position.orderId,
        stageId: position.stageId,
        stageGroupKey: position.stageGroupKey,
        queuePosition: result.length + 1,
      ));
    }

    for (final key in nextKeys) {
      final position = byKey[key];
      if (position != null) assign(position);
    }
    for (final position in current) {
      assign(position);
    }
    return result;
  }

  static List<String> reorderedKeys({
    required Iterable<WorkplaceQueuePosition> current,
    required Iterable<WorkplaceQueueEntry> orderedEntries,
    required String workplaceId,
  }) {
    return reorderedQueueKeys(
      current: current,
      orderedKeys: orderedEntries.map(
        (entry) => WorkplaceQueueItemKey.fromEntry(entry),
      ),
      workplaceId: workplaceId,
    );
  }

  static List<String> reorderedQueueKeys({
    required Iterable<WorkplaceQueuePosition> current,
    required Iterable<WorkplaceQueueItemKey> orderedKeys,
    required String workplaceId,
  }) {
    final normalizedWorkplace = workplaceId.trim();
    final currentForWorkplace = sortedPositions(current.where(
      (position) => position.workplaceId.trim() == normalizedWorkplace,
    ));
    // Существующие строки ищем по тождеству, а возвращаем их собственный
    // queueKey: вызывающий сопоставляет результат с картой позиций, у которой
    // ключи именно такие. Раньше сравнение шло строгими ключами, и элемент,
    // чья строка заведена без task_id, не опознавался как видимый: его
    // позиция не переписывалась, а сам он ещё и дублировался в хвосте —
    // отсюда «поставил на одно место, а оно встало на другое».
    final bySemantic = canonicalBySemanticKey(currentForWorkplace);

    final visibleKeys = <String>[];
    final seenSemantic = <String>{};
    for (final key in orderedKeys) {
      if (key.workplaceId.trim() != normalizedWorkplace) continue;
      if (!seenSemantic.add(key.semanticKey)) continue;
      final existing = bySemantic[key.semanticKey];
      visibleKeys.add(existing?.queueKey ?? key.queueKey);
    }

    // В хвост — по одной строке на элемент: вторая строка задвоенного элемента
    // заняла бы отдельный номер и сдвинула всё, что ниже.
    final tailSeen = <String>{};
    return <String>[
      ...visibleKeys,
      for (final position in currentForWorkplace)
        if (!seenSemantic.contains(position.semanticKey) &&
            tailSeen.add(position.semanticKey))
          bySemantic[position.semanticKey]?.queueKey ?? position.queueKey,
    ];
  }
}

class WorkplaceQueueItemKey {
  final String workplaceId;
  final String? taskId;
  final String orderId;
  final String stageId;
  final String? stageGroupKey;

  const WorkplaceQueueItemKey({
    required this.workplaceId,
    this.taskId,
    required this.orderId,
    required this.stageId,
    this.stageGroupKey,
  });

  factory WorkplaceQueueItemKey.fromEntry(WorkplaceQueueEntry entry) {
    return WorkplaceQueueItemKey(
      workplaceId: entry.workplaceId,
      taskId: entry.taskId,
      orderId: entry.orderId,
      stageId: entry.stageId,
      stageGroupKey: entry.stageGroupKey,
    );
  }

  String get queueKey => ProductionQueueProvider.queueKeyFor(
        workplaceId: workplaceId,
        taskId: taskId,
        orderId: orderId,
        stageId: stageId,
        stageGroupKey: stageGroupKey,
      );

  /// Тождество элемента очереди — см. [WorkplaceQueuePosition.semanticKey].
  String get semanticKey => ProductionQueueProvider.queueSemanticKeyFor(
        workplaceId: workplaceId,
        orderId: orderId,
        stageId: stageId,
        stageGroupKey: stageGroupKey,
      );

  WorkplaceQueueEntry toEntry() {
    return WorkplaceQueueEntry(
      workplaceId: workplaceId,
      taskId: taskId,
      orderId: orderId,
      stageId: stageId,
      stageGroupKey: stageGroupKey,
    );
  }
}

class WorkplaceQueueEntry {
  final String workplaceId;
  final String? taskId;
  final String orderId;
  final String stageId;
  final String? stageGroupKey;

  const WorkplaceQueueEntry({
    required this.workplaceId,
    required this.taskId,
    required this.orderId,
    required this.stageId,
    this.stageGroupKey,
  });

  /// Единственный способ построить элемент очереди рабочего места.
  ///
  /// ПОЧЕМУ stageId ПРИБИТ К РАБОЧЕМУ МЕСТУ
  /// Тождество слота — это `workplaceId::order::stageId::group`, и один и тот
  /// же слот обязаны одинаково назвать все экраны. Рабочее пространство
  /// отбирает задачи условием `task.stageId == выбранное РМ`, поэтому у него
  /// stageId всегда равен рабочему месту. МУПЗ же брал stageId из НАЙДЕННОЙ
  /// задачи, а искал её через `tasksByGroup[group.key]` — по ключу группы
  /// маршрута, тогда как задачи разложены по СВОЕМУ `task.stageGroupKey`.
  /// Ключи расходились, и на один слот заводились ДВЕ строки позиций: одну
  /// читало рабочее пространство, другую — МУПЗ. Списки после этого жили
  /// каждый своей жизнью, а перетаскивание в МУПЗ не двигало то, что видит
  /// рабочий.
  ///
  /// Уникальный индекс `workplace_queue_positions_item_uniq` от этого не
  /// спасал: он держит одну строку на ключ, а ключи были разные.
  ///
  /// Пустой [workplaceId] или [orderId] даёт элемент, который
  /// `syncWorkplaceEntries` отбрасывает, — это законный «нечего ставить в
  /// очередь», а не ошибка.
  factory WorkplaceQueueEntry.forSlot({
    required String workplaceId,
    required String orderId,
    String? taskId,
    String? stageGroupKey,
  }) {
    final workplace = workplaceId.trim();
    return WorkplaceQueueEntry(
      workplaceId: workplace,
      taskId: (taskId?.trim().isEmpty ?? true) ? null : taskId!.trim(),
      orderId: orderId.trim(),
      stageId: workplace,
      stageGroupKey: stageGroupKey?.trim(),
    );
  }

  String get queueKey => ProductionQueueProvider.queueKeyFor(
        workplaceId: workplaceId,
        taskId: taskId,
        orderId: orderId,
        stageId: stageId,
        stageGroupKey: stageGroupKey,
      );

  /// Тождество элемента очереди — см. [WorkplaceQueuePosition.semanticKey].
  String get semanticKey => ProductionQueueProvider.queueSemanticKeyFor(
        workplaceId: workplaceId,
        orderId: orderId,
        stageId: stageId,
        stageGroupKey: stageGroupKey,
      );

  Map<String, dynamic> toInsertMap(int queuePosition) => {
        'workplace_id': workplaceId.trim(),
        if (taskId?.trim().isNotEmpty == true) 'task_id': taskId!.trim(),
        'order_id': orderId.trim(),
        'stage_id': stageId.trim(),
        if (stageGroupKey?.trim().isNotEmpty == true)
          'stage_group_key': stageGroupKey!.trim(),
        'queue_position': queuePosition,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
}

/// Отвечает за ручную очередь производственных заданий рабочих мест и скрытые записи.
///
/// Ручная очередь рабочих мест хранится в Supabase в
/// `public.workplace_queue_positions`. Старый `production_queue_state` остаётся
/// только для скрытых заказов и fallback-совместимости старых экранов.
class ProductionQueueProvider with ChangeNotifier {
  static const _prefsKeyOrder = 'production_order_sequence';
  static const _prefsKeyHidden = 'production_hidden_orders';
  static const _prefsKeyPositions = 'production_workplace_positions';
  static const _defaultGroup = 'global';
  static const _legacyRemoteTable = 'production_queue_state';
  static const _positionsTable = 'workplace_queue_positions';

  // Ключи подавления повторов лога, см. [_logSyncError].
  static const _syncSourceLegacy = 'legacy';
  static const _syncSourcePositions = 'positions';

  /// 25 с вместо прежних 10: цеховой Wi-Fi слабый, а после замедления
  /// поллинга до 20 с одиночный медленный запрос уже никому не мешает.
  static const _queueRequestTimeout = Duration(seconds: 25);

  final Map<String, List<String>> _orderSequences = {};
  final Map<String, Set<String>> _hiddenOrders = {};
  final Map<String, Map<String, WorkplaceQueuePosition>> _positionsByWorkplace =
      {};
  final SupabaseClient _sb = Supabase.instance.client;
  Future<void>? _remoteBootstrap;
  Timer? _pollingTimer;
  bool _disposed = false;

  // Защита поллинга: не запускаем новый цикл, пока висит предыдущий,
  // а при ошибках сети пропускаем тики с экспоненциальным backoff (до 60 с).
  bool _pollInFlight = false;
  int _pollFailureStreak = 0;
  int _pollSkipTicks = 0;
  // Подавление повторов лога — отдельно по каждому источнику. Общий флаг
  // сбрасывался успехом соседней таблицы: legacy-запрос проходил, снимал
  // подавление, и следующий таймаут positions снова печатался. В журнале
  // это давало по 7 одинаковых строк за 11 секунд.
  final Set<String> _mutedSyncErrorSources = <String>{};

  bool _loaded = false;
  bool _isSyncingOrders = false;

  bool get isReady => _loaded;

  ProductionQueueProvider() {
    RealtimeSyncService.instance.registerRefreshHandler(
      owner: this,
      resource: RealtimeResource.productionQueueLegacy,
      handler: refreshLegacyRemoteState,
    );
    RealtimeSyncService.instance.registerRefreshHandler(
      owner: this,
      resource: RealtimeResource.productionQueuePositions,
      handler: refreshPositionsRemoteState,
    );
    _bootstrapRemoteSync();
    _startPollingFallback();
  }

  static String queueKeyFor({
    required String workplaceId,
    String? taskId,
    required String orderId,
    required String stageId,
    String? stageGroupKey,
  }) {
    final workplace = workplaceId.trim();
    final task = taskId?.trim() ?? '';
    if (task.isNotEmpty) return '$workplace::task::$task';
    return '$workplace::order::${orderId.trim()}::stage::${stageId.trim()}::group::${(stageGroupKey ?? '').trim()}';
  }

  static String queueSemanticKeyFor({
    required String workplaceId,
    required String orderId,
    required String stageId,
    String? stageGroupKey,
  }) {
    return '${workplaceId.trim()}::order::${orderId.trim()}::stage::${stageId.trim()}::group::${(stageGroupKey ?? '').trim()}';
  }

  void _startPollingFallback() {
    _pollingTimer?.cancel();
    // 20 с, а не 2: обе таблицы опубликованы в supabase_realtime и приходят
    // подпиской, поллинг — только страховка на случай разрыва сокета.
    // Прежние 2 с давали ~1 запрос/сек на планшет и сами создавали затор
    // на цеховом Wi-Fi.
    _pollingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(_pollRemote());
    });
  }

  Future<void> _pollRemote() async {
    if (_pollInFlight) return;
    if (_pollSkipTicks > 0) {
      _pollSkipTicks--;
      return;
    }
    _pollInFlight = true;
    try {
      final result = await afterProductionQueueBootstrap(
        _remoteBootstrap,
        () async {
          if (_disposed) return (legacy: true, positions: true);
          return (
            legacy: await _loadLegacyRemote(),
            positions: await _loadAllWorkplacePositions(),
          );
        },
      );
      final legacyOk = result.legacy;
      final positionsOk = result.positions;
      if (legacyOk && positionsOk) {
        _pollFailureStreak = 0;
        _pollSkipTicks = 0;
      } else {
        if (_pollFailureStreak < 5) _pollFailureStreak++;
        // 1 → 3 пропущенных тика: при тике 20 с это 40 с и 80 с между
        // попытками. Потолок опущен с 29 тиков специально: раньше при тике
        // 2 с он давал ~60 с, а после замедления поллинга те же 29 тиков
        // растянулись бы до 10 минут.
        _pollSkipTicks = (1 << _pollFailureStreak) - 1;
        if (_pollSkipTicks > 3) _pollSkipTicks = 3;
      }
    } finally {
      _pollInFlight = false;
    }
  }

  void _logSyncError(String source, String message) {
    if (!_mutedSyncErrorSources.add(source)) return;
    debugPrint('$message (повторные ошибки скрыты до восстановления связи)');
  }

  void _noteSyncSuccess(String source) {
    if (!_mutedSyncErrorSources.remove(source)) return;
    debugPrint('✅ Связь с Supabase восстановлена ($source), '
        'синхронизация очереди продолжается');
  }

  Future<void> _init() async {
    await _loadLocal();
    await _loadLegacyRemote(seedRemoteWhenEmpty: true);
    await _loadAllWorkplacePositions();
  }

  Future<void> _bootstrapRemoteSync() {
    final existing = _remoteBootstrap;
    if (existing != null) return existing;
    final future = _init().whenComplete(() {
      _remoteBootstrap = null;
    });
    _remoteBootstrap = future;
    return future;
  }

  String _normalizeGroup(String groupId) {
    final trimmed = groupId.trim();
    return trimmed.isEmpty ? _defaultGroup : trimmed;
  }

  String _normalizeOrderId(String orderId) => orderId.trim();

  String _normalizeWorkplaceId(String workplaceId) => workplaceId.trim();

  List<String> _sequenceForGroup(String groupId) {
    final key = _normalizeGroup(groupId);
    return _orderSequences.putIfAbsent(key, () => <String>[]);
  }

  Set<String> _hiddenForGroup(String groupId) {
    final key = _normalizeGroup(groupId);
    return _hiddenOrders.putIfAbsent(key, () => <String>{});
  }

  Future<void> _loadLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawSequence = prefs.getString(_prefsKeyOrder);
      if (rawSequence != null && rawSequence.isNotEmpty) {
        final decoded = jsonDecode(rawSequence);
        if (decoded is List) {
          _orderSequences[_defaultGroup] = decoded
              .map((e) => e?.toString() ?? '')
              .where((e) => e.isNotEmpty)
              .toList();
        } else if (decoded is Map) {
          decoded.forEach((key, value) {
            if (value is List) {
              _orderSequences[key.toString()] = value
                  .map((e) => e?.toString() ?? '')
                  .where((e) => e.isNotEmpty)
                  .toList();
            }
          });
        }
      }

      final rawHiddenMap = prefs.getString(_prefsKeyHidden);
      if (rawHiddenMap != null && rawHiddenMap.isNotEmpty) {
        final decoded = jsonDecode(rawHiddenMap);
        if (decoded is List) {
          _hiddenOrders[_defaultGroup] = decoded
              .map((e) => e?.toString() ?? '')
              .where((e) => e.isNotEmpty)
              .toSet();
        } else if (decoded is Map) {
          decoded.forEach((key, value) {
            if (value is List) {
              _hiddenOrders[key.toString()] = value
                  .map((e) => e?.toString() ?? '')
                  .where((e) => e.isNotEmpty)
                  .toSet();
            }
          });
        }
      } else {
        final rawHidden = prefs.getStringList(_prefsKeyHidden);
        if (rawHidden != null) {
          _hiddenOrders[_defaultGroup] =
              rawHidden.where((e) => e.trim().isNotEmpty).toSet();
        }
      }
      // Снимок позиций с прошлого запуска больше не читаем и не храним —
      // очередь берётся только из базы. Ключ удаляем, чтобы на устройствах,
      // обновившихся со старой версии, не оставалось лежать старой очереди.
      await prefs.remove(_prefsKeyPositions);
    } catch (e) {
      debugPrint('❌ Failed to load production queue prefs: $e');
    }

    _loaded = true;
    notifyListeners();
  }

  /// Рабочие места, для которых позиции уже грузятся.
  final Set<String> _positionsRequested = <String>{};

  /// Статус загрузки позиций по рабочим местам.
  ///
  /// Раньше отказ сети был неотличим от успеха: клиент молча отдавал снимок с
  /// диска, и соседние планшеты показывали разную очередь, оба — уверенно.
  /// Теперь экран знает, загружены позиции или нет, и вместо произвольного
  /// порядка показывает, что связи нет.
  final Map<String, bool> _positionsLoadedByWorkplace = <String, bool>{};

  /// Загружены ли позиции этого рабочего места в текущем сеансе.
  bool positionsLoadedFor(String workplaceId) =>
      _positionsLoadedByWorkplace[_normalizeWorkplaceId(workplaceId)] ?? false;

  /// Идёт ли сейчас запрос позиций этого рабочего места.
  ///
  /// Нужно, чтобы отличать «ещё грузим» от «не смогли загрузить»: без этого
  /// экран показывал бы отказ в первом же кадре, до того как запрос вообще
  /// успел уйти.
  bool positionsLoadingFor(String workplaceId) =>
      _positionsRequested.contains(_normalizeWorkplaceId(workplaceId));

  Future<void> _ensureAuthed() async {
    try {
      await AppAuth.ensureSignedIn();
      return;
    } catch (_) {}
    final auth = _sb.auth;
    if (auth.currentUser != null) return;
    try {
      await auth.signInAnonymously();
    } catch (_) {}
  }

  List<String> _decodeStringList(dynamic raw) {
    if (raw is! List) return <String>[];
    return raw
        .map((e) => e?.toString().trim() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
  }

  bool _stringListsEqual(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (_normalizeOrderId(left[i]) != _normalizeOrderId(right[i]))
        return false;
    }
    return true;
  }

  bool _stringSetsEqual(Set<String> left, Set<String> right) {
    if (left.length != right.length) return false;
    for (final value in left) {
      if (!right.contains(_normalizeOrderId(value))) return false;
    }
    return true;
  }

  /// Сравнение двух позиций по значению: у [WorkplaceQueuePosition] нет
  /// переопределённого `==`, поэтому полагаться на равенство объектов и на
  /// равенство вложенных `Map` нельзя — сравниваем поля явно.
  @visibleForTesting
  static bool positionsEqual(
    WorkplaceQueuePosition left,
    WorkplaceQueuePosition right,
  ) {
    return left.id == right.id &&
        left.workplaceId == right.workplaceId &&
        left.taskId == right.taskId &&
        left.orderId == right.orderId &&
        left.stageId == right.stageId &&
        left.stageGroupKey == right.stageGroupKey &&
        left.queuePosition == right.queuePosition &&
        left.hasQueuePosition == right.hasQueuePosition;
  }

  /// Совпадают ли два снимка позиций рабочих мест целиком.
  ///
  /// Нужно, чтобы поллинг не дёргал `notifyListeners()` на каждом тике:
  /// `TasksScreen` подписан на провайдер через `context.watch`, и безусловная
  /// нотификация пересобирала весь экран, ломая открытые диалоги.
  @visibleForTesting
  static bool positionSnapshotsMatch(
    Map<String, Map<String, WorkplaceQueuePosition>> left,
    Map<String, Map<String, WorkplaceQueuePosition>> right,
  ) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      final other = right[entry.key];
      if (other == null) return false;
      if (entry.value.length != other.length) return false;
      for (final position in entry.value.entries) {
        final counterpart = other[position.key];
        if (counterpart == null) return false;
        if (!positionsEqual(position.value, counterpart)) return false;
      }
    }
    return true;
  }

  bool _legacyRemoteStateMatches(
    Map<String, List<String>> nextSequences,
    Map<String, Set<String>> nextHidden,
  ) {
    if (_orderSequences.length != nextSequences.length ||
        _hiddenOrders.length != nextHidden.length) return false;
    for (final entry in nextSequences.entries) {
      final current = _orderSequences[entry.key];
      if (current == null || !_stringListsEqual(current, entry.value))
        return false;
    }
    for (final entry in nextHidden.entries) {
      final current = _hiddenOrders[entry.key];
      if (current == null || !_stringSetsEqual(current, entry.value))
        return false;
    }
    return true;
  }

  Future<bool> _loadLegacyRemote({bool seedRemoteWhenEmpty = false}) async {
    try {
      await _ensureAuthed();
      final raw = await _sb
          .from(_legacyRemoteTable)
          .select('group_id, order_sequence, hidden_order_ids')
          .timeout(_queueRequestTimeout);
      _noteSyncSuccess(_syncSourceLegacy);
      if (_disposed) return true;
      if (raw is! List) return true;

      final nextSequences = <String, List<String>>{};
      final nextHidden = <String, Set<String>>{};
      for (final row in raw) {
        if (row is! Map) continue;
        final map = Map<String, dynamic>.from(row as Map);
        final groupId = _normalizeGroup(map['group_id']?.toString() ?? '');
        nextSequences[groupId] = _decodeStringList(map['order_sequence']);
        nextHidden[groupId] =
            _decodeStringList(map['hidden_order_ids']).toSet();
      }

      if (shouldSeedLegacyRemote(
        seedRemoteWhenEmpty: seedRemoteWhenEmpty,
        remoteIsEmpty: nextSequences.isEmpty && nextHidden.isEmpty,
        localIsEmpty: _orderSequences.isEmpty && _hiddenOrders.isEmpty,
      )) {
        await _pushLocalStateToLegacyRemote();
        return true;
      }
      if (_legacyRemoteStateMatches(nextSequences, nextHidden)) return true;

      _orderSequences
        ..clear()
        ..addAll(nextSequences);
      _hiddenOrders
        ..clear()
        ..addAll(nextHidden);

      await _persist();
      notifyListeners();
      return true;
    } catch (e) {
      _logSyncError(_syncSourceLegacy,
          '⚠️ Failed to load legacy production queue from Supabase: $e');
      return false;
    }
  }

  Future<bool> _loadAllWorkplacePositions() async {
    try {
      await _ensureAuthed();
      // Страницами по 1000: PostgREST по умолчанию не отдаёт больше тысячи
      // строк за запрос, а таблица уже перевалила за неё. Без пагинации
      // «хвост» просто не приезжал, и заказы этих рабочих мест оказывались
      // без позиции — то есть в конце списка, независимо от очереди.
      const pageSize = 1000;
      final raw = <dynamic>[];
      for (var offset = 0;; offset += pageSize) {
        final page = await _sb
            .from(_positionsTable)
            .select(
                'id, workplace_id, task_id, order_id, stage_id, stage_group_key, queue_position')
            .order('workplace_id')
            .order('queue_position')
            .range(offset, offset + pageSize - 1)
            .timeout(_queueRequestTimeout);
        if (page is! List) break;
        raw.addAll(page);
        if (page.length < pageSize) break;
      }
      _noteSyncSuccess(_syncSourcePositions);
      if (_disposed) return true;
      final next = <String, Map<String, WorkplaceQueuePosition>>{};
      for (final row in raw) {
        if (row is! Map) continue;
        final position = WorkplaceQueuePosition.fromMap(
            Map<String, dynamic>.from(row as Map));
        final workplaceId = _normalizeWorkplaceId(position.workplaceId);
        if (workplaceId.isEmpty ||
            position.orderId.trim().isEmpty ||
            position.stageId.trim().isEmpty) continue;
        next.putIfAbsent(workplaceId, () => <String, WorkplaceQueuePosition>{})[
            position.queueKey] = position;
      }
      for (final workplaceId in next.keys) {
        _positionsLoadedByWorkplace[workplaceId] = true;
      }
      if (positionSnapshotsMatch(_positionsByWorkplace, next)) return true;
      _positionsByWorkplace
        ..clear()
        ..addAll(next);
      notifyListeners();
      return true;
    } catch (e) {
      _logSyncError(_syncSourcePositions,
          '⚠️ Failed to load workplace queue positions from Supabase: $e');
      return false;
    }
  }

  /// Перечитывает удалённую очередь без каких-либо записей в Supabase.
  /// Повторный realtime event во время чтения объединяется в один проход.
  Future<void> refreshLegacyRemoteState() async {
    await afterProductionQueueBootstrap(_remoteBootstrap, () async {
      if (_disposed) return;
      await _loadLegacyRemote();
    });
  }

  Future<void> refreshPositionsRemoteState() async {
    await afterProductionQueueBootstrap(_remoteBootstrap, () async {
      if (_disposed) return;
      await _loadAllWorkplacePositions();
    });
  }

  @visibleForTesting
  static bool shouldSeedLegacyRemote({
    required bool seedRemoteWhenEmpty,
    required bool remoteIsEmpty,
    required bool localIsEmpty,
  }) =>
      seedRemoteWhenEmpty && remoteIsEmpty && !localIsEmpty;

  Future<void> refreshRemoteState() async {
    await Future.wait<void>([
      refreshLegacyRemoteState(),
      refreshPositionsRemoteState(),
    ]);
  }



  /// Гарантирует, что позиции ОДНОГО рабочего места загружены.
  ///
  /// Экран очереди не должен зависеть от общего запроса по всей таблице: тот
  /// тянет больше тысячи строк и на цеховой сети регулярно не укладывался в
  /// таймаут (в журнале это «Failed to load workplace queue positions»). При
  /// его провале карта позиций оставалась пустой, priorityOfEntry возвращал
  /// «бесконечность» для всех заказов, и список показывался в произвольном
  /// порядке — при том что в базе номера были правильные. Запрос по одному
  /// рабочему месту меньше на порядок и проходит.
  void ensurePositionsLoaded(String workplaceId) {
    final normalized = _normalizeWorkplaceId(workplaceId);
    if (normalized.isEmpty || _disposed) return;
    // Очередь всегда читается из базы. Дедуп по _positionsRequested, чтобы
    // повторные перестройки экрана не плодили одинаковые запросы.
    if (!_positionsRequested.add(normalized)) return;
    // Метод зовётся и из build (нельзя уведомлять сразу), и с кнопки
    // «Повторить» (там уведомить надо, иначе нажатие выглядит как ничего).
    // Пост-кадровый колбэк подходит обоим.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) notifyListeners();
    });
    unawaited(loadPositionsForWorkplace(normalized).whenComplete(() {
      _positionsRequested.remove(normalized);
      // Снимаем признак «грузится» И только потом уведомляем: иначе экран
      // перерисуется, пока флаг ещё стоит, и навсегда останется со спиннером.
      if (!_disposed) notifyListeners();
    }));
  }

  /// Читает позиции рабочего места ИЗ БАЗЫ. Единственный источник очереди.
  ///
  /// Сеть в цеху рвётся часто (в журнале за месяц 483 отказа DNS и 373
  /// таймаута), поэтому одна неудачная попытка — не повод сдаваться: пробуем
  /// три раза с нарастающей паузой. Если не вышло и после этого, рабочее место
  /// помечается «не загружено», и экран показывает это прямо, а не рисует
  /// список в произвольном порядке.
  Future<List<WorkplaceQueuePosition>> loadPositionsForWorkplace(
      String workplaceId) async {
    final normalized = _normalizeWorkplaceId(workplaceId);
    if (normalized.isEmpty) return const <WorkplaceQueuePosition>[];
    const attempts = 3;
    Object? lastError;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      if (_disposed) return positionsForWorkplace(normalized);
      try {
        await _ensureAuthed();
        final raw = await _sb
            .from(_positionsTable)
            .select(
                'id, workplace_id, task_id, order_id, stage_id, stage_group_key, queue_position')
            .eq('workplace_id', normalized)
            .order('queue_position')
            .timeout(_queueRequestTimeout);
        if (raw is! List) throw StateError('unexpected payload');
        _noteSyncSuccess('$_syncSourcePositions:$normalized');
        final positions = WorkplaceQueuePositionPlanner.sortedPositions(
          raw.whereType<Map>().map(
                (row) => WorkplaceQueuePosition.fromMap(
                  Map<String, dynamic>.from(row),
                ),
              ),
        );
        _positionsByWorkplace[normalized] = {
          for (final position in positions) position.queueKey: position,
        };
        _positionsLoadedByWorkplace[normalized] = true;
        notifyListeners();
        return positions;
      } catch (e) {
        lastError = e;
        if (attempt < attempts) {
          await Future<void>.delayed(Duration(seconds: attempt * 2));
        }
      }
    }
    // Отказ больше не притворяется успехом: снимка с диска нет, а то, что
    // осталось в памяти от прошлой удачной загрузки, помечено устаревшим.
    _positionsLoadedByWorkplace[normalized] = false;
    _logSyncError('$_syncSourcePositions:$normalized',
        '⚠️ Failed to load workplace queue positions for "$normalized": $lastError');
    notifyListeners();
    return positionsForWorkplace(normalized);
  }

  List<WorkplaceQueuePosition> positionsForWorkplace(String workplaceId) {
    final values = _positionsByWorkplace[_normalizeWorkplaceId(workplaceId)]
            ?.values
            .toList() ??
        <WorkplaceQueuePosition>[];
    return WorkplaceQueuePositionPlanner.sortedPositions(values);
  }

  int priorityOfEntry(WorkplaceQueueEntry entry) {
    final workplaceId = _normalizeWorkplaceId(entry.workplaceId);
    if (workplaceId.isEmpty) return 1 << 30;
    final workplaceMap = _positionsByWorkplace[workplaceId];
    if (workplaceMap == null || workplaceMap.isEmpty) return 1 << 30;
    final semanticKey = queueSemanticKeyFor(
      workplaceId: workplaceId,
      orderId: entry.orderId,
      stageId: entry.stageId,
      stageGroupKey: entry.stageGroupKey,
    );
    // Ту же строку, что выберет перестановка — см. positionForSemanticKey.
    //
    // Раньше здесь стоял быстрый путь «точное совпадение по queueKey», и он
    // обходил это правило. У заказа с ДВУМЯ строками (одна на живой задаче,
    // другая на удалённой) показ попадал в строку живой задачи, а
    // перестановка выбирала строку с меньшим номером — то есть мёртвую. Заказ
    // ТОО Raw на Листорезке из-за этого нельзя было поднять в очереди вообще:
    // drag присваивал номер мёртвой строке, живая уезжала в хвост, и список
    // читал именно её.
    final best = WorkplaceQueuePositionPlanner.positionForSemanticKey(
      workplaceMap.values,
      semanticKey,
    );
    if (best != null) return best.queuePosition;
    return 1 << 30;
  }

  List<T> getSortedByWorkplaceQueue<T>(
    List<T> items,
    WorkplaceQueueEntry Function(T) entrySelector,
  ) {
    final indexed = <({T item, int index})>[];
    for (var i = 0; i < items.length; i++) {
      indexed.add((item: items[i], index: i));
    }
    indexed.sort((a, b) {
      final priorityComparison = priorityOfEntry(entrySelector(a.item))
          .compareTo(priorityOfEntry(entrySelector(b.item)));
      if (priorityComparison != 0) return priorityComparison;
      return a.index.compareTo(b.index);
    });
    return indexed.map((entry) => entry.item).toList();
  }

  Future<void> _pushLocalStateToLegacyRemote() async {
    for (final entry in _orderSequences.entries) {
      await _upsertLegacyRemoteGroup(entry.key);
    }
    for (final groupId in _hiddenOrders.keys) {
      if (_orderSequences.containsKey(groupId)) continue;
      await _upsertLegacyRemoteGroup(groupId);
    }
  }

  Future<void> _upsertLegacyRemoteGroup(String groupId) async {
    try {
      await _ensureAuthed();
      await _sb.from(_legacyRemoteTable).upsert({
        'group_id': _normalizeGroup(groupId),
        'order_sequence': _sequenceForGroup(groupId),
        'hidden_order_ids': _hiddenForGroup(groupId).toList(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      debugPrint(
          '⚠️ Failed to upsert legacy production queue group "$groupId": $e');
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final orderPayload = <String, List<String>>{};
      _orderSequences.forEach((key, value) {
        orderPayload[key] = value.where((e) => e.trim().isNotEmpty).toList();
      });
      final hiddenPayload = <String, List<String>>{};
      _hiddenOrders.forEach((key, value) {
        hiddenPayload[key] = value.where((e) => e.trim().isNotEmpty).toList();
      });
      await prefs.setString(_prefsKeyOrder, jsonEncode(orderPayload));
      await prefs.setString(_prefsKeyHidden, jsonEncode(hiddenPayload));
    } catch (e) {
      debugPrint('❌ Failed to persist production queue prefs: $e');
    }
  }

  Future<void> _persistEverywhere({String? groupId}) async {
    await _persist();
    if (groupId != null) {
      await _upsertLegacyRemoteGroup(groupId);
      return;
    }
    await _pushLocalStateToLegacyRemote();
  }

  /// Номер для нового элемента в хвосте очереди — считается ПО БАЗЕ.
  ///
  /// Раньше при сетевом сбое `catch (_) {}` молча оставлял максимум из памяти.
  /// Устройство с отставшим снимком вставляло элемент на уже занятый номер, а
  /// уникальности на `(workplace_id, queue_position)` в схеме нет — получалась
  /// ничья, и порядок у такого элемента начинал зависеть от устройства.
  /// Теперь сбой чтения — это отказ: лучше не записать ничего, чем записать
  /// номер, взятый с потолка.
  Future<int> _nextPositionForWorkplace(String workplaceId) async {
    final normalized = _normalizeWorkplaceId(workplaceId);
    final raw = await _sb
        .from(_positionsTable)
        .select('queue_position')
        .eq('workplace_id', normalized)
        .timeout(_queueRequestTimeout);
    var maxPosition = 0;
    if (raw is List) {
      for (final row in raw.whereType<Map>()) {
        final remoteMax = WorkplaceQueuePosition._intFrom(
          row['queue_position'],
        );
        if (remoteMax != null && remoteMax > maxPosition) {
          maxPosition = remoteMax;
        }
      }
    }
    return maxPosition + 1;
  }

  Future<void> ensureEntryAtTail(WorkplaceQueueEntry entry) async {
    final workplaceId = _normalizeWorkplaceId(entry.workplaceId);
    if (workplaceId.isEmpty ||
        entry.orderId.trim().isEmpty ||
        entry.stageId.trim().isEmpty) return;
    // По тождеству, а не по строгому ключу: иначе для элемента, уже
    // записанного без task_id, вставлялась ВТОРАЯ строка на ту же позицию в
    // очереди, и порядок становился неопределённым.
    final existing = _positionsByWorkplace[workplaceId];
    if (existing != null &&
        existing.values.any((p) => p.semanticKey == entry.semanticKey)) {
      return;
    }
    try {
      await _ensureAuthed();
      final position = await _nextPositionForWorkplace(workplaceId);
      await _sb.from(_positionsTable).insert(entry.toInsertMap(position));
      await loadPositionsForWorkplace(workplaceId);
    } catch (e) {
      debugPrint(
        '⚠️ Failed to append workplace queue entry "${entry.queueKey}": $e',
      );
      await loadPositionsForWorkplace(workplaceId);
    }
  }

  /// Синхронизирует задания рабочих мест: существующие позиции не меняются,
  /// новые записи добавляются в конец очереди только внутри своего workplace.
  void syncWorkplaceEntries(
    Iterable<WorkplaceQueueEntry> entries, {
    String? workplaceId,
  }) {
    if (_isSyncingOrders) return;
    final requestedWorkplace =
        workplaceId == null ? null : _normalizeWorkplaceId(workplaceId);
    if (workplaceId != null && requestedWorkplace!.isEmpty) return;
    _isSyncingOrders = true;
    try {
      unawaited(_bootstrapRemoteSync());
      final entriesByWorkplace = <String, List<WorkplaceQueueEntry>>{};
      final seenByWorkplace = <String, Set<String>>{};
      for (final entry in entries) {
        final normalized = _normalizeWorkplaceId(entry.workplaceId);
        if (normalized.isEmpty) continue;
        if (requestedWorkplace != null && normalized != requestedWorkplace) {
          continue;
        }
        if (entry.orderId.trim().isEmpty || entry.stageId.trim().isEmpty) {
          continue;
        }
        final seen = seenByWorkplace.putIfAbsent(normalized, () => <String>{});
        if (!seen.add(entry.queueKey)) continue;
        entriesByWorkplace
            .putIfAbsent(normalized, () => <WorkplaceQueueEntry>[])
            .add(entry);
      }
      if (entriesByWorkplace.isEmpty) {
        _isSyncingOrders = false;
        return;
      }
      unawaited(() async {
        try {
          for (final workplaceEntry in entriesByWorkplace.entries) {
            await _syncSingleWorkplaceEntries(
              workplaceEntry.value,
              workplaceId: workplaceEntry.key,
            );
          }
        } finally {
          _isSyncingOrders = false;
        }
      }());
    } catch (_) {
      _isSyncingOrders = false;
    }
  }

  Future<void> _syncSingleWorkplaceEntries(
    List<WorkplaceQueueEntry> entries, {
    required String workplaceId,
  }) async {
    final positions = await loadPositionsForWorkplace(workplaceId);
    if (positions.any((position) => !position.hasQueuePosition)) {
      await normalizePositions(workplaceId: workplaceId);
    }
    final current = positionsForWorkplace(workplaceId);
    final insertPlans = WorkplaceQueuePositionPlanner.appendMissingAfterMax(
      existing: current,
      entries: entries,
      workplaceId: workplaceId,
    );
    for (final plan in insertPlans) {
      await _insertEntryAtPosition(plan.entry, plan.queuePosition);
    }
    if (insertPlans.isNotEmpty) {
      await loadPositionsForWorkplace(workplaceId);
    }
  }

  Future<void> _insertEntryAtPosition(
    WorkplaceQueueEntry entry,
    int queuePosition,
  ) async {
    try {
      await _ensureAuthed();
      await _sb.from(_positionsTable).insert(entry.toInsertMap(queuePosition));
    } catch (e) {
      debugPrint(
        '⚠️ Failed to append workplace queue entry "${entry.queueKey}": $e',
      );
    }
  }

  /// Записывает новые номера очереди ОДНИМ запросом.
  ///
  /// Раньше здесь шёл цикл `update ... eq(id)` — по запросу на строку. На
  /// Флексопечати это 189 запросов подряд, на Упаковке 220, и каждый из них
  /// realtime-подписка возвращала обратно в приложение: пока перестановка
  /// дописывалась, список несколько раз перечитывал наполовину обновлённую
  /// таблицу и перетасовывался на глазах. Прерывание на середине (уход с
  /// экрана, обрыв сети) оставляло очередь частью в новом порядке, частью в
  /// старом — та же «вакханалия» уже навсегда.
  ///
  /// upsert по первичному ключу — одна операция: либо применились все
  /// номера, либо ни одного.
  Future<void> _writePositions(List<WorkplaceQueuePosition> changes) async {
    if (changes.isEmpty) return;
    await _ensureAuthed();
    final now = DateTime.now().toUtc().toIso8601String();
    await _sb.from(_positionsTable).upsert([
      for (final position in changes)
        {
          'id': position.id,
          'workplace_id': position.workplaceId.trim(),
          if ((position.taskId ?? '').trim().isNotEmpty)
            'task_id': position.taskId!.trim(),
          'order_id': position.orderId.trim(),
          'stage_id': position.stageId.trim(),
          if ((position.stageGroupKey ?? '').trim().isNotEmpty)
            'stage_group_key': position.stageGroupKey!.trim(),
          'queue_position': position.queuePosition,
          'updated_at': now,
        },
    ]);
  }

  Future<void> normalizePositions({required String workplaceId}) async {
    final normalized = _normalizeWorkplaceId(workplaceId);
    if (normalized.isEmpty) return;
    final positions = await loadPositionsForWorkplace(normalized);
    final changes = <WorkplaceQueuePosition>[];
    for (var i = 0; i < positions.length; i++) {
      final expected = i + 1;
      if (positions[i].queuePosition == expected) continue;
      changes.add(WorkplaceQueuePosition(
        id: positions[i].id,
        workplaceId: positions[i].workplaceId,
        taskId: positions[i].taskId,
        orderId: positions[i].orderId,
        stageId: positions[i].stageId,
        stageGroupKey: positions[i].stageGroupKey,
        queuePosition: expected,
      ));
    }
    if (changes.isEmpty) return;
    await _writePositions(changes);
    await loadPositionsForWorkplace(normalized);
  }

  Future<void> saveWorkplaceReorder(
    Iterable<WorkplaceQueueEntry> orderedEntries, {
    required String workplaceId,
  }) async {
    await applyVisibleTaskReorder(
      workplaceId: workplaceId,
      orderedKeys: orderedEntries
          .map((entry) => WorkplaceQueueItemKey.fromEntry(entry))
          .toList(growable: false),
    );
  }

  /// Applies the visible task/stage order for one workplace and rewrites only
  /// that workplace's queue positions to a normalized 1-based sequence.
  Future<void> applyVisibleTaskReorder({
    required String workplaceId,
    required List<WorkplaceQueueItemKey> orderedKeys,
  }) async {
    final normalized = _normalizeWorkplaceId(workplaceId);
    if (normalized.isEmpty) return;
    final visibleKeys = <WorkplaceQueueItemKey>[];
    final seen = <String>{};
    for (final key in orderedKeys) {
      if (_normalizeWorkplaceId(key.workplaceId) != normalized) continue;
      if (key.orderId.trim().isEmpty || key.stageId.trim().isEmpty) continue;
      if (!seen.add(key.semanticKey)) continue;
      visibleKeys.add(key);
    }
    if (visibleKeys.isEmpty) return;

    await loadPositionsForWorkplace(normalized);
    for (final key in visibleKeys) {
      await ensureEntryAtTail(key.toEntry());
    }
    final current = positionsForWorkplace(normalized);
    final nextKeys = WorkplaceQueuePositionPlanner.reorderedQueueKeys(
      current: current,
      orderedKeys: visibleKeys,
      workplaceId: normalized,
    );
    // Номер получает КАЖДАЯ строка рабочего места, без исключений — см.
    // WorkplaceQueuePositionPlanner.renumber.
    final renumbered = WorkplaceQueuePositionPlanner.renumber(
      current: current,
      nextKeys: nextKeys,
    );

    // Apply the new order in memory before the network roundtrip. Without this
    // optimistic update the next build can re-render the old queue and make a
    // successful drag look like it was ignored until realtime/polling catches up.
    _applyLocalRenumber(workplaceId: normalized, renumbered: renumbered);

    final changes = <WorkplaceQueuePosition>[];
    final currentById = {for (final position in current) position.id: position};
    for (final position in renumbered) {
      final before = currentById[position.id];
      if (before != null &&
          before.hasQueuePosition &&
          before.queuePosition == position.queuePosition) {
        continue;
      }
      changes.add(position);
    }

    try {
      await _writePositions(changes);
    } catch (_) {
      await loadPositionsForWorkplace(normalized);
      rethrow;
    }
    await loadPositionsForWorkplace(normalized);
  }

  /// Отражает пересчитанные номера в памяти до похода в сеть: без этого
  /// следующая перерисовка показала бы прежний порядок, и удачное
  /// перетаскивание выглядело бы как проигнорированное.
  void _applyLocalRenumber({
    required String workplaceId,
    required List<WorkplaceQueuePosition> renumbered,
  }) {
    final currentMap = _positionsByWorkplace[workplaceId];
    if (currentMap == null || currentMap.isEmpty) return;
    final byId = {
      for (final entry in currentMap.entries) entry.value.id: entry.key,
    };
    var changed = false;
    final updated = Map<String, WorkplaceQueuePosition>.from(currentMap);
    for (final position in renumbered) {
      // Ключ карты — тот, под которым строка уже лежит: запись под чужим
      // ключом плодила бы в памяти второй элемент рядом со старым.
      final mapKey = byId[position.id];
      if (mapKey == null) continue;
      final before = updated[mapKey];
      if (before != null &&
          before.hasQueuePosition &&
          before.queuePosition == position.queuePosition) {
        continue;
      }
      updated[mapKey] = position;
      changed = true;
    }
    if (!changed) return;
    _positionsByWorkplace[workplaceId] = updated;
    notifyListeners();
  }

  /// Legacy/fallback order sync. Manual workplace ordering must use
  /// [syncWorkplaceEntries] instead.
  void syncOrders(Iterable<String> ids, {String groupId = _defaultGroup}) {
    if (_isSyncingOrders) return;
    _isSyncingOrders = true;
    try {
      unawaited(_bootstrapRemoteSync());
      final normalizedIds = <String>[];
      final seen = <String>{};
      for (final raw in ids) {
        final id = _normalizeOrderId(raw);
        if (id.isEmpty || !seen.add(id)) continue;
        normalizedIds.add(id);
      }
      final sequence = _sequenceForGroup(groupId);
      bool changed = false;

      final canonicalSequence = <String>[];
      final canonicalSeen = <String>{};
      for (final raw in sequence) {
        final id = _normalizeOrderId(raw);
        if (id.isEmpty || !canonicalSeen.add(id)) {
          changed = true;
          continue;
        }
        canonicalSequence.add(id);
      }
      if (!_stringListsEqual(canonicalSequence, sequence)) {
        sequence
          ..clear()
          ..addAll(canonicalSequence);
        changed = true;
      }

      final missingIds = <String>[];
      for (final id in normalizedIds) {
        if (!sequence.contains(id)) missingIds.add(id);
      }

      if (missingIds.isNotEmpty) {
        sequence.addAll(missingIds);
        changed = true;
      }

      if (changed) {
        _persistEverywhere(groupId: groupId);
        notifyListeners();
      }
    } finally {
      _isSyncingOrders = false;
    }
  }

  /// Legacy/fallback priority. Manual workplace ordering must use
  /// [priorityOfEntry] instead.
  int priorityOf(String orderId, {String groupId = _defaultGroup}) {
    final normalizedOrderId = _normalizeOrderId(orderId);
    if (normalizedOrderId.isEmpty) return 1 << 30;
    final sequence = _orderSequences[_normalizeGroup(groupId)];
    final idx = sequence?.indexOf(normalizedOrderId) ?? -1;
    if (idx != -1) return idx;
    return 1 << 30;
  }

  /// Legacy/fallback sorting. Manual workplace ordering must use
  /// [getSortedByWorkplaceQueue] instead.
  List<T> getSortedByPriority<T>(
    List<T> items,
    String Function(T) idSelector, {
    String groupId = _defaultGroup,
  }) {
    final indexed = <({T item, int index})>[];
    for (var i = 0; i < items.length; i++) {
      indexed.add((item: items[i], index: i));
    }
    if (indexed.length < 2) return indexed.map((entry) => entry.item).toList();

    final sequence =
        _orderSequences[_normalizeGroup(groupId)] ?? const <String>[];
    final indexById = <String, int>{};
    for (var i = 0; i < sequence.length; i++) {
      final id = _normalizeOrderId(sequence[i]);
      if (id.isEmpty || indexById.containsKey(id)) continue;
      indexById[id] = i;
    }

    indexed.sort((a, b) {
      final aId = _normalizeOrderId(idSelector(a.item));
      final bId = _normalizeOrderId(idSelector(b.item));
      final aPriority = indexById[aId] ?? (1 << 30);
      final bPriority = indexById[bId] ?? (1 << 30);
      final priorityComparison = aPriority.compareTo(bPriority);
      if (priorityComparison != 0) return priorityComparison;
      return a.index.compareTo(b.index);
    });
    return indexed.map((entry) => entry.item).toList();
  }

  List<T> sortByPriority<T>(List<T> items, String Function(T) idSelector,
      {String groupId = _defaultGroup}) {
    return getSortedByPriority(items, idSelector, groupId: groupId);
  }

  /// Legacy/fallback reorder. Manual workplace ordering must use
  /// [saveWorkplaceReorder] instead.
  void applyVisibleReorder(List<String> orderedIds,
      {String groupId = _defaultGroup}) {
    unawaited(_bootstrapRemoteSync());
    if (orderedIds.isEmpty) return;
    final normalizedOrderedIds = <String>[];
    final seen = <String>{};
    for (final raw in orderedIds) {
      final id = _normalizeOrderId(raw);
      if (id.isEmpty || !seen.add(id)) continue;
      normalizedOrderedIds.add(id);
    }
    if (normalizedOrderedIds.isEmpty) return;

    final sequence = _sequenceForGroup(groupId);
    final set = normalizedOrderedIds.toSet();

    for (final id in normalizedOrderedIds) {
      if (!sequence.contains(id)) sequence.add(id);
    }

    final anchor = sequence.indexWhere(set.contains);
    final insertPosition = anchor == -1 ? sequence.length : anchor;

    sequence.removeWhere(set.contains);
    sequence.insertAll(insertPosition, normalizedOrderedIds);

    _persistEverywhere(groupId: groupId);
    notifyListeners();
  }

  bool isHidden(String orderId, {String groupId = _defaultGroup}) {
    final hidden = _hiddenOrders[_normalizeGroup(groupId)];
    if (hidden == null) return false;
    return hidden.contains(_normalizeOrderId(orderId));
  }

  void hideOrder(String orderId, {String groupId = _defaultGroup}) {
    unawaited(_bootstrapRemoteSync());
    final normalizedOrderId = _normalizeOrderId(orderId);
    if (normalizedOrderId.isEmpty) return;
    if (_hiddenForGroup(groupId).add(normalizedOrderId)) {
      _persistEverywhere(groupId: groupId);
      notifyListeners();
    }
  }

  void restoreOrder(String orderId, {String groupId = _defaultGroup}) {
    unawaited(_bootstrapRemoteSync());
    if (_hiddenForGroup(groupId).remove(_normalizeOrderId(orderId))) {
      _persistEverywhere(groupId: groupId);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pollingTimer?.cancel();
    _pollingTimer = null;
    RealtimeSyncService.instance.unregisterOwner(this);
    super.dispose();
  }
}
