import 'product_model.dart';
import 'material_model.dart';

/// Статус заказа.
enum OrderStatus { newOrder, inWork, completed }

/// Модель заказа.
class OrderModel {
  final String id;
  String customer;
  DateTime orderDate;
  DateTime dueDate;
  ProductModel product;
  List<String> additionalParams;
  String handle;
  String cardboard;
  MaterialModel? material;
  double makeready;
  double val;
  String? pdfUrl;
  String? stageTemplateId;
  bool contractSigned;
  bool paymentDone;
  String comments;
  /// Храним строкой (name), чтобы не падать на незнакомых значениях
  String status;
  String? assignmentId;
  bool assignmentCreated;

  /// Конструктор с безопасными дефолтами — не требует
  /// additionalParams и assignmentCreated при создании.
  OrderModel({
    required this.id,
    required this.customer,
    required this.orderDate,
    required this.dueDate,
    required this.product,

    List<String>? additionalParams,
    String? handle,
    String? cardboard,
    this.material,
    double? makeready,
    double? val,
    this.pdfUrl,
    this.stageTemplateId,
    bool? contractSigned,
    bool? paymentDone,
    String? comments,
    String? status,

    this.assignmentId,
    bool? assignmentCreated,
  })  : additionalParams  = additionalParams ?? const <String>[],
        handle            = handle ?? '-',
        cardboard         = cardboard ?? 'нет',
        makeready         = (makeready ?? 0).toDouble(),
        val               = (val ?? 0).toDouble(),
        contractSigned    = contractSigned ?? false,
        paymentDone       = paymentDone ?? false,
        comments          = comments ?? '',
        status            = status ?? 'newOrder',
        assignmentCreated = assignmentCreated ?? false;

  /// Преобразует строковое поле [status] в [OrderStatus].
  /// Если получено неизвестное значение, возвращается [OrderStatus.newOrder].
  OrderStatus get statusEnum => OrderStatus.values.firstWhere(
        (s) => s.name == status,
        orElse: () => OrderStatus.newOrder,
      );

  /// Устанавливает статус, записывая строковое значение в [status].
  set statusEnum(OrderStatus newStatus) => status = newStatus.name;

  /// В БД пишем SNAKE_CASE — соответствует SQL-схеме.
  Map<String, dynamic> toMap() => {
        'id': id,
        'customer': customer,
        'order_date': orderDate.toIso8601String(),
        'due_date': dueDate.toIso8601String(),
        'product': product.toMap(),
        'additional_params': additionalParams,
        'handle': handle,
        'cardboard': cardboard,
        if (material != null) 'material': material!.toMap(),
        'makeready': makeready,
        'val': val,
        if (pdfUrl != null) 'pdf_url': pdfUrl,
        if (stageTemplateId != null) 'stage_template_id': stageTemplateId,
        'contract_signed': contractSigned,
        'payment_done': paymentDone,
        'comments': comments,
        'status': status, // строка
        if (assignmentId != null) 'assignment_id': assignmentId,
        'assignment_created': assignmentCreated,
      };

  /// Парсим и camelCase, и snake_case (для обратной совместимости).
  factory OrderModel.fromMap(Map<String, dynamic> map) {
    dynamic _pick(List<String> keys) {
      for (final k in keys) {
        if (map.containsKey(k) && map[k] != null) return map[k];
      }
      return null;
    }

    DateTime _parseDate(dynamic v) {
      if (v is String) return DateTime.parse(v);
      if (v is DateTime) return v;
      // если дата отсутствует — не падаем
      return DateTime.now();
    }

    final productMap = (_pick(['product']) as Map?) ?? const {};
    final materialMap = (_pick(['material']) as Map?);

    return OrderModel(
      id: (_pick(['id']) as String?) ?? '',
      customer: (_pick(['customer']) as String?) ?? '',
      orderDate: _parseDate(_pick(['orderDate', 'order_date'])),
      dueDate: _parseDate(_pick(['dueDate', 'due_date'])),
      product: ProductModel.fromMap(Map<String, dynamic>.from(productMap)),
      additionalParams: List<String>.from(
        (_pick(['additionalParams', 'additional_params']) as List?) ?? const [],
      ),
      handle: (_pick(['handle']) as String?) ?? '-',
      cardboard: (_pick(['cardboard']) as String?) ?? 'нет',
      material: materialMap != null
          ? MaterialModel.fromMap(Map<String, dynamic>.from(materialMap))
          : null,
      makeready: ((_pick(['makeready']) as num?)?.toDouble()) ?? 0,
      val: ((_pick(['val']) as num?)?.toDouble()) ?? 0,
      pdfUrl: (_pick(['pdfUrl', 'pdf_url']) as String?),
      stageTemplateId:
          (_pick(['stageTemplateId', 'stage_template_id']) as String?),
      contractSigned:
          (_pick(['contractSigned', 'contract_signed']) as bool?) ?? false,
      paymentDone:
          (_pick(['paymentDone', 'payment_done']) as bool?) ?? false,
      comments: (_pick(['comments']) as String?) ?? '',
      status: (_pick(['status']) as String?) ?? 'newOrder',
      assignmentId: (_pick(['assignmentId', 'assignment_id']) as String?),
      assignmentCreated:
          (_pick(['assignmentCreated', 'assignment_created']) as bool?) ?? false,
    );
  }
}
