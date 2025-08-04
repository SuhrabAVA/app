class PlannedStage {
  final String stageId;
  String? comment;

  PlannedStage({required this.stageId, this.comment});

  PlannedStage copyWith({String? comment, String? photoUrl}) => PlannedStage(
        stageId: stageId,
        comment: comment ?? this.comment,
        photoUrl: photoUrl ?? this.photoUrl,
      );

  Map<String, dynamic> toMap() => {
        'stageId': stageId,
        if (comment != null && comment!.isNotEmpty) 'comment': comment,
      };

  factory PlannedStage.fromMap(Map<String, dynamic> map) =>
      PlannedStage(
        stageId: map['stageId'] as String,
        comment: map['comment'] as String?,
      );
}
