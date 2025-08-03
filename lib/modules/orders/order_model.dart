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

  /// Преобразует модель заказа в Map для сохранения в Firebase.
  Map<String, dynamic> toMap() => {
        'id': id,
        'customer': customer,
        'orderDate': orderDate.toIso8601String(),
        'dueDate': dueDate.toIso8601String(),
        'products': products.map((p) => p.toMap()).toList(),
        'contractSigned': contractSigned,
        'paymentDone': paymentDone,
        'comments': comments,
        'status': status.name,
      };

  /// Создаёт [OrderModel] из Map, полученного из Firebase.
  factory OrderModel.fromMap(Map<String, dynamic> map) => OrderModel(
        id: map['id'] as String,
        customer: map['customer'] as String? ?? '',
        orderDate: DateTime.parse(map['orderDate'] as String),
        dueDate: DateTime.parse(map['dueDate'] as String),
        products: (map['products'] as List<dynamic>? ?? [])
            .map((p) => ProductModel.fromMap(Map<String, dynamic>.from(p)))
            .toList(),
        contractSigned: map['contractSigned'] as bool? ?? false,
        paymentDone: map['paymentDone'] as bool? ?? false,
        comments: map['comments'] as String? ?? '',
        status:
            OrderStatus.values.byName(map['status'] as String? ?? 'newOrder'),
      );
}