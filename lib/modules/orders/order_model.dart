import 'product_model.dart';

/// Статус заказа определяет его стадия обработки.
enum OrderStatus { newOrder, inWork, completed }

/// Модель заказа. Один заказ может включать несколько продуктов.
class OrderModel {
  final String id;
  String customer;
  DateTime orderDate;
  DateTime dueDate;
  List<ProductModel> products;
  bool contractSigned;
  bool paymentDone;
  String comments;
  OrderStatus status;

  OrderModel({
    required this.id,
    required this.customer,
    required this.orderDate,
    required this.dueDate,
    required this.products,
    this.contractSigned = false,
    this.paymentDone = false,
    this.comments = '',
    this.status = OrderStatus.newOrder,
  });
}