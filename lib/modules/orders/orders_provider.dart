// lib/modules/orders/orders_provider.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'material_model.dart';
import 'order_model.dart';
import 'product_model.dart';

class OrdersProvider with ChangeNotifier {
  final SupabaseClient _supabase = Supabase.instance.client;

  final List<OrderModel> _orders = [];
  List<OrderModel> get orders => List.unmodifiable(_orders);

  // Realtime channel for listening to order changes.
  RealtimeChannel? _ordersChannel;

  OrdersProvider() {
    _listenToOrders();
  }

  // ===== AUTH =====
  Future<void> _ensureAuthed() async {
    final auth = _supabase.auth;
    if (auth.currentUser == null) {
      try {
        // Supabase supports anonymous sign-in if enabled in your project.
        await auth.signInAnonymously();
      } catch (_) {
        // Если анонимная аутентификация выключена — просто продолжаем.
        // Для чтения у вас должна быть RLS-политика на anon.
      }
    }
  }

  // ===== DATA LOAD =====
  Future<void> refresh() async {
    try {
      await _ensureAuthed();
      final res = await _supabase
          .from('orders')
          .select()
          .order('created_at', ascending: false);

      final rows = (res as List).cast<Map<String, dynamic>>();
      _orders
        ..clear()
        ..addAll(rows.map((row) => OrderModel.fromMap(row)));
      notifyListeners();
    } catch (e, st) {
      debugPrint('❌ refresh orders error: $e\n$st');
    }
  }

