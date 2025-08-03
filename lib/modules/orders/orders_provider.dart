import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:firebase_database/firebase_database.dart';

import 'order_model.dart';
import 'product_model.dart';

/// Провайдер для управления списком заказов. Хранит заказы в памяти и
/// уведомляет слушателей об изменениях.
class OrdersProvider with ChangeNotifier {
  final _uuid = const Uuid();
  final DatabaseReference _ordersRef =
      FirebaseDatabase.instance.ref('orders');

  final List<OrderModel> _orders = [];

  OrdersProvider() {
    _listenToOrders();
  }

  List<OrderModel> get orders => List.unmodifiable(_orders);

  void _listenToOrders() {
    _ordersRef.onValue.listen((event) {
      final data = event.snapshot.value;
      _orders.clear();
      if (data is Map) {
        data.forEach((key, value) {
          final map = Map<String, dynamic>.from(value as Map);
          _orders.add(OrderModel.fromMap(map));
        });
      }
      notifyListeners();
    });
  }

  /// Добавляет новый заказ в список и сохраняет его в Firebase.
  void addOrder(OrderModel order) {
    _orders.add(order);
    notifyListeners();
    _ordersRef.child(order.id).set(order.toMap());
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
    );
    _orders.add(newOrder);
    notifyListeners();
    _ordersRef.child(newOrder.id).set(newOrder.toMap());
    return newOrder;
  }

  /// Обновляет существующий заказ. Идентификация по ID.
  void updateOrder(OrderModel updated) {
    final index = _orders.indexWhere((o) => o.id == updated.id);
    if (index >= 0) {
      _orders[index] = updated;
      notifyListeners();
      _ordersRef.child(updated.id).set(updated.toMap());
    }
  }

  /// Генерирует новый номер заказа в формате ORD-YYYY-NNN.
  String _generateOrderNumber() {
    final now = DateTime.now();
    final year = now.year;
    final serial = (_orders.length + 1).toString().padLeft(3, '0');
    return 'ORD-$year-$serial';
  }
}