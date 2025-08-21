import 'dart:async';
import 'dart:convert'; // jsonDecode
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'order_model.dart';
import 'product_model.dart';

class OrdersProvider with ChangeNotifier {
  final SupabaseClient _supabase = Supabase.instance.client;

  final List<OrderModel> _orders = [];
  StreamSubscription<List<Map<String, dynamic>>>? _ordersSub;

  OrdersProvider() {
    _listenToOrders();
  }

  List<OrderModel> get orders => List.unmodifiable(_orders);

  // ===== live stream =====
  void _listenToOrders() {
    _ordersSub?.cancel();
    _ordersSub = _supabase
        .from('orders')
        .stream(primaryKey: ['id'])
        .listen((rows) {
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
      rethrow;
    }
  }

  /// Создаёт заказ с авто-ID и сохраняет его.
  Future<OrderModel> createOrder({
    required String customer,
    required DateTime orderDate,
    required DateTime dueDate,
    required ProductModel product,
    bool contractSigned = false,
    bool paymentDone = false,
    String comments = '',
  }) async {
    final newOrder = OrderModel(
      id: _generateOrderNumber(),
      customer: customer,
      orderDate: orderDate,
      dueDate: dueDate,
      product: product,
      contractSigned: contractSigned,
      paymentDone: paymentDone,
      comments: comments,
      status: OrderStatus.newOrder, // используем то, что у тебя точно есть
      assignmentId: null,
      assignmentCreated: false,
    );

    _orders.add(newOrder); // оптимистично
    notifyListeners();

    try {
      final inserted = await _supabase
          .from('orders')
          .insert(newOrder.toMap())
          .select()
          .single() as Map<String, dynamic>;

      // синхронизируемся с тем, что вернула БД
      final created = OrderModel.fromMap(Map<String, dynamic>.from(inserted));
      final idx = _orders.indexWhere((o) => o.id == newOrder.id);
      if (idx != -1) {
        _orders[idx] = created;
        notifyListeners();
      }
      return created;
    } catch (e, st) {
      _orders.removeWhere((o) => o.id == newOrder.id); // откат
      notifyListeners();
      debugPrint('❌ createOrder error: $e\n$st');
      rethrow;
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
      await _supabase
          .from('orders')
          .update(updated.toMap())
          .eq('id', updated.id)
          .select()
          .single();
    } catch (e, st) {
      _orders[index] = prev; // откат
      notifyListeners();
      debugPrint('❌ updateOrder error: $e\n$st');
      rethrow;
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
      rethrow;
    }
  }

  // ===== Склад: вызывай сам в нужных местах UI/сценариев =====

  /// Списание материалов по продуктам заказа (например, при «в производстве» или «завершён»).
  Future<void> applyStockOnFulfillment(OrderModel order) async {
    await _applyStockDelta(order, isShipment: true);
  }

  /// Возврат материалов по продуктам заказа (например, при «отменён»).
  Future<void> revertStockOnCancel(OrderModel order) async {
    await _applyStockDelta(order, isShipment: false);
  }

  /// Общая реализация списания/возврата.
  Future<void> _applyStockDelta(
    OrderModel order, {
    required bool isShipment,
  }) async {
    final pm = order.product.toMap();

    // поддержим разные названия полей
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
      // не блокируем процесс — просто логируем
      debugPrint('⚠️ stock delta failed for $tmcId: $e');
      }
    
  }

  // ===== генераторы =====

  /// ORD-YYYY-NNN (NNN — счётчик в пределах года).
  String _generateOrderNumber() {
    final year = DateTime.now().year;
    final countThisYear =
        _orders.where((o) => o.id.startsWith('ORD-$year-')).length + 1;
    final serial = countThisYear.toString().padLeft(3, '0');
    return 'ORD-$year-$serial';
  }

  /// ZK-YYYY-NNN — для производственных заданий.
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
