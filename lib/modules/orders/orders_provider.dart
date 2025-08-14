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
      assignmentId: null,
      assignmentCreated: false,
    );
    _orders.add(newOrder);
    notifyListeners();
    _ordersRef.child(newOrder.id).set(newOrder.toMap());
    return newOrder;
  }

  /// Обновляет существующий заказ по его идентификатору.
  /// Если заказ найден в локальном списке, он заменяется, а изменения
  /// сохраняются в Firebase. В противном случае новая запись будет
  /// создана в базе данных.
  void updateOrder(OrderModel updated) {
    final index = _orders.indexWhere((o) => o.id == updated.id);
    if (index >= 0) {
      _orders[index] = updated;
      notifyListeners();
    }
    // Сохраняем обновлённую запись в Firebase независимо от наличия в списке.
    _ordersRef.child(updated.id).set(updated.toMap());
  }

  /// Удаляет заказ по идентификатору. Удаляет его из списка и из Firebase.
  void deleteOrder(String id) {
    final index = _orders.indexWhere((o) => o.id == id);
    if (index == -1) return;
    final removed = _orders.removeAt(index);
    notifyListeners();
    _ordersRef.child(removed.id).remove();
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