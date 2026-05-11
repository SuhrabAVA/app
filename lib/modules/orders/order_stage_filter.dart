enum OrderHandleType { none, flat, twisted, dieCut }

const String flatHandleStageId = '6ffdf2d9-3f57-45ca-9fad-dd700ac5c320';
const String twistedHandleStageId = 'c51ebb2e-dac8-4068-9e4c-ce0d8b975626';
const String manualHandleStageId = 'c25ac6fa-390a-4e87-84aa-536055e013f4';
const String dieCutHandleStageId = '4925309c-a2c6-4f5f-9f5e-7dd5ff38827d';
const String cuttingStageId = 'c828062f-a6a6-4fe5-b01b-c51e36fe5fba';
const String kCardboardCuttingStageId =
    'd7d91f75-2f85-446f-8c1d-a20606bdb3b1';
const String kCardboardInsertStageId =
    'ce15da53-34bb-4a48-acef-610ddfd4a42e';
const String kBottomWithCardboardAssemblyStageId =
    'd15da69b-9842-4967-96ed-28a4834b409e';
const Set<String> kOptionalCardboardStageIds = {
  kCardboardCuttingStageId,
  kCardboardInsertStageId,
  kBottomWithCardboardAssemblyStageId,
};

List<Map<String, dynamic>> filterOrderStagesByOptions({
  required List<Map<String, dynamic>> stages,
  required OrderHandleType selectedHandleType,
  required bool hasCardboard,
  required bool hasCutting,
}) {
  bool shouldKeepStage(String stageId) {
    if (stageId == flatHandleStageId) {
      return selectedHandleType == OrderHandleType.flat;
    }
    if (stageId == twistedHandleStageId) {
      return selectedHandleType == OrderHandleType.twisted;
    }
    if (stageId == manualHandleStageId) {
      return selectedHandleType == OrderHandleType.flat ||
          selectedHandleType == OrderHandleType.twisted;
    }
    if (stageId == dieCutHandleStageId) {
      return selectedHandleType == OrderHandleType.dieCut;
    }
    if (kOptionalCardboardStageIds.contains(stageId)) {
      return hasCardboard;
    }
    if (stageId == cuttingStageId) {
      return hasCutting;
    }
    return true;
  }

  final filtered = <Map<String, dynamic>>[];
  for (final stage in stages) {
    final map = Map<String, dynamic>.from(stage);
    final stageId = (map['stageId'] ??
            map['stage_id'] ??
            map['stageid'] ??
            map['workplaceId'] ??
            map['workplace_id'] ??
            map['id'])
        ?.toString()
        .trim();
    if (stageId == null || stageId.isEmpty || shouldKeepStage(stageId)) {
      filtered.add(map);
    }
  }
  return filtered;
}
