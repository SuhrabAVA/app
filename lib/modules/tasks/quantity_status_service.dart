import 'dart:convert';

import 'package:flutter/material.dart';

import '../orders/order_model.dart';
import '../orders/stage_queue_builder.dart' as stage_queue;
import '../orders/material_model.dart';
import 'task_model.dart';

const String kQuantityStatusTwoSheetPackageProductId =
    stage_queue.kTwoSheetPackageProductTypeId;
const String kQuantityStatusSheetCutStageId = stage_queue.kSheetCutStageId;
const Set<String> kQuantityStatusSheetCutStageAliases = <String>{
  'листорезка',
};
const String kQuantityStatusWarningMessage =
    'Введённое количество отличается от плана. Проверьте значение перед завершением этапа.';

enum QuantityStatus { success, warning, danger, unknown }

const Set<String> _meterUnitAliases = <String>{
  'м',
  'метр',
  'метры',
  'm',
  'meter',
  'meters',
};

const Set<String> _pieceUnitAliases = <String>{
  '',
  'шт',
  'шт.',
  'штука',
  'штуки',
  'лист',
  'листы',
  'экземпляр',
  'экземпляры',
  'pcs',
  'pieces',
};

const Set<String> _packUnitAliases = <String>{
  'уп',
  'уп.',
  'упак',
  'упаковка',
  'упаковки',
  'пач',
  'пачка',
  'пачки',
  'pack',
  'packs',
};

