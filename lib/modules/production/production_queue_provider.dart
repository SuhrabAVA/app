import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/app_auth.dart';

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
        if (position.workplaceId.trim() == normalizedWorkplace) position.queueKey,
    };
    final missing = <WorkplaceQueueEntry>[];
    final seen = <String>{};
    for (final entry in entries) {
      if (entry.workplaceId.trim() != normalizedWorkplace) continue;
      if (entry.orderId.trim().isEmpty || entry.stageId.trim().isEmpty) {
        continue;
      }
      if (existingKeys.contains(entry.queueKey)) continue;
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

  static List<String> reorderedKeys({
    required Iterable<WorkplaceQueuePosition> current,
    required Iterable<WorkplaceQueueEntry> orderedEntries,
    required String workplaceId,
  }) {
    final normalizedWorkplace = workplaceId.trim();
    final entries = <WorkplaceQueueEntry>[];
    final seen = <String>{};
    for (final entry in orderedEntries) {
      if (entry.workplaceId.trim() != normalizedWorkplace) continue;
      if (!seen.add(entry.queueKey)) continue;
      entries.add(entry);
    }

    final currentForWorkplace = sortedPositions(current.where(
      (position) => position.workplaceId.trim() == normalizedWorkplace,
    ));
    final orderedKeys = entries.map((entry) => entry.queueKey).toSet();
    return <String>[
      ...entries.map((entry) => entry.queueKey),
      ...currentForWorkplace
          .where((position) => !orderedKeys.contains(position.queueKey))
          .map((position) => position.queueKey),
    ];
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

  String get queueKey => ProductionQueueProvider.queueKeyFor(
        workplaceId: workplaceId,
        taskId: taskId,
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
  static const _defaultGroup = 'global';
  static const _legacyRemoteTable = 'production_queue_state';
  static const _positionsTable = 'workplace_queue_positions';

  final Map<String, List<String>> _orderSequences = {};
  final Map<String, Set<String>> _hiddenOrders = {};
  final Map<String, Map<String, WorkplaceQueuePosition>> _positionsByWorkplace = {};
  final SupabaseClient _sb = Supabase.instance.client;
  RealtimeChannel? _legacyChannel;
  RealtimeChannel? _positionsChannel;
  Future<void>? _remoteBootstrap;
  Timer? _pollingTimer;

  bool _loaded = false;
  bool _isSyncingOrders = false;

  bool get isReady => _loaded;

  ProductionQueueProvider() {
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

  void _startPollingFallback() {
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_loadLegacyRemote());
      unawaited(_loadAllWorkplacePositions());
    });
  }

  Future<void> _init() async {
    await _loadLocal();
    await _loadLegacyRemote();
    await _loadAllWorkplacePositions();
    await _subscribeRemote();
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
    } catch (e) {
      debugPrint('❌ Failed to load production queue prefs: $e');
    }

    _loaded = true;
    notifyListeners();
  }

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
      if (_normalizeOrderId(left[i]) != _normalizeOrderId(right[i])) return false;
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

  bool _legacyRemoteStateMatches(
    Map<String, List<String>> nextSequences,
    Map<String, Set<String>> nextHidden,
  ) {
    if (_orderSequences.length != nextSequences.length ||
        _hiddenOrders.length != nextHidden.length) return false;
    for (final entry in nextSequences.entries) {
      final current = _orderSequences[entry.key];
      if (current == null || !_stringListsEqual(current, entry.value)) return false;
    }
    for (final entry in nextHidden.entries) {
      final current = _hiddenOrders[entry.key];
      if (current == null || !_stringSetsEqual(current, entry.value)) return false;
    }
    return true;
  }

  Future<void> _loadLegacyRemote() async {
    try {
      await _ensureAuthed();
      final raw = await _sb
          .from(_legacyRemoteTable)
          .select('group_id, order_sequence, hidden_order_ids');
      if (raw is! List) return;

      final nextSequences = <String, List<String>>{};
      final nextHidden = <String, Set<String>>{};
      for (final row in raw) {
        if (row is! Map) continue;
        final map = Map<String, dynamic>.from(row as Map);
        final groupId = _normalizeGroup(map['group_id']?.toString() ?? '');
        nextSequences[groupId] = _decodeStringList(map['order_sequence']);
        nextHidden[groupId] = _decodeStringList(map['hidden_order_ids']).toSet();
      }

      if (nextSequences.isEmpty && nextHidden.isEmpty) {
        await _pushLocalStateToLegacyRemote();
        return;
      }
      if (_legacyRemoteStateMatches(nextSequences, nextHidden)) return;

      _orderSequences
        ..clear()
        ..addAll(nextSequences);
      _hiddenOrders
        ..clear()
        ..addAll(nextHidden);

      await _persist();
      notifyListeners();
    } catch (e) {
      debugPrint('⚠️ Failed to load legacy production queue from Supabase: $e');
    }
  }

  Future<void> _loadAllWorkplacePositions() async {
    try {
      await _ensureAuthed();
      final raw = await _sb
          .from(_positionsTable)
          .select('id, workplace_id, task_id, order_id, stage_id, stage_group_key, queue_position')
          .order('workplace_id')
          .order('queue_position');
      if (raw is! List) return;
      final next = <String, Map<String, WorkplaceQueuePosition>>{};
      for (final row in raw) {
        if (row is! Map) continue;
        final position = WorkplaceQueuePosition.fromMap(Map<String, dynamic>.from(row as Map));
        final workplaceId = _normalizeWorkplaceId(position.workplaceId);
        if (workplaceId.isEmpty || position.orderId.trim().isEmpty || position.stageId.trim().isEmpty) continue;
        next.putIfAbsent(workplaceId, () => <String, WorkplaceQueuePosition>{})[position.queueKey] = position;
      }
      _positionsByWorkplace
        ..clear()
        ..addAll(next);
      notifyListeners();
    } catch (e) {
      debugPrint('⚠️ Failed to load workplace queue positions from Supabase: $e');
    }
  }

  Future<List<WorkplaceQueuePosition>> loadPositionsForWorkplace(String workplaceId) async {
    final normalized = _normalizeWorkplaceId(workplaceId);
    if (normalized.isEmpty) return const <WorkplaceQueuePosition>[];
    try {
      await _ensureAuthed();
      final raw = await _sb
          .from(_positionsTable)
          .select('id, workplace_id, task_id, order_id, stage_id, stage_group_key, queue_position')
          .eq('workplace_id', normalized)
          .order('queue_position');
      if (raw is! List) return positionsForWorkplace(normalized);
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
      notifyListeners();
      return positions;
    } catch (e) {
      debugPrint('⚠️ Failed to load workplace queue positions for "$normalized": $e');
      return positionsForWorkplace(normalized);
    }
  }

  List<WorkplaceQueuePosition> positionsForWorkplace(String workplaceId) {
    final values = _positionsByWorkplace[_normalizeWorkplaceId(workplaceId)]?.values.toList() ??
        <WorkplaceQueuePosition>[];
    return WorkplaceQueuePositionPlanner.sortedPositions(values);
  }

  int priorityOfEntry(WorkplaceQueueEntry entry) {
    final workplaceId = _normalizeWorkplaceId(entry.workplaceId);
    if (workplaceId.isEmpty) return 1 << 30;
    return _positionsByWorkplace[workplaceId]?[entry.queueKey]?.queuePosition ?? (1 << 30);
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

  Future<void> _subscribeRemote() async {
    try {
      await _ensureAuthed();
      _legacyChannel?.unsubscribe();
      if (_legacyChannel != null) _sb.removeChannel(_legacyChannel!);
      _legacyChannel = _sb
          .channel('realtime:$_legacyRemoteTable')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: _legacyRemoteTable,
            callback: (_) async => _loadLegacyRemote(),
          )
          .subscribe();

      _positionsChannel?.unsubscribe();
      if (_positionsChannel != null) _sb.removeChannel(_positionsChannel!);
      _positionsChannel = _sb
          .channel('realtime:$_positionsTable')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: _positionsTable,
            callback: (_) async => _loadAllWorkplacePositions(),
          )
          .subscribe();
    } catch (e) {
      debugPrint('⚠️ Failed to subscribe production queue realtime: $e');
    }
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
      debugPrint('⚠️ Failed to upsert legacy production queue group "$groupId": $e');
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

  Future<int> _nextPositionForWorkplace(String workplaceId) async {
    final normalized = _normalizeWorkplaceId(workplaceId);
    final cached = _positionsByWorkplace[normalized]?.values ??
        const <WorkplaceQueuePosition>[];
    var maxPosition = 0;
    for (final item in cached) {
      if (!item.hasQueuePosition) continue;
      if (item.queuePosition > maxPosition) maxPosition = item.queuePosition;
    }
    try {
      final raw = await _sb
          .from(_positionsTable)
          .select('queue_position')
          .eq('workplace_id', normalized);
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
    } catch (_) {}
    return maxPosition + 1;
  }

  Future<void> ensureEntryAtTail(WorkplaceQueueEntry entry) async {
    final workplaceId = _normalizeWorkplaceId(entry.workplaceId);
    if (workplaceId.isEmpty ||
        entry.orderId.trim().isEmpty ||
        entry.stageId.trim().isEmpty) return;
    if (_positionsByWorkplace[workplaceId]?.containsKey(entry.queueKey) == true) return;
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

  Future<void> normalizePositions({required String workplaceId}) async {
    final normalized = _normalizeWorkplaceId(workplaceId);
    if (normalized.isEmpty) return;
    final positions = await loadPositionsForWorkplace(normalized);
    var changed = false;
    for (var i = 0; i < positions.length; i++) {
      final expected = i + 1;
      if (positions[i].queuePosition == expected) continue;
      changed = true;
      await _sb.from(_positionsTable).update({
        'queue_position': expected,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', positions[i].id);
    }
    if (changed) await loadPositionsForWorkplace(normalized);
  }

  Future<void> saveWorkplaceReorder(
    Iterable<WorkplaceQueueEntry> orderedEntries, {
    required String workplaceId,
  }) async {
    final normalized = _normalizeWorkplaceId(workplaceId);
    if (normalized.isEmpty) return;
    final entries = <WorkplaceQueueEntry>[];
    final seen = <String>{};
    for (final entry in orderedEntries) {
      if (_normalizeWorkplaceId(entry.workplaceId) != normalized) continue;
      if (!seen.add(entry.queueKey)) continue;
      entries.add(entry);
    }
    if (entries.isEmpty) return;

    await loadPositionsForWorkplace(normalized);
    for (final entry in entries) {
      await ensureEntryAtTail(entry);
    }
    final current = positionsForWorkplace(normalized);
    final nextKeys = WorkplaceQueuePositionPlanner.reorderedKeys(
      current: current,
      orderedEntries: entries,
      workplaceId: normalized,
    );
    final byKey = {
      for (final position in current) position.queueKey: position,
    };
    for (var i = 0; i < nextKeys.length; i++) {
      final position = byKey[nextKeys[i]];
      if (position == null) continue;
      final nextPosition = i + 1;
      if (position.queuePosition == nextPosition) continue;
      await _sb.from(_positionsTable).update({
        'queue_position': nextPosition,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', position.id);
    }
    await loadPositionsForWorkplace(normalized);
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

    final sequence = _orderSequences[_normalizeGroup(groupId)] ?? const <String>[];
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
  void applyVisibleReorder(List<String> orderedIds, {String groupId = _defaultGroup}) {
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
    _pollingTimer?.cancel();
    _pollingTimer = null;
    if (_legacyChannel != null) {
      _legacyChannel!.unsubscribe();
      _sb.removeChannel(_legacyChannel!);
      _legacyChannel = null;
    }
    if (_positionsChannel != null) {
      _positionsChannel!.unsubscribe();
      _sb.removeChannel(_positionsChannel!);
      _positionsChannel = null;
    }
    super.dispose();
  }
}
