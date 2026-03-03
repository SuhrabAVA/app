import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/app_auth.dart';

/// Отвечает за ручную очередь производственных заказов и скрытые записи.
///
/// Очередь хранится локально (SharedPreferences), чтобы соблюсти порядок
/// отображения и сортировки задач между сессиями. Чем ниже индекс — тем выше
/// приоритет заказа.
class ProductionQueueProvider with ChangeNotifier {
  static const _prefsKeyOrder = 'production_order_sequence';
  static const _prefsKeyHidden = 'production_hidden_orders';
  static const _defaultGroup = 'global';
  static const _remoteTable = 'production_queue_state';

  final Map<String, List<String>> _orderSequences = {};
  final Map<String, Set<String>> _hiddenOrders = {};
  final SupabaseClient _sb = Supabase.instance.client;
  RealtimeChannel? _channel;

  bool _loaded = false;

  bool get isReady => _loaded;

  ProductionQueueProvider() {
    _init();
  }

  Future<void> _init() async {
    await _loadLocal();
    await _loadRemote();
    await _subscribeRemote();
  }

  String _normalizeGroup(String groupId) {
    final trimmed = groupId.trim();
    return trimmed.isEmpty ? _defaultGroup : trimmed;
  }

  String _normalizeOrderId(String orderId) => orderId.trim();

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
          _hiddenOrders[_defaultGroup] =
              decoded.map((e) => e?.toString() ?? '').where((e) => e.isNotEmpty).toSet();
        } else if (decoded is Map) {
          decoded.forEach((key, value) {
            if (value is List) {
              _hiddenOrders[key.toString()] =
                  value.map((e) => e?.toString() ?? '').where((e) => e.isNotEmpty).toSet();
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
    } catch (_) {
      // fallback for setups with anon access
    }
    final auth = _sb.auth;
    if (auth.currentUser != null) return;
    try {
      await auth.signInAnonymously();
    } catch (_) {}
  }

  List<String> _decodeStringList(dynamic raw) {
    if (raw is! List) return const <String>[];
    return raw
        .map((e) => e?.toString().trim() ?? '')
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> _loadRemote() async {
    try {
      await _ensureAuthed();
      final raw = await _sb
          .from(_remoteTable)
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
        await _pushLocalStateToRemote();
        return;
      }

      _orderSequences
        ..clear()
        ..addAll(nextSequences);
      _hiddenOrders
        ..clear()
        ..addAll(nextHidden);

      await _persist();
      notifyListeners();
    } catch (e) {
      debugPrint('⚠️ Failed to load production queue from Supabase: $e');
    }
  }

  Future<void> _subscribeRemote() async {
    try {
      await _ensureAuthed();
      _channel?.unsubscribe();
      if (_channel != null) {
        _sb.removeChannel(_channel!);
      }
      _channel = _sb
          .channel('realtime:$_remoteTable')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: _remoteTable,
            callback: (_) async {
              await _loadRemote();
            },
          )
          .subscribe();
    } catch (e) {
      debugPrint('⚠️ Failed to subscribe production queue realtime: $e');
    }
  }

  Future<void> _pushLocalStateToRemote() async {
    for (final entry in _orderSequences.entries) {
      await _upsertRemoteGroup(entry.key);
    }
    for (final groupId in _hiddenOrders.keys) {
      if (_orderSequences.containsKey(groupId)) continue;
      await _upsertRemoteGroup(groupId);
    }
  }

  Future<void> _upsertRemoteGroup(String groupId) async {
    try {
      await _ensureAuthed();
      await _sb.from(_remoteTable).upsert({
        'group_id': _normalizeGroup(groupId),
        'order_sequence': _sequenceForGroup(groupId),
        'hidden_order_ids': _hiddenForGroup(groupId).toList(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      debugPrint('⚠️ Failed to upsert production queue group "$groupId": $e');
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
      await _upsertRemoteGroup(groupId);
      return;
    }
    await _pushLocalStateToRemote();
  }

  /// Добавляем недостающие id и удаляем отсутствующие в [ids].
  void syncOrders(Iterable<String> ids, {String groupId = _defaultGroup}) {
    final normalizedIds = <String>[];
    final seen = <String>{};
    for (final raw in ids) {
      final id = _normalizeOrderId(raw);
      if (id.isEmpty || !seen.add(id)) continue;
      normalizedIds.add(id);
    }
    final set = normalizedIds.toSet();
    final sequence = _sequenceForGroup(groupId);
    final hidden = _hiddenForGroup(groupId);
    bool changed = false;

    // Keep stored sequence canonical to avoid duplicates caused by whitespace
    // variants from different data sources.
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
    if (canonicalSequence.length != sequence.length) {
      sequence
        ..clear()
        ..addAll(canonicalSequence);
    }

    for (final id in normalizedIds) {
      if (!sequence.contains(id)) {
        sequence.add(id);
        changed = true;
      }
    }

    final toRemove = sequence.where((id) => !set.contains(id)).toList();
    if (toRemove.isNotEmpty) {
      sequence.removeWhere((id) => toRemove.contains(id));
      hidden.removeWhere((id) => toRemove.contains(id));
      changed = true;
    }

    if (changed) {
      _persistEverywhere(groupId: groupId);
      notifyListeners();
    }
  }

  /// Возвращает приоритет (индекс) заказа. Новые id получают самый низкий
  /// приоритет (в конец списка).
  int priorityOf(String orderId, {String groupId = _defaultGroup}) {
    final normalizedOrderId = _normalizeOrderId(orderId);
    if (normalizedOrderId.isEmpty) {
      return 1 << 30;
    }
    final sequence = _sequenceForGroup(groupId);
    final idx = sequence.indexOf(normalizedOrderId);
    if (idx != -1) return idx;
    sequence.add(normalizedOrderId);
    return sequence.length - 1;
  }

  /// Сортирует заказы по сохранённой очереди.
  List<T> sortByPriority<T>(List<T> items, String Function(T) idSelector,
      {String groupId = _defaultGroup}) {
    final copy = [...items];
    copy.sort((a, b) =>
        priorityOf(idSelector(a), groupId: groupId).compareTo(priorityOf(idSelector(b), groupId: groupId)));
    return copy;
  }

  /// Переставляет видимые заказы, сохраняя положение остальных.
  void applyVisibleReorder(List<String> orderedIds, {String groupId = _defaultGroup}) {
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
      if (!sequence.contains(id)) {
        sequence.add(id);
      }
    }

    final anchor = sequence.indexWhere(set.contains);
    final insertPosition = anchor == -1 ? sequence.length : anchor;

    sequence.removeWhere(set.contains);
    sequence.insertAll(insertPosition, normalizedOrderedIds);

    _persistEverywhere(groupId: groupId);
    notifyListeners();
  }

  bool isHidden(String orderId, {String groupId = _defaultGroup}) =>
      _hiddenForGroup(groupId).contains(_normalizeOrderId(orderId));

  void hideOrder(String orderId, {String groupId = _defaultGroup}) {
    final normalizedOrderId = _normalizeOrderId(orderId);
    if (normalizedOrderId.isEmpty) return;
    if (_hiddenForGroup(groupId).add(normalizedOrderId)) {
      _persistEverywhere(groupId: groupId);
      notifyListeners();
    }
  }

  void restoreOrder(String orderId, {String groupId = _defaultGroup}) {
    if (_hiddenForGroup(groupId).remove(_normalizeOrderId(orderId))) {
      _persistEverywhere(groupId: groupId);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_channel != null) {
      _channel!.unsubscribe();
      _sb.removeChannel(_channel!);
      _channel = null;
    }
    super.dispose();
  }
}
