class PlannedStage {
  final String stageId;
  final String stageName;
  String? comment;

  PlannedStage({
    required this.stageId,
    required this.stageName,
    this.comment,
  });

  PlannedStage copyWith({String? comment}) => PlannedStage(
        stageId: stageId,
        stageName: stageName,
        comment: comment ?? this.comment,
      );

  Map<String, dynamic> toMap() => {
        'stageId': stageId,
        'stageName': stageName,
        if (comment != null && comment!.isNotEmpty) 'comment': comment,
      };

  factory PlannedStage.fromMap(Map<String, dynamic> map) => PlannedStage(
        stageId: map['stageId'] as String,
        stageName: map['stageName'] as String? ?? '',
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