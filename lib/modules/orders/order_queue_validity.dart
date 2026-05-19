import 'dart:convert';

import 'material_model.dart';
import 'order_model.dart';
import 'product_model.dart';

Map<String, dynamic> buildQueueSignature({
  required ProductModel product,
  required List<MaterialModel> paperMaterials,
  required double? materialWidth,
  required bool hasPaint,
  required bool hasTrimming,
  required bool hasCardboard,
  required String handle,
  required String? templateId,
}) {
  final normalizedPapers = paperMaterials
      .map((paper) => <String, dynamic>{
            'id': (paper.id ?? '').trim(),
            'name': paper.name.trim(),
            'format': (paper.format ?? '').trim(),
            'grammage': (paper.grammage ?? '').trim(),
            'quantity': paper.quantity,
          })
      .toList(growable: false);

  return <String, dynamic>{
    'product_type_id': product.type.trim(),
    'product_quantity': product.quantity,
    'product_width': product.width,
    'product_height': product.height,
    'product_depth': product.depth,
    'product_width_b': product.widthB,
    'material_width': materialWidth,
    'paper_materials': normalizedPapers,
    'has_paint': hasPaint,
    'has_trimming': hasTrimming,
    'has_cardboard': hasCardboard,
    'handle': handle.trim(),
    'stage_template_id': templateId,
  };
}

bool isQueueActual({
  required Map<String, dynamic> currentSignature,
  required Map<String, dynamic>? storedSignature,
  required String queueBuildStatus,
  required List<Map<String, dynamic>> stages,
}) {
  if (stages.isEmpty) return false;
  if (QueueBuildStatus.normalize(queueBuildStatus) != QueueBuildStatus.built) {
    return false;
  }
  if (storedSignature == null) return false;
  return jsonEncode(storedSignature) == jsonEncode(currentSignature);
}
