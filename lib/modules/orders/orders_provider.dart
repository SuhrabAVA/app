import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'material_model.dart';
import 'order_model.dart';
import 'product_model.dart';
import '../../utils/auth_helper.dart';

class OrdersProvider with ChangeNotifier {
  final SupabaseClient _supabase = Supabase.instance.client;

  final List<OrderModel> _orders = [];
  StreamSubscription<List<Map<String, dynamic>>>? _ordersSub;

  OrdersProvider() {
    _listenToOrders();
  }

  List<OrderModel> get orders => List.unmodifiable(_orders);

  Future<void> refresh() async {
    try {
      final rows = await _supabase.from('orders').select();
      _orders
        ..clear()
        ..addAll(rows.map((row) {
          final map = Map<String, dynamic>.from(row);
          final p = map['product'];
          if (p is String) {
            try {
              map['product'] =
                  p.isEmpty ? <String, dynamic>{} : jsonDecode(p) as Map;
            } catch (_) {
              map['product'] = <String, dynamic>{};
            }
          } else if (p == null) {
            map['product'] = <String, dynamic>{};
          }
          return OrderModel.fromMap(map);
        }));
      notifyListeners();
    } catch (e, st) {
      debugPrint('❌ refresh orders error: $e\n$st');
    }
  }

