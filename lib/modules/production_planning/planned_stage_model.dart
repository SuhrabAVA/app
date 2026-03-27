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
      _dedupeOrdered(
        [stageId, ...alternativeStageIds],
        caseInsensitive: true,
      );

  List<String> get allStageNames =>
      _dedupeOrdered(
        [stageName, ...alternativeStageNames],
        caseInsensitive: true,
      );

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
        stageName: (map['stageName'] as String? ?? '').trim(),
        alternativeStageIds: _dedupeOrdered(
          (map['alternativeStageIds'] as List?)
                ?.whereType<dynamic>()
                .map((e) => e.toString())
                .toList() ??
              const [],
          caseInsensitive: true,
        ),
        alternativeStageNames: _dedupeOrdered(
          (map['alternativeStageNames'] as List?)
                ?.whereType<dynamic>()
                .map((e) => e.toString())
                .toList() ??
              const [],
          caseInsensitive: true,
        ),
        comment: map['comment'] as String?,
      );
}

List<String> _dedupeOrdered(
  List<String> values, {
  bool caseInsensitive = false,
}) {
  final seen = <String>{};
  final result = <String>[];
  for (final value in values) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) continue;
    final key = caseInsensitive ? trimmed.toLowerCase() : trimmed;
    if (!seen.add(key)) continue;
    result.add(trimmed);
  }
  return result;
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
    final entries = stagesData.entries.toList()
      ..sort((a, b) {
        final ak = int.tryParse(a.key.toString());
        final bk = int.tryParse(b.key.toString());
        if (ak != null && bk != null) return ak.compareTo(bk);
        if (ak != null) return -1;
        if (bk != null) return 1;
        return a.key.toString().compareTo(b.key.toString());
      });
    for (final entry in entries) {
      final value = entry.value;
      if (value is Map) {
        result.add(
            PlannedStage.fromMap(Map<String, dynamic>.from(value as Map)));
      }
    }
  }
  return result;
}