String normalizeQuantityUnit(String? unit) =>
    (unit ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

bool isQuantityMeterUnit(String? unit) =>
    _meterUnitAliases.contains(normalizeQuantityUnit(unit));

bool isQuantityPieceUnit(String? unit) =>
    _pieceUnitAliases.contains(normalizeQuantityUnit(unit));

bool isQuantityPackUnit(String? unit) =>
    _packUnitAliases.contains(normalizeQuantityUnit(unit));

double? _number(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  if (value is String) {
    final normalized = value.trim().replaceAll(',', '.');
    if (normalized.isEmpty) return null;
    final parsed = double.tryParse(normalized);
    if (parsed != null) return parsed;
    return double.tryParse(normalized.replaceAll(RegExp(r'[^0-9.\-]'), ''));
  }
  return null;
}

double? _paperLengthFromMap(Map<String, dynamic>? map) {
  if (map == null) return null;
  for (final key in const <String>['lengthL', 'length_l', 'length', 'L']) {
    final parsed = _number(map[key]);
    if (parsed != null && parsed > 0) return parsed;
  }
  final paper = map['paper'];
  if (paper is Map) {
    final parsed = _paperLengthFromMap(Map<String, dynamic>.from(paper));
    if (parsed != null && parsed > 0) return parsed;
  }
  return null;
}

double? _paperLengthFromMaterial(MaterialModel material) {
  final extraLength = _paperLengthFromMap(material.extra);
  if (extraLength != null && extraLength > 0) return extraLength;
  if (material.quantity > 0) return material.quantity;
  return null;
}

double taskPaperLengthTotalForOrder(OrderModel? order) {
  if (order == null) return 0;

  final materialTotal = order.paperMaterials.fold<double>(0, (sum, material) {
    final length = _paperLengthFromMaterial(material);
    return length == null || length <= 0 ? sum : sum + length;
  });
  if (materialTotal > 0) return materialTotal;

  final productMap = order.product.toMap();
  final productLength = _paperLengthFromMap(productMap);
  if (productLength != null && productLength > 0) return productLength;

  final directLength = order.product.length;
  if (directLength != null && directLength > 0) return directLength;

  return 0;
}

double? initialTaskMeterQuantityForOrder({
  required String? unit,
  required OrderModel? order,
}) {
  if (!isQuantityMeterUnit(unit)) return null;
  final total = taskPaperLengthTotalForOrder(order);
  return total > 0 ? total : null;
}

const Set<String> kQuantityStatusTwoSheetPackageProductAliases = <String>{
  'пакет с 2х листов',
  'пакет с 2 листов',
  'пакет из 2х листов',
  'пакет из 2 листов',
};

String _normalizeProductName(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll('ё', 'е')
    .replaceAll(RegExp(r'[\s_\-]+'), ' ');

bool _isTwoSheetPackageProduct(String productType) {
  return stage_queue.isTwoSheetPackageProductType(productType) ||
      kQuantityStatusTwoSheetPackageProductAliases
          .contains(_normalizeProductName(productType));
}

bool isTwoSheetPackageSheetCutting({
  required OrderModel order,
  required TaskModel task,
}) {
  final productType = order.product.type.trim();
  final stageId = task.stageId.trim();
  return _isTwoSheetPackageProduct(productType) &&
      (stageId == kQuantityStatusSheetCutStageId ||
          kQuantityStatusSheetCutStageAliases
              .contains(_normalizeProductName(stageId)));
}

double? packQuantityFromOrder(OrderModel order) {
  final packs = _number(order.product.blQuantity);
  return (packs != null && packs > 0) ? packs : null;
}

double? getExpectedQuantity({
  required OrderModel order,
  required TaskModel task,
  required String unit,
}) {
  if (isQuantityMeterUnit(unit)) {
    final meters = taskPaperLengthTotalForOrder(order);
    return meters > 0 ? meters : null;
  }

  if (isQuantityPackUnit(unit)) {
    final quantity = order.product.quantity;
    return quantity > 0 ? quantity.toDouble() : null;
  }

  if (isQuantityPieceUnit(unit)) {
    final quantity = order.product.quantity;
    if (quantity <= 0) return null;
    if (isTwoSheetPackageSheetCutting(order: order, task: task)) {
      return quantity * 2;
    }
    return quantity.toDouble();
  }

  return null;
}

QuantityStatus getQuantityStatus({
  required double actual,
  required double? expected,
}) {
  if (expected == null || expected <= 0) return QuantityStatus.unknown;
  final diff = (actual - expected).abs();
  if (diff <= 0.0001) return QuantityStatus.success;
  final deviation = diff / expected;
  if (deviation <= 0.1) return QuantityStatus.warning;
  return QuantityStatus.danger;
}

Color getQuantityStatusColor(QuantityStatus status) {
  switch (status) {
    case QuantityStatus.success:
      return Colors.green;
    case QuantityStatus.warning:
      return Colors.orange;
    case QuantityStatus.danger:
      return Colors.red;
    case QuantityStatus.unknown:
      return Colors.grey;
  }
}

String quantityStatusToJson({
  required double actual,
  required String unit,
  required double? expected,
  required QuantityStatus status,
  required String displayText,
}) {
  return jsonEncode(<String, dynamic>{
    'actual': actual,
    'unit': unit,
    'expected': expected,
    'quantity_status': status.name,
    'display': displayText,
  });
}

Map<String, dynamic>? tryDecodeQuantityPayload(String text) {
  final trimmed = text.trim();
  if (!trimmed.startsWith('{')) return null;
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {}
  return null;
}

double? quantityActualFromText(String text) {
  final payload = tryDecodeQuantityPayload(text);
  final actual = _number(payload?['actual']);
  if (actual != null) return actual;

  final normalized = text.replaceAll(',', '.').trim();
  final totalFromFormula =
      RegExp(r'=\s*(-?\d+(?:\.\d+)?)').firstMatch(normalized);
  if (totalFromFormula != null) {
    return double.tryParse(totalFromFormula.group(1) ?? '');
  }
  final packsMatch = RegExp(r'(-?\d+(?:\.\d+)?)\s*пач', caseSensitive: false)
      .firstMatch(normalized);
  final inPackMatch =
      RegExp(r'[x×*]\s*(-?\d+(?:\.\d+)?)').firstMatch(normalized);
  if (packsMatch != null && inPackMatch != null) {
    final packs = double.tryParse(packsMatch.group(1) ?? '') ?? 0;
    final inPack = double.tryParse(inPackMatch.group(1) ?? '') ?? 0;
    return packs * inPack;
  }
  final parsed = double.tryParse(normalized);
  if (parsed != null) return parsed;
  final firstNumber = RegExp(r'-?\d+(?:\.\d+)?').firstMatch(normalized);
  return firstNumber == null ? null : double.tryParse(firstNumber.group(0)!);
}

String quantityDisplayText(String text) {
  final payload = tryDecodeQuantityPayload(text);
  final display = payload?['display']?.toString().trim();
  if (display != null && display.isNotEmpty) return display;
  return text;
}

QuantityStatus? quantityStatusFromText(String text) {
  final payload = tryDecodeQuantityPayload(text);
  final raw = payload?['quantity_status']?.toString();
  if (raw == null) return null;
  for (final status in QuantityStatus.values) {
    if (status.name == raw) return status;
  }
  return null;
}