  // ===== live stream =====
  void _listenToOrders() {
    _ordersSub?.cancel();
    _ordersSub =
        _supabase.from('orders').stream(primaryKey: ['id']).listen((rows) {
      _orders
        ..clear()
        ..addAll(rows.map((row) {
          final map = Map<String, dynamic>.from(row);

          // product в БД — jsonb; подстрахуемся, если пришла строка
          final p = map['product'];
          if (p is String) {
            try {
              map['product'] =
                  p.isEmpty ? <String, dynamic>{} : jsonDecode(p) as Map;
            } catch (_) {
              map['product'] = <String, dynamic>{};
            }
          } else if (p == null) {
            map['product'] = <String, dynamic>{};
          }

          return OrderModel.fromMap(map);
        }));
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _ordersSub?.cancel();
    super.dispose();
  }

  // ===== CRUD =====

  /// Добавляет готовый заказ и сохраняет его в Supabase.
  Future<void> addOrder(OrderModel order) async {
    _orders.add(order); // оптимистично
    notifyListeners();
    try {
      await _supabase.from('orders').insert(order.toMap()).select().single();
    } catch (e, st) {
      _orders.removeWhere((o) => o.id == order.id); // откат
      notifyListeners();
      debugPrint('❌ addOrder error: $e\n$st');
      // НЕ бросаем дальше, чтобы не валить приложение
    }
  }

  /// Создаёт заказ с ID, резервируемым на сервере (RPC reserve_order_id), и сохраняет его.
  Future<OrderModel?> createOrder({
    String manager = '',
    required String customer,
    required DateTime orderDate,
    required DateTime dueDate,
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
  }) async {
    // 1) Берём уникальный id на сервере
    final reservedId = await _reserveOrderId();

    // Собираем заказ
    OrderModel newOrder = OrderModel(
      id: reservedId,
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
      status: 'newOrder',
      assignmentId: null,
      assignmentCreated: false,
    );

    _orders.add(newOrder); // оптимистично
    notifyListeners();

    Future<Map<String, dynamic>> _tryInsert(OrderModel o) async {
      final inserted =
          await _supabase.from('orders').insert(o.toMap()).select().single();
      return Map<String, dynamic>.from(inserted);
    }

    try {
      Map<String, dynamic> inserted;
      try {
        inserted = await _tryInsert(newOrder);
      } on PostgrestException catch (e) {
        // если вдруг конфликт — резервируем другой id и повторяем
        if (e.code == '23505') {
          final nextId = await _reserveOrderId();
          final updatedOrder = OrderModel(
            id: nextId,
            manager: newOrder.manager,
            customer: newOrder.customer,
            orderDate: newOrder.orderDate,
            dueDate: newOrder.dueDate,
            product: newOrder.product,
            additionalParams: newOrder.additionalParams,
            handle: newOrder.handle,
            cardboard: newOrder.cardboard,
            material: newOrder.material,
            makeready: newOrder.makeready,
            val: newOrder.val,
            pdfUrl: newOrder.pdfUrl,
            stageTemplateId: newOrder.stageTemplateId,
            contractSigned: newOrder.contractSigned,
            paymentDone: newOrder.paymentDone,
            comments: newOrder.comments,
            status: newOrder.status,
            assignmentId: newOrder.assignmentId,
            assignmentCreated: newOrder.assignmentCreated,
          );

          final idx = _orders.indexWhere((x) => x.id == newOrder.id);
          if (idx != -1) {
            _orders[idx] = updatedOrder;
            notifyListeners();
          }
          newOrder = updatedOrder;
          inserted = await _tryInsert(updatedOrder);
        } else {
          rethrow;
        }
      }

      // синхронизация с тем, что вернула БД
      final created = OrderModel.fromMap(inserted);
      final idx = _orders.indexWhere((o) => o.id == newOrder.id);
      if (idx != -1) {
        _orders[idx] = created;
        notifyListeners();
      }

      // Логируем создание заказа (без падений)
      await _logOrderEvent(created.id, 'Создание', 'Создан заказ');
      return created;
    } catch (e, st) {
      _orders.removeWhere((o) => o.id == newOrder.id);
      notifyListeners();
      debugPrint('❌ createOrder error: $e\n$st');
      // НЕ rethrow — чтобы не убивать поток/экран
      return null;
    }
  }

  /// Обновляет существующий заказ по ID.
  Future<void> updateOrder(OrderModel updated) async {
    final index = _orders.indexWhere((o) => o.id == updated.id);
    if (index == -1) return;

    final prev = _orders[index];
    _orders[index] = updated; // оптимистично
    notifyListeners();

    try {
      final _ = await _supabase
          .from('orders')
          .update(updated.toMap())
          .eq('id', updated.id)
          .select()
          .maybeSingle(); // не бросает, если 0 строк

      await _logOrderEvent(updated.id, 'Обновление', 'Изменён заказ');
    } catch (e, st) {
      _orders[index] = prev; // откат
      notifyListeners();
      debugPrint('❌ updateOrder error: $e\n$st');
    }
  }

  /// Удаляет заказ по идентификатору.
  Future<void> deleteOrder(String id) async {
    final index = _orders.indexWhere((o) => o.id == id);
    if (index == -1) return;

    final removed = _orders.removeAt(index);
    notifyListeners();

    try {
      await _supabase.from('orders').delete().eq('id', removed.id);
    } catch (e, st) {
      _orders.insert(index, removed); // откат
      notifyListeners();
      debugPrint('❌ deleteOrder error: $e\n$st');
    }
  }

  // ===== История заказов =====

  Future<void> _logOrderEvent(
    String orderId,
    String eventType,
    String description, {
    String? user,
  }) async {
    final rawUser = user ?? AuthHelper.currentUserId;

    bool _looksLikeUuid(String s) {
      final re = RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
      );
      return re.hasMatch(s);
    }

    final payload = <String, dynamic>{
      'order_id': orderId,
      'event_type': eventType,
      'description': description,
    };

    if (rawUser != null && rawUser.isNotEmpty) {
      if (_looksLikeUuid(rawUser)) {
        payload['user'] = rawUser; // только UUID
      } else {
        payload['actor_role'] = rawUser; // роли/строки сюда
      }
    }

    debugPrint('ℹ️ order_history payload: $payload');

    try {
      await _supabase.from('order_history').insert(payload);
    } catch (e, st) {
      debugPrint('❌ logOrderEvent error: $e\n$st');
    }
  }

  /// Возвращает список событий истории по идентификатору заказа.
  Future<List<Map<String, dynamic>>> fetchOrderHistory(String orderId) async {
    try {
      final rows = await _supabase
          .from('order_history')
          .select()
          .eq('order_id', orderId)
          .order('created_at', ascending: true);
      return List<Map<String, dynamic>>.from(rows);
    } catch (e, st) {
      debugPrint('❌ fetchOrderHistory error: $e\n$st');
      return [];
    }
  }

  // ===== Склад =====

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

    final tmcId = (pm['tmcId'] ??
        pm['tmc_id'] ??
        pm['materialId'] ??
        pm['material_id']) as String?;

    final qRaw = (pm['quantity'] ?? pm['qty'] ?? pm['count']);
    final qty =
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

  // ===== helpers =====

  Future<String> _reserveOrderId() async {
    try {
      final res = await _supabase.rpc('reserve_order_id');
      if (res is String && res.isNotEmpty) return res;
      throw Exception('empty id from rpc');
    } catch (e) {
      debugPrint('⚠️ reserve_order_id failed: $e');
      // Фоллбэк: уникальный локальный ID по времени (минимальный риск коллизии)
      final now = DateTime.now();
      final tail =
          (now.microsecondsSinceEpoch % 1000000).toString().padLeft(6, '0');
      return 'ORD-${now.year}-$tail';
    }
  }

  // Локальный генератор — оставлен только как утилита.
  String _generateOrderNumber() {
    final year = DateTime.now().year;
    final countThisYear =
        _orders.where((o) => o.id.startsWith('ORD-$year-')).length + 1;
    final serial = countThisYear.toString().padLeft(3, '0');
    return 'ORD-$year-$serial';
  }

  String generateAssignmentId() {
    final year = DateTime.now().year;
    final countThisYear = _orders
            .where((o) => (o.assignmentId ?? '').startsWith('ZK-$year-'))
            .length +
        1;
    final serial = countThisYear.toString().padLeft(3, '0');
    return 'ZK-$year-$serial';
  }
}
