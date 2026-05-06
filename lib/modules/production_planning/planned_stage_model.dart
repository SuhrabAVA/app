class PlannedStage {
  final String stageId;
  final String stageName;
  final List<String> workplaceIds;
  final List<String> alternativeStageIds;
  final List<String> alternativeStageNames;
  String? comment;

  PlannedStage({
    required this.stageId,
    required this.stageName,
    List<String>? workplaceIds,
    List<String> alternativeStageIds = const [],
    this.alternativeStageNames = const [],
    this.comment,
  })  : workplaceIds = workplaceIds == null || workplaceIds.isEmpty
            ? _dedupeOrdered(
                [stageId, ...alternativeStageIds],
                caseInsensitive: true,
              )
            : _dedupeOrdered(workplaceIds, caseInsensitive: true),
        alternativeStageIds = (workplaceIds == null || workplaceIds.isEmpty
                ? _dedupeOrdered(
                    [stageId, ...alternativeStageIds],
                    caseInsensitive: true,
                  )
                : _dedupeOrdered(workplaceIds, caseInsensitive: true))
            .skip(1)
            .toList();

  List<String> get allStageIds =>
      _dedupeOrdered(
        workplaceIds.isNotEmpty ? workplaceIds : [stageId, ...alternativeStageIds],
        caseInsensitive: true,
      );

  List<String> get allStageNames =>
      _dedupeOrdered(
        [stageName, ...alternativeStageNames],
        caseInsensitive: true,
      );

  PlannedStage copyWith({
    String? comment,
    List<String>? workplaceIds,
    List<String>? alternativeStageIds,
    List<String>? alternativeStageNames,
  }) =>
      PlannedStage(
        stageId: stageId,
        stageName: stageName,
        workplaceIds: workplaceIds ?? this.workplaceIds,
        alternativeStageIds: alternativeStageIds ?? this.alternativeStageIds,
        alternativeStageNames: alternativeStageNames ?? this.alternativeStageNames,
        comment: comment ?? this.comment,
      );

  Map<String, dynamic> toMap() => {
        'stageId': allStageIds.isNotEmpty ? allStageIds.first : stageId,
        'workplaceId': allStageIds.isNotEmpty ? allStageIds.first : stageId,
        'workplaceIds': allStageIds,
        'stageName': stageName,
        if (allStageIds.length > 1) 'alternativeStageIds': allStageIds.skip(1).toList(),
        if (alternativeStageNames.isNotEmpty) 'alternativeStageNames': alternativeStageNames,
        if (comment != null && comment!.isNotEmpty) 'comment': comment,
      };

  factory PlannedStage.fromMap(Map<String, dynamic> map) {
    final primary = (map['stageId'] ??
                map['stage_id'] ??
                map['workplaceId'] ??
                map['workplace_id'] ??
                map['id'])
            ?.toString() ??
        '';
    final explicitWorkplaces =
        _readStringList(map['workplaceIds'] ?? map['workplace_ids']);
    final legacyAlternatives = _readStringList(
      map['alternativeStageIds'] ?? map['alternative_stage_ids'],
    );
    final workplaces = explicitWorkplaces.isNotEmpty
        ? explicitWorkplaces
        : _dedupeOrdered([primary, ...legacyAlternatives],
            caseInsensitive: true);
    final stageName = (map['stageName'] ?? map['stage_name'] ?? '').toString();
    return PlannedStage(
      stageId: workplaces.isNotEmpty ? workplaces.first : primary,
      stageName: stageName.trim(),
      workplaceIds: workplaces,
      alternativeStageIds:
          workplaces.length > 1 ? workplaces.skip(1).toList() : const [],
      alternativeStageNames: _dedupeOrdered(
        _readStringList(
          map['alternativeStageNames'] ?? map['alternative_stage_names'],
        ),
        caseInsensitive: true,
      ),
      comment: map['comment'] as String?,
    );
  }
}

List<String> _readStringList(dynamic raw) {
  if (raw is List) {
    return raw.map((e) => e.toString()).toList();
  }
  if (raw is String && raw.trim().isNotEmpty) {
    return raw.split(',').map((e) => e.trim()).toList();
  }
  return const [];
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
