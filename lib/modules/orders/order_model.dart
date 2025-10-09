// lib/modules/orders/order_model.dart
import 'dart:convert';
import 'product_model.dart';
import 'material_model.dart';

/// Статус заказа.
enum OrderStatus { newOrder, inWork, completed }

/// ===== SAFE CAST HELPERS =====
bool? _asBool(dynamic v) {
  if (v == null) return null;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final s = v.trim().toLowerCase();
    if (['true', 't', '1', 'yes', 'y'].contains(s)) return true;
    if (['false', 'f', '0', 'no', 'n', '', 'null'].contains(s)) return false;
  }
  return null;
}

Map<String, dynamic> _asMap(dynamic v) {
  if (v == null) return <String, dynamic>{};
  if (v is Map) return Map<String, dynamic>.from(v as Map);
  if (v is String && v.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(v);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
  }
  return <String, dynamic>{};
}

List<String> _asStringList(dynamic v) {
  if (v == null) return const <String>[];
  if (v is List)
    return v
        .map((e) => e?.toString() ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
  if (v is String && v.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(v);
      if (decoded is List) {
        return decoded
            .map((e) => e?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .toList();
      }
    } catch (_) {}
  }
  if (v is Map) {
    // если пришёл объект — берём значения
    return v.values
        .map((e) => e?.toString() ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
  }
  return const <String>[];
}

T? _pick<T>(Map src, String snake, String camel) {
  final a = src[snake];
  if (a is T) return a as T;
  final b = src[camel];
  if (b is T) return b as T;
  return null;
}

dynamic _pickAny(Map src, List<String> keys) {
  for (final k in keys) {
    if (src.containsKey(k) && src[k] != null) return src[k];
  }
  return null;
}

/// ===== Модель заказа =====
class OrderModel {
  final String id;
  String manager;
  String customer;
  DateTime orderDate;
  DateTime? dueDate;
  ProductModel product;
  List<String> additionalParams;
  String handle;
  String cardboard;
  MaterialModel? material;
  double makeready;
  double val;
  String? pdfUrl;
  String? stageTemplateId;
  // Формы
  final bool isOldForm;
  final int? newFormNo;
  final String? formSeries;
  final String? formCode;
  bool contractSigned;
  bool paymentDone;
  String comments;

  /// Храним строкой (name), чтобы не падать на незнакомых значениях
  String status;
  String? assignmentId;
  bool assignmentCreated;

  OrderModel({
    required this.id,
    required this.manager,
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
    // формы
    this.isOldForm = false,
    this.newFormNo,
    this.formSeries,
    this.formCode,
    bool? contractSigned,
    bool? paymentDone,
    String? comments,
    String? status,
    this.assignmentId,
    bool? assignmentCreated,
  })  : additionalParams = additionalParams ?? const <String>[],
        handle = handle ?? '-',
        cardboard = cardboard ?? 'нет',
        makeready = (makeready ?? 0).toDouble(),
        val = (val ?? 0).toDouble(),
        contractSigned = contractSigned ?? false,
        paymentDone = paymentDone ?? false,
        comments = comments ?? '',
        status = status ?? 'newOrder',
        assignmentCreated = assignmentCreated ?? false;

  OrderStatus get statusEnum => OrderStatus.values
      .firstWhere((s) => s.name == status, orElse: () => OrderStatus.newOrder);
  set statusEnum(OrderStatus s) => status = s.name;

  /// В БД пишем snake_case.
  Map<String, dynamic> toMap() => {
        'id': id,
        'manager': manager,
        'customer': customer,
        'order_date': orderDate.toIso8601String(),
        if (dueDate != null) 'due_date': dueDate!.toIso8601String(),
        'product': product.toMap(),
        'additional_params':
            additionalParams, // массив строк; БД примет и объект
        'handle': handle,
        'cardboard': cardboard,
        if (material != null) 'material': material!.toMap(),
        'makeready': makeready,
        'val': val,
        'is_old_form': isOldForm,
        if (newFormNo != null) 'new_form_no': newFormNo,
        if (formSeries != null) 'form_series': formSeries,
        if (formCode != null) 'form_code': formCode,
        if (pdfUrl != null) 'pdf_url': pdfUrl,
        if (stageTemplateId != null) 'stage_template_id': stageTemplateId,
        'contract_signed': contractSigned,
        'payment_done': paymentDone,
        'comments': comments,
        'status': status,
        if (assignmentId != null) 'assignment_id': assignmentId,
        'assignment_created': assignmentCreated,
      };

  /// Парсим и camelCase, и snake_case.
  factory OrderModel.fromMap(Map<String, dynamic> map) {
    DateTime? _parseDate(dynamic v) {
      if (v is String && v.isNotEmpty) {
        try {
          return DateTime.parse(v);
        } catch (_) {}
      }
      if (v is DateTime) return v;
      return null;
    }

    final productMap = _asMap(_pickAny(map, const ['product', 'productMap']));
    final materialMap = _asMap(_pickAny(map, const ['material']));

    final assignmentCreatedBool = _asBool(
            _pickAny(map, const ['assignment_created', 'assignmentCreated'])) ??
        false;
    final contractSignedBool =
        _asBool(_pickAny(map, const ['contract_signed', 'contractSigned'])) ??
            false;
    final paymentDoneBool =
        _asBool(_pickAny(map, const ['payment_done', 'paymentDone'])) ?? false;

    final isOldFormBool =
        _asBool(_pickAny(map, const ['is_old_form', 'isOldForm'])) ?? false;
    final int? newFormNoVal =
        (_pickAny(map, const ['new_form_no', 'newFormNo']) as num?)?.toInt();
    final String? formSeriesVal =
        (_pickAny(map, const ['form_series', 'formSeries']) as String?);
    final String? formCodeVal =
        (_pickAny(map, const ['form_code', 'formCode']) as String?);

    return OrderModel(
      id: (_pickAny(map, const ['id']) as String?) ?? '',
      manager: (_pickAny(map, const ['manager']) as String?) ?? '',
      customer: (_pickAny(map, const ['customer']) as String?) ?? '',
      orderDate: _parseDate(_pickAny(map, const ['order_date', 'orderDate'])) ??
          DateTime.now() ??
          DateTime.now(),
      dueDate: _parseDate(_pickAny(map, const ['due_date', 'dueDate'])),
      product: ProductModel.fromMap(productMap),
      additionalParams: _asStringList(
          _pickAny(map, const ['additional_params', 'additionalParams'])),
      handle: (_pickAny(map, const ['handle']) as String?) ?? '-',
      cardboard: (_pickAny(map, const ['cardboard']) as String?) ?? 'нет',
      material: materialMap.isEmpty ? null : MaterialModel.fromMap(materialMap),
      makeready:
          ((_pickAny(map, const ['makeready']) as num?)?.toDouble()) ?? 0,
      val: ((_pickAny(map, const ['val']) as num?)?.toDouble()) ?? 0,
      pdfUrl: (_pickAny(map, const ['pdf_url', 'pdfUrl']) as String?),
      stageTemplateId:
          (_pickAny(map, const ['stage_template_id', 'stageTemplateId'])
              as String?),
      isOldForm: isOldFormBool,
      newFormNo: newFormNoVal,
      formSeries: formSeriesVal,
      formCode: formCodeVal,
      contractSigned: contractSignedBool,
      paymentDone: paymentDoneBool,
      comments: (_pickAny(map, const ['comments']) as String?) ?? '',
      status: (_pickAny(map, const ['status']) as String?) ?? 'newOrder',
      assignmentId:
          (_pickAny(map, const ['assignment_id', 'assignmentId']) as String?),
      assignmentCreated: assignmentCreatedBool,
    );
  }
}