  // ===== REALTIME =====
  void _listenToOrders() {
    // Remove previous channel if any
    if (_ordersChannel != null) {
      _supabase.removeChannel(_ordersChannel!);
      _ordersChannel = null;
    }

    // Initial fetch
    refresh();

    // Subscribe to realtime changes in the dedicated 'orders' table
    _ordersChannel = _supabase
        .channel('orders_changes')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'orders',
          callback: (payload) async => refresh(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'orders',
          callback: (payload) async => refresh(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'orders',
          callback: (payload) async => refresh(),
        )
        .subscribe();
  }

  @override
  void dispose() {
    if (_ordersChannel != null) {
      _supabase.removeChannel(_ordersChannel!);
      _ordersChannel = null;
    }
    super.dispose();
  }

  // ===== CRUD =====

  /// Добавляет готовый заказ (оптимистично) и пишет в таблицу `orders`.
  Future<void> addOrder(OrderModel order) async {
    await _ensureAuthed();

    // Optimistic insert
    _orders.add(order);
    notifyListeners();

    try {
      final inserted = await _supabase
          .from('orders')
          .insert(order.toMap())
          .select()
          .single() as Map<String, dynamic>;

      final newOrder = OrderModel.fromMap(inserted);
      final idx = _orders.indexWhere((o) => o.id == order.id);
      if (idx != -1) {
        _orders[idx] = newOrder;
      } else {
        _orders.add(newOrder);
      }
      notifyListeners();

      // Log creation (best effort)
      await _logOrderEvent(newOrder.id, 'Создание', 'Создан заказ');
    } catch (e, st) {
      // Rollback optimistic change
      _orders.removeWhere((o) => o.id == order.id);
      notifyListeners();
      debugPrint('❌ addOrder error: $e\n$st');
    }
  }

  /// Создаёт заказ — id возвращает БД. Возвращает созданную модель или null при ошибке.
  Future<OrderModel?> createOrder({
    String manager = '',
    required String customer,
    required DateTime orderDate,
    DateTime? dueDate,
    required ProductModel product,
    List<String> additionalParams = const [],
    String handle = '-',
    String cardboard = 'нет',
    MaterialModel? material,
    double makeready = 0,
    double val = 0,
    String? pdfUrl,
    String? stageTemplateId,
    bool contractSigned = false,
    bool paymentDone = false,
    String comments = '',
    String status = 'newOrder',
    String? assignmentId,
    bool assignmentCreated = false,
  }) async {
    await _ensureAuthed();

    // Local temp id for optimistic UI
    final tempLocalId = 'local-${DateTime.now().microsecondsSinceEpoch}';
    final localOrder = OrderModel(
      id: tempLocalId,
      manager: manager,
      customer: customer,
      orderDate: orderDate,
      dueDate: dueDate,
      product: product,
      additionalParams: additionalParams,
      handle: handle,
      cardboard: cardboard,
      material: material,
      makeready: makeready,
      val: val,
      pdfUrl: pdfUrl,
      stageTemplateId: stageTemplateId,
      contractSigned: contractSigned,
      paymentDone: paymentDone,
      comments: comments,
      status: status,
      assignmentId: assignmentId,
      assignmentCreated: assignmentCreated,
    );

    // Optimistic add
    _orders.add(localOrder);
    notifyListeners();

    try {
      final inserted = await _supabase
          .from('orders')
          .insert(localOrder.toMap()..remove('id')) // let DB generate id
          .select()
          .single() as Map<String, dynamic>;

      final created = OrderModel.fromMap(inserted);

      // Replace optimistic row
      final idx = _orders.indexWhere((o) => o.id == tempLocalId);
      if (idx != -1) _orders[idx] = created;
      notifyListeners();

      // Log creation (best effort)
      await _logOrderEvent(created.id, 'Создание', 'Создан заказ');
      return created;
    } catch (e, st) {
      // Rollback
      _orders.removeWhere((o) => o.id == tempLocalId);
      notifyListeners();
      debugPrint('❌ createOrder error: $e\n$st');

      await _applyPaperWriteoffFromOrder(localOrder);
      return null;
    }
  }

  /// Обновляет существующий заказ по ID (оптимистично).
  Future<void> updateOrder(OrderModel updated) async {
    await _ensureAuthed();

    final index = _orders.indexWhere((o) => o.id == updated.id);
    if (index == -1) return;

    final prev = _orders[index];
    _orders[index] = updated; // optimistic
    notifyListeners();

    try {
      await _supabase
          .from('orders')
          .update(updated.toMap()..remove('id'))
          .eq('id', updated.id);

      await _logOrderEvent(updated.id, 'Обновление', 'Изменён заказ');
    } catch (e, st) {
      _orders[index] = prev; // rollback
      notifyListeners();
      debugPrint('❌ updateOrder error: $e\n$st');
    }
  }

  /// Удаляет заказ по идентификатору (оптимистично).
  Future<void> deleteOrder(String id) async {
    await _ensureAuthed();

    final index = _orders.indexWhere((o) => o.id == id);
    if (index == -1) return;

    final removed = _orders.removeAt(index);
    notifyListeners();

    try {
      await _supabase.from('orders').delete().eq('id', id);
      // Историю удалять не обязательно — это след.
      await _logOrderEvent(id, 'Удаление', 'Удалён заказ');
    } catch (e, st) {
      // rollback
      _orders.insert(index, removed);
      notifyListeners();
      debugPrint('❌ deleteOrder error: $e\n$st');
    }
  }

  // ===== HISTORY =====

  Future<void> _logOrderEvent(
    String orderId,
    String eventType,
    String description, {
    String? userId,
  }) async {
    try {
      await _supabase.from('order_events').insert({
        'order_id': orderId,
        'event_type': eventType,
        'description': description,
        if (userId != null) 'user_id': userId,
      });
    } catch (e, st) {
      // Non-fatal
      debugPrint('❌ logOrderEvent error: $e\n$st');
    }
  }

  /// Возвращает список событий истории по идентификатору заказа.
  Future<List<Map<String, dynamic>>> fetchOrderHistory(String orderId) async {
    DateTime? _parseTimestamp(dynamic value) {
      if (value == null) return null;
      if (value is int) {
        if (value > 2000000000) {
          return DateTime.fromMillisecondsSinceEpoch(value);
        }
        return DateTime.fromMillisecondsSinceEpoch(value * 1000);
      }
      if (value is num) {
        final int intValue = value.toInt();
        return _parseTimestamp(intValue);
      }
      if (value is String) {
        if (value.isEmpty) return null;
        final parsedInt = int.tryParse(value);
        if (parsedInt != null) return _parseTimestamp(parsedInt);
        return DateTime.tryParse(value);
      }
      if (value is DateTime) return value;
      return null;
    }

    double? _extractQuantity(String type, String text) {
      const trackedTypes = {'quantity_done', 'quantity_team_total', 'quantity_share'};
      if (!trackedTypes.contains(type)) return null;
      final normalized = text.replaceAll(',', '.');
      final match = RegExp(r'-?[0-9]+(?:\.[0-9]+)?').firstMatch(normalized);
      if (match != null) {
        return double.tryParse(match.group(0)!);
      }
      return double.tryParse(normalized.trim());
    }

    String? _stringOrNull(dynamic value) {
      if (value == null) return null;
      final String stringValue = value.toString();
      return stringValue.trim().isEmpty ? null : stringValue;
    }

    try {
      final List<Map<String, dynamic>> combined = [];

      final eventRows = await _supabase
          .from('order_events')
          .select()
          .eq('order_id', orderId)
          .order('created_at');

      if (eventRows is List) {
        for (final raw in eventRows) {
          if (raw is! Map) continue;
          final map = Map<String, dynamic>.from(raw as Map);
          final DateTime? ts =
              _parseTimestamp(map['created_at'] ?? map['timestamp'] ?? map['inserted_at']);
          combined.add({
            'source': 'order_event',
            'timestamp': ts?.millisecondsSinceEpoch,
            'event_type': _stringOrNull(map['event_type']) ?? '',
            'description':
                _stringOrNull(map['description']) ?? _stringOrNull(map['message']) ?? '',
            'user_id': _stringOrNull(map['user_id']),
            'payload': map['payload'],
          });
        }
      }

      final taskRows = await _supabase
          .from('tasks')
          .select('id, stage_id, comments')
          .eq('order_id', orderId);

      if (taskRows is List) {
        for (final raw in taskRows) {
          if (raw is! Map) continue;
          final map = Map<String, dynamic>.from(raw as Map);
          final String? stageId = _stringOrNull(map['stage_id'] ?? map['stageId']);
          final commentsData = map['comments'];
          final List<Map<String, dynamic>> commentsList = [];

          if (commentsData is List) {
            for (final item in commentsData) {
              if (item is Map) {
                commentsList.add(Map<String, dynamic>.from(item));
              }
            }
          } else if (commentsData is Map) {
            commentsData.forEach((_, value) {
              if (value is Map) {
                commentsList.add(Map<String, dynamic>.from(value));
              }
            });
          }

          for (final comment in commentsList) {
            final String type = _stringOrNull(comment['type']) ?? '';
            final String text = _stringOrNull(comment['text']) ?? '';
            final DateTime? ts = _parseTimestamp(comment['timestamp']);
            combined.add({
              'source': 'task_comment',
              'timestamp': ts?.millisecondsSinceEpoch,
              'event_type': type,
              'description': text,
              'user_id': _stringOrNull(comment['userId']),
              'stage_id': stageId,
              'quantity': _extractQuantity(type, text),
            });
          }
        }
      }

      combined.sort((a, b) {
        final int tsA = (a['timestamp'] as int?) ?? 0;
        final int tsB = (b['timestamp'] as int?) ?? 0;
        return tsA.compareTo(tsB);
      });

      return combined;
    } catch (e, st) {
      debugPrint('❌ fetchOrderHistory error: $e\n$st');
      return [];
    }
  }

  // ===== STOCK (WAREHOUSE) INTEGRATION =====

  /// Списание бумаги по данным заказа (если материал = бумага и указан tmcId).
  Future<void> _applyPaperWriteoffFromOrder(OrderModel order) async {
    try {
      final pm = order.product.toMap();
      final String? tmcId = (pm['tmcId'] ??
          pm['tmc_id'] ??
          pm['materialId'] ??
          pm['material_id']) as String?;
      final dynamic qRaw = (pm['quantity'] ?? pm['qty'] ?? pm['count']);
      final double qty =
          (qRaw is num) ? qRaw.toDouble() : double.tryParse('$qRaw') ?? 0.0;

      if (tmcId == null || qty <= 0) return;

      // вызываем writeoff для типа paper по ID
      await _supabase.rpc('writeoff', params: {
        'type': 'paper',
        'item': tmcId,
        'qty': qty,
        'reason': 'Списание при создании заказа',
        'by_name': 'OrdersProvider'
      });
    } catch (e) {
      // если недостаточно остатков — пробрасываем, чтобы показать ошибку пользователю
      rethrow;
    }
  }

  Future<void> applyStockOnFulfillment(OrderModel order) async {
    await _applyStockDelta(order, isShipment: true);
  }

  Future<void> revertStockOnCancel(OrderModel order) async {
    await _applyStockDelta(order, isShipment: false);
  }

  Future<void> _applyStockDelta(
    OrderModel order, {
    required bool isShipment,
  }) async {
    final pm = order.product.toMap();

    final String? tmcId = (pm['tmcId'] ??
        pm['tmc_id'] ??
        pm['materialId'] ??
        pm['material_id']) as String?;

    final dynamic qRaw = (pm['quantity'] ?? pm['qty'] ?? pm['count']);
    final double qty =
        (qRaw is num) ? qRaw.toDouble() : double.tryParse('$qRaw') ?? 0.0;

    if (tmcId == null || qty <= 0) return;

    final delta = isShipment ? -qty : qty;
    try {
      await _supabase.rpc('materials_increment', params: {
        'p_id': tmcId,
        'p_delta': delta,
      });
    } catch (e) {
      debugPrint('⚠️ stock delta failed for $tmcId: $e');
    }
  }

  // ===== HELPERS =====

  /// Генерирует человекочитаемый номер заказа типа ORD-YYYY-N.
  /// Храните его в поле модели (не в PK).
  String generateHumanNumber({int? sequence}) {
    final year = DateTime.now().year;
    final n = sequence ?? (_orders.length + 1);
    return 'ORD-$year-$n';
  }

  /// Генерирует человекочитаемый номер задания вида `ZK-YYYY-NNN`.
  /// Храните его в `assignmentId` модели заказа.
  String generateAssignmentId({String prefix = 'ZK'}) {
    final year = DateTime.now().year;
    int maxSeq = 0;
    for (final o in _orders) {
      final id = o.assignmentId;
      if (id == null || id.isEmpty) continue;
      if (!id.startsWith('$prefix-$year-')) continue;
      final parts = id.split('-');
      if (parts.length < 3) continue;
      final seq = int.tryParse(parts.last) ?? 0;
      if (seq > maxSeq) maxSeq = seq;
    }
    final next = (maxSeq + 1).toString().padLeft(3, '0');
    return '$prefix-$year-$next';
  }

  /// Генерирует читаемый номер заказа: `ЗК-YYYY.MM.DD-N` (N — порядковый за день).
  Future<String> generateReadableOrderId(
    DateTime date, {
    String prefix = 'ЗК',
  }) async {
    await _ensureAuthed();
    final yyyy = date.year.toString().padLeft(4, '0');
    final mm = date.month.toString().padLeft(2, '0');
    final dd = date.day.toString().padLeft(2, '0');
    final datePrefix = '$prefix-$yyyy.$mm.$dd-';
    int maxSeq = 0;

    // Смотрим уже загруженные заказы в провайдере
    for (final o in _orders) {
      final aid = o.assignmentId ?? '';
      if (!aid.startsWith(datePrefix)) continue;
      final parts = aid.split('-');
      if (parts.length < 3) continue;
      final seq = int.tryParse(parts.last) ?? 0;
      if (seq > maxSeq) maxSeq = seq;
    }

    // Дополнительно проверим по БД на всякий случай
    try {
      final rows = await _supabase
          .from('orders')
          .select('assignment_id')
          .ilike('assignment_id', '${datePrefix}%');

      for (final r in (rows as List)) {
        final aid = (r['assignment_id'] ?? '').toString();
        if (!aid.startsWith(datePrefix)) continue;
        final parts = aid.split('-');
        if (parts.length < 3) continue;
        final seq = int.tryParse(parts.last) ?? 0;
        if (seq > maxSeq) maxSeq = seq;
      }
    } catch (_) {}

    final next = (maxSeq + 1).toString();
    return '$datePrefix$next';
  }
}
