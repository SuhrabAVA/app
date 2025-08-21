import 'product_model.dart';

/// Статус заказа определяет его стадия обработки.
enum OrderStatus { newOrder, inWork, completed }

/// Модель заказа. В текущей реализации заказ содержит один продукт.
class OrderModel {
  final String id;
  String customer;
  DateTime orderDate;
  DateTime dueDate;
  /// Единственный продукт, связанный с заказом.
  ProductModel product;
  bool contractSigned;
  bool paymentDone;
  String comments;
  OrderStatus status;
  /// Идентификатор производственного задания (формат ЗК-YYYY-NNN). Генерируется при планировании.
  String? assignmentId;
  /// Признак того, что производственное задание создано для этого заказа.
  bool assignmentCreated;

  OrderModel({
    required this.id,
    required this.customer,
    required this.orderDate,
    required this.dueDate,
    required this.product,
    this.contractSigned = false,
    this.paymentDone = false,
    this.comments = '',
    this.status = OrderStatus.newOrder,
    this.assignmentId,
    this.assignmentCreated = false,
  });

  /// Преобразует модель заказа в Map для сохранения в Firebase.
  Map<String, dynamic> toMap() => {
        'id': id,
        'customer': customer,
        'orderDate': orderDate.toIso8601String(),
        'dueDate': dueDate.toIso8601String(),
        'product': product.toMap(),
        'contractSigned': contractSigned,
        'paymentDone': paymentDone,
        'comments': comments,
        'status': status.name,
        if (assignmentId != null) 'assignmentId': assignmentId,
        'assignmentCreated': assignmentCreated,
      };

  /// Создаёт [OrderModel] из Map, полученного из Firebase.
  factory OrderModel.fromMap(Map<String, dynamic> map) => OrderModel(
        id: map['id'] as String,
        customer: map['customer'] as String? ?? '',
        orderDate: DateTime.parse(map['orderDate'] as String),
        dueDate: DateTime.parse(map['dueDate'] as String),
        product: ProductModel.fromMap(
          Map<String, dynamic>.from(
            map['product'] as Map? ?? const {},
          ),
        ),
        contractSigned: map['contractSigned'] as bool? ?? false,
        paymentDone: map['paymentDone'] as bool? ?? false,
        comments: map['comments'] as String? ?? '',
        status:
            OrderStatus.values.byName(map['status'] as String? ?? 'newOrder'),
        assignmentId: map['assignmentId'] as String?,
        assignmentCreated: map['assignmentCreated'] as bool? ?? false,
      );
}