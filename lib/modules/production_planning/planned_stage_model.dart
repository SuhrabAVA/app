class PlannedStage {
  final String stageId;
  final String stageName;
  final List<String> alternativeStageIds;
  final List<String> alternativeStageNames;
  String? comment;

  PlannedStage({
    required this.stageId,
    required this.stageName,
    this.alternativeStageIds = const [],
    this.alternativeStageNames = const [],
    this.comment,
  });

  List<String> get allStageIds =>
      [stageId, ...alternativeStageIds.where((id) => id != stageId)].toSet().toList();

  List<String> get allStageNames =>
      [stageName, ...alternativeStageNames.where((n) => n != stageName)].toSet().toList();

  PlannedStage copyWith({
    String? comment,
    List<String>? alternativeStageIds,
    List<String>? alternativeStageNames,
  }) =>
      PlannedStage(
        stageId: stageId,
        stageName: stageName,
        alternativeStageIds: alternativeStageIds ?? this.alternativeStageIds,
        alternativeStageNames: alternativeStageNames ?? this.alternativeStageNames,
        comment: comment ?? this.comment,
      );

  Map<String, dynamic> toMap() => {
        'stageId': stageId,
        'stageName': stageName,
        if (alternativeStageIds.isNotEmpty) 'alternativeStageIds': alternativeStageIds,
        if (alternativeStageNames.isNotEmpty) 'alternativeStageNames': alternativeStageNames,
        if (comment != null && comment!.isNotEmpty) 'comment': comment,
      };

  factory PlannedStage.fromMap(Map<String, dynamic> map) => PlannedStage(
        stageId: map['stageId'] as String,
        stageName: map['stageName'] as String? ?? '',
        alternativeStageIds: (map['alternativeStageIds'] as List?)
                ?.whereType<dynamic>()
                .map((e) => e.toString())
                .toList() ??
            const [],
        alternativeStageNames: (map['alternativeStageNames'] as List?)
                ?.whereType<dynamic>()
                .map((e) => e.toString())
                .toList() ??
            const [],
        comment: map['comment'] as String?,
      );
}
/// Decodes a dynamic value retrieved from Firebase into a list of
/// [PlannedStage] objects. Firebase can return either a List or a Map for
/// arrays depending on how the data was stored, so this helper normalises the
/// format for further processing.
List<PlannedStage> decodePlannedStages(dynamic stagesData) {
  final result = <PlannedStage>[];
  if (stagesData is List) {
    for (final item in stagesData.whereType<Map>()) {
      result.add(
          PlannedStage.fromMap(Map<String, dynamic>.from(item as Map)));
    }
  } else if (stagesData is Map) {
    stagesData.forEach((_, value) {
      if (value is Map) {
        result.add(
            PlannedStage.fromMap(Map<String, dynamic>.from(value as Map)));
      }
    });
  }
  return result;
}