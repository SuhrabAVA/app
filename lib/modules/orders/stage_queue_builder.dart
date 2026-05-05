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

List<Map<String, dynamic>> insertProductStageAfterBaseStages(
  List<Map<String, dynamic>> queue,
  Map<String, dynamic> productStage,
) {
  final ids = queue.map((e) => (e['stageId'] ?? e['id'] ?? '').toString()).toList();
  final baseIds = <String>{'w_bobiner', 'w_bobbin', 'w_flexoprint'};
  var insertAt = -1;
  for (var i = 0; i < ids.length; i++) {
    if (baseIds.contains(ids[i])) insertAt = i;
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

bool canToggleProductStage({
  required String productTypeId,
  required String stageId,
}) {
  final normalizedProductTypeId = productTypeId.trim();
  if (kVTypeProducts.contains(normalizedProductTypeId)) {
    return stageId == kFriStageId || stageId == kWindowStageId;
  }
  if (normalizedProductTypeId == '71c889cb-b24c-4bda-9a69-ae312f9a4bbd') {
    return stageId == kAutoBigStageId ||
        stageId == kAutoSmallStageId ||
        stageId == kTubeStageId;
  }
  return false;
}
