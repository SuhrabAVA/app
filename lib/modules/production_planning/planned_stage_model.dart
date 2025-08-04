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
