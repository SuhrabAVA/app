const String kPackagingStageId = 'edeb85db-c7a3-4a24-8f33-70ccdd4aaae1';
const String kFriStageId = '92d96ee9-0519-40b9-bd17-9bec475496b6';
const String kWindowStageId = '8337f16e-c2d1-42dc-966d-6277ba3c1a50';
const String kAutoBigStageId = 'fdbf1735-a67c-47c9-a7e1-90546e1fe6ed';
const String kAutoSmallStageId = 'cbcbe469-b924-4064-ae05-885ccd1b842a';
const String kTubeStageId = 'e62fc013-4785-43f3-b3ee-a3ca51777199';
const String kSheetCutStageId = '19a67630-8374-4f9f-ae5b-f2f66828720b';

const Set<String> kVTypeProducts = {
  '448b731a-eafe-40f1-9268-bc5dd6ba57bc',
  '688ce20b-2db5-43ed-a414-dda08443a06a',
  'd2323dba-74c9-4e86-adfb-18cd47be9480',
  'dfd3beb1-1afd-4c06-9b3b-5da680377b0d',
};
const Set<String> kSheetProducts = {
  'aab3ed17-1688-43f0-b623-58dac264941f',
  'b07cd977-939c-4d4f-b68c-8d163341460e',
};

const String kPTypePackageProduct = '71c889cb-b24c-4bda-9a69-ae312f9a4bbd';

Map<String, dynamic>? _detectProductStage(String productTypeId) {
  if (kVTypeProducts.contains(productTypeId)) {
    return {'stageId': kFriStageId, 'stageName': 'Фри'};
  }
  if (productTypeId == kPTypePackageProduct) {
    return {'stageId': kAutoBigStageId, 'stageName': 'Автомат большой'};
  }
  if (kSheetProducts.contains(productTypeId)) {
    return {'stageId': kSheetCutStageId, 'stageName': 'Листорезка'};
  }
  return null;
}

List<Map<String, dynamic>> buildOrderStageQueue({
  required String productTypeId,
  required bool hasCutting,
  required bool hasCardboard,
  required bool hasBobbinCutting,
  required bool hasFlexPrinting,
  Object? handleType,
  List<Map<String, dynamic>> existingStages = const [],
  List<Map<String, dynamic>> templateStages = const [],
}) {
  final queue = <Map<String, dynamic>>[];
  final source = existingStages.isNotEmpty ? existingStages : templateStages;
  for (final stage in source) {
    final copy = Map<String, dynamic>.from(stage);
    final id = (copy['stageId'] ?? copy['id'] ?? '').toString();
    if (id == kPackagingStageId) continue;
    queue.add(copy);
  }

  if (queue.isEmpty) {
    if (hasBobbinCutting || hasCutting || hasCardboard) {
      queue.add({
        'stageId': 'b92a89d1-8e95-4c6d-b990-e308486e4bf1',
        'workplaceId': 'b92a89d1-8e95-4c6d-b990-e308486e4bf1',
        'stageName': 'Бобинорезка',
      });
    }
    if (hasFlexPrinting) {
      queue.add({
        'stageId': '0571c01c-f086-47e4-81b2-5d8b2ab91218',
        'workplaceId': '0571c01c-f086-47e4-81b2-5d8b2ab91218',
        'stageName': 'Флексопечать',
      });
    }
  }

  final productStage = _detectProductStage(productTypeId.trim());
  if (productStage != null) {
    queue.removeWhere((s) {
      final id = (s['stageId'] ?? s['id'] ?? '').toString();
      return id == kFriStageId ||
          id == kWindowStageId ||
          id == kAutoBigStageId ||
          id == kAutoSmallStageId ||
          id == kTubeStageId ||
          id == kSheetCutStageId;
    });
    final withProduct = insertProductStageAfterBaseStages(queue, productStage);
    queue
      ..clear()
      ..addAll(withProduct);
  }

  queue.add({'stageId': kPackagingStageId, 'stageName': 'Упаковка'});
  final seen = <String>{};
  return queue
      .where((s) => seen.add((s['stageId'] ?? s['id']).toString()))
      .toList(growable: false);
}

List<Map<String, dynamic>> insertProductStageAfterBaseStages(
  List<Map<String, dynamic>> queue,
  Map<String, dynamic> productStage,
) {
  bool isBaseStage(Map<String, dynamic> stage) {
    final id = (stage['stageId'] ?? stage['id'] ?? '').toString().toLowerCase();
    final name = (stage['stageName'] ??
            stage['workplaceName'] ??
            stage['title'] ??
            stage['name'] ??
            '')
        .toString()
        .toLowerCase();
    const baseIds = <String>{
      'w_bobiner',
      'w_bobbin',
      'w_flexoprint',
      'b92a89d1-8e95-4c6d-b990-e308486e4bf1', // canonical bobbin id
      '0571c01c-f086-47e4-81b2-5d8b2ab91218', // canonical flexo id
    };
    if (baseIds.contains(id)) return true;
    return name.contains('бобин') ||
        name.contains('бобтн') ||
        name.contains('флексо') ||
        name.contains('flexo') ||
        name.contains('печать');
  }

  var insertAt = -1;
  for (var i = 0; i < queue.length; i++) {
    if (isBaseStage(queue[i])) insertAt = i;
  }
  final next = List<Map<String, dynamic>>.from(queue);
  next.insert(insertAt + 1, productStage);
  return next;
}

String? toggleProductStage(String stageId) {
  switch (stageId) {
    case kFriStageId:
      return kWindowStageId;
    case kWindowStageId:
      return kFriStageId;
    case kAutoBigStageId:
      return kAutoSmallStageId;
    case kAutoSmallStageId:
      return kTubeStageId;
    case kTubeStageId:
      return kAutoBigStageId;
    default:
      return null;
  }
}
