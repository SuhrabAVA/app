enum OrderHandleType { none, flat, twisted }

const String flatHandleStageId = '6fdff2d9-3f57-45ca-9fad-dd700ac5c320';
const String twistedHandleStageId = 'c5c1eb2e-dac8-4068-9e4c-ced8fb975626';
const String cuttingStageId = 'c828062f-a6a6-4fe5-b01b-c51e36fe5fba';
const String cardboardStageId = 'ce15da53-34bb-4a48-acef-610dddfad42e';

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
    if (stageId == cardboardStageId) {
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
