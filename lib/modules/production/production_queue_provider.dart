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

  final List<String> _orderSequence = [];
  final Set<String> _hiddenOrders = {};

  bool _loaded = false;

  bool get isReady => _loaded;

  ProductionQueueProvider() {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawSequence = prefs.getString(_prefsKeyOrder);
      if (rawSequence != null && rawSequence.isNotEmpty) {
        final decoded = jsonDecode(rawSequence);
        if (decoded is List) {
          _orderSequence.clear();
          _orderSequence
              .addAll(decoded.map((e) => e?.toString() ?? '').where((e) => e.isNotEmpty));
        }
      }

      final rawHidden = prefs.getStringList(_prefsKeyHidden);
      if (rawHidden != null) {
        _hiddenOrders..clear()..addAll(rawHidden.where((e) => e.trim().isNotEmpty));
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
      await prefs.setString(_prefsKeyOrder, jsonEncode(_orderSequence));
      await prefs.setStringList(_prefsKeyHidden, _hiddenOrders.toList());
    } catch (e) {
      debugPrint('❌ Failed to persist production queue prefs: $e');
    }
  }

  /// Добавляем недостающие id и удаляем отсутствующие в [ids].
  void syncOrders(Iterable<String> ids) {
    final set = ids.where((e) => e.trim().isNotEmpty).toSet();
    bool changed = false;

    for (final id in set) {
      if (!_orderSequence.contains(id)) {
        _orderSequence.add(id);
        changed = true;
      }
    }

    final toRemove = _orderSequence.where((id) => !set.contains(id)).toList();
    if (toRemove.isNotEmpty) {
      _orderSequence.removeWhere((id) => toRemove.contains(id));
      _hiddenOrders.removeWhere((id) => toRemove.contains(id));
      changed = true;
    }

    if (changed) {
      _persist();
      notifyListeners();
    }
  }

  /// Возвращает приоритет (индекс) заказа. Новые id получают самый низкий
  /// приоритет (в конец списка).
  int priorityOf(String orderId) {
    final idx = _orderSequence.indexOf(orderId);
    if (idx != -1) return idx;
    _orderSequence.add(orderId);
    _persist();
    return _orderSequence.length - 1;
  }

  /// Сортирует заказы по сохранённой очереди.
  List<T> sortByPriority<T>(List<T> items, String Function(T) idSelector) {
    final copy = [...items];
    copy.sort((a, b) => priorityOf(idSelector(a)).compareTo(priorityOf(idSelector(b))));
    return copy;
  }

  /// Переставляет видимые заказы, сохраняя положение остальных.
  void applyVisibleReorder(List<String> orderedIds) {
    if (orderedIds.isEmpty) return;
    final set = orderedIds.toSet();

    for (final id in orderedIds) {
      if (!_orderSequence.contains(id)) {
        _orderSequence.add(id);
      }
    }

    final anchor = _orderSequence.indexWhere(set.contains);
    final insertPosition = anchor == -1 ? _orderSequence.length : anchor;

    _orderSequence.removeWhere(set.contains);
    _orderSequence.insertAll(insertPosition, orderedIds);

    _persist();
    notifyListeners();
  }

  bool isHidden(String orderId) => _hiddenOrders.contains(orderId);

  void hideOrder(String orderId) {
    if (_hiddenOrders.add(orderId)) {
      _persist();
      notifyListeners();
    }
  }

  void restoreOrder(String orderId) {
    if (_hiddenOrders.remove(orderId)) {
      _persist();
      notifyListeners();
    }
  }
}
