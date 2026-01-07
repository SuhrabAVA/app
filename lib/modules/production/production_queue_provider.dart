import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Отвечает за ручную очередь производственных заказов и скрытые записи.
///
/// Очередь хранится локально (SharedPreferences), чтобы соблюсти порядок
/// отображения и сортировки задач между сессиями. Чем ниже индекс — тем выше
/// приоритет заказа.
class ProductionQueueProvider with ChangeNotifier {
  static const _prefsKeyOrder = 'production_order_sequence';
  static const _prefsKeyHidden = 'production_hidden_orders';
  static const _defaultGroup = 'global';

  final Map<String, List<String>> _orderSequences = {};
  final Map<String, Set<String>> _hiddenOrders = {};

  bool _loaded = false;

  bool get isReady => _loaded;

  ProductionQueueProvider() {
    _load();
  }

  String _normalizeGroup(String groupId) {
    final trimmed = groupId.trim();
    return trimmed.isEmpty ? _defaultGroup : trimmed;
  }

  List<String> _sequenceForGroup(String groupId) {
    final key = _normalizeGroup(groupId);
    return _orderSequences.putIfAbsent(key, () => <String>[]);
  }

  Set<String> _hiddenForGroup(String groupId) {
    final key = _normalizeGroup(groupId);
    return _hiddenOrders.putIfAbsent(key, () => <String>{});
  }

  Future<void> _load() async {
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

  /// Добавляем недостающие id и удаляем отсутствующие в [ids].
  void syncOrders(Iterable<String> ids, {String groupId = _defaultGroup}) {
    final set = ids.where((e) => e.trim().isNotEmpty).toSet();
    final sequence = _sequenceForGroup(groupId);
    final hidden = _hiddenForGroup(groupId);
    bool changed = false;

    for (final id in set) {
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
      _persist();
      notifyListeners();
    }
  }

  /// Возвращает приоритет (индекс) заказа. Новые id получают самый низкий
  /// приоритет (в конец списка).
  int priorityOf(String orderId, {String groupId = _defaultGroup}) {
    final sequence = _sequenceForGroup(groupId);
    final idx = sequence.indexOf(orderId);
    if (idx != -1) return idx;
    sequence.add(orderId);
    _persist();
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
    final sequence = _sequenceForGroup(groupId);
    final set = orderedIds.toSet();

    for (final id in orderedIds) {
      if (!sequence.contains(id)) {
        sequence.add(id);
      }
    }

    final anchor = sequence.indexWhere(set.contains);
    final insertPosition = anchor == -1 ? sequence.length : anchor;

    sequence.removeWhere(set.contains);
    sequence.insertAll(insertPosition, orderedIds);

    _persist();
    notifyListeners();
  }

  bool isHidden(String orderId, {String groupId = _defaultGroup}) =>
      _hiddenForGroup(groupId).contains(orderId);

  void hideOrder(String orderId, {String groupId = _defaultGroup}) {
    if (_hiddenForGroup(groupId).add(orderId)) {
      _persist();
      notifyListeners();
    }
  }

  void restoreOrder(String orderId, {String groupId = _defaultGroup}) {
    if (_hiddenForGroup(groupId).remove(orderId)) {
      _persist();
      notifyListeners();
    }
  }
}
