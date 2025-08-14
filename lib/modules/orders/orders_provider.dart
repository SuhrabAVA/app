import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'order_model.dart';
import 'product_model.dart';

/// Провайдер для управления списком заказов. Хранит заказы в памяти и
/// уведомляет слушателей об изменениях.
class OrdersProvider with ChangeNotifier {
  final _uuid = const Uuid();
  final SupabaseClient _supabase = Supabase.instance.client;

  final List<OrderModel> _orders = [];

  OrdersProvider() {
    _listenToOrders();
  }

  List<OrderModel> get orders => List.unmodifiable(_orders);

  void _listenToOrders() {
    _supabase.from('orders').stream(primaryKey: ['id']).listen((rows) {
      _orders
        ..clear()
        ..addAll(rows.map((row) {
          final map = Map<String, dynamic>.from(row as Map);
          return OrderModel.fromMap(map);
        }));
      notifyListeners();
    });
  }

  /// Добавляет новый заказ в список и сохраняет его в Supabase.
  void addOrder(OrderModel order) {
    _orders.add(order);
    notifyListeners();
    _supabase.from('orders').insert(order.toMap());
  }

  /// Создаёт и добавляет новый заказ с автоматически сгенерированным ID.
  OrderModel createOrder({
    required String customer,
    required DateTime orderDate,
    required DateTime dueDate,
    List<ProductModel>? products,
    bool contractSigned = false,
    bool paymentDone = false,
    String comments = '',
  }) {
    final newOrder = OrderModel(
      id: _generateOrderNumber(),
      customer: customer,
      orderDate: orderDate,
      dueDate: dueDate,
      products: products ?? [],
      contractSigned: contractSigned,
      paymentDone: paymentDone,
      comments: comments,
      status: OrderStatus.newOrder,
      assignmentId: null,
      assignmentCreated: false,
    );
    _orders.add(newOrder);
    notifyListeners();
    _supabase.from('orders').insert(newOrder.toMap());
    return newOrder;
  }

  /// Обновляет существующий заказ по его идентификатору.
  /// Сохраняет изменения в Supabase.
  void updateOrder(OrderModel updated) {
    final index = _orders.indexWhere((o) => o.id == updated.id);
    if (index >= 0) {
      _orders[index] = updated;
      notifyListeners();
    }
    _supabase.from('orders').upsert(updated.toMap());
  }

  /// Удаляет заказ по идентификатору. Удаляет его из списка и из Supabase.
  void deleteOrder(String id) {
    final index = _orders.indexWhere((o) => o.id == id);
    if (index == -1) return;
    final removed = _orders.removeAt(index);
    notifyListeners();
    _supabase.from('orders').delete().eq('id', removed.id);
  }
  

  /// Генерирует новый номер заказа в формате ORD-YYYY-NNN.
  String _generateOrderNumber() {
    final now = DateTime.now();
    final year = now.year;
    final serial = (_orders.length + 1).toString().padLeft(3, '0');
    return 'ORD-$year-$serial';
  }

  /// Генерирует уникальный идентификатор производственного задания в формате ЗК-YYYY-NNN.
  /// Подсчитывает количество уже существующих заданий в текущем году и увеличивает счётчик.
  String generateAssignmentId() {
    final now = DateTime.now();
    final year = now.year;
    // Подсчитываем количество заказов с назначенным заданием в текущем году.
    final count = _orders
            .where((o) => o.assignmentId != null && o.assignmentId!.startsWith('ZK-$year-'))
            .length +
        1;
    final serial = count.toString().padLeft(3, '0');
    return 'ZK-$year-$serial';
  }
}