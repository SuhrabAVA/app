enum TaskStatus { waiting, inProgress, paused, completed, problem }

class TaskModel {
  final String id;
  final String orderId;
  final String stageId;
  final TaskStatus status;
  final int spentSeconds;
  final int? startedAt;

  TaskModel({
    required this.id,
    required this.orderId,
    required this.stageId,
    this.status = TaskStatus.waiting,
    this.spentSeconds = 0,
    this.startedAt,
  });

  Map<String, dynamic> toMap() => {
        'orderId': orderId,
        'stageId': stageId,
        'status': status.name,
        'spentSeconds': spentSeconds,
        if (startedAt != null) 'startedAt': startedAt,
      };

  factory TaskModel.fromMap(Map<String, dynamic> map, String id) => TaskModel(
        id: id,
        orderId: map['orderId'] as String,
        stageId: map['stageId'] as String,
        status:
            TaskStatus.values.byName(map['status'] as String? ?? 'waiting'),
        spentSeconds: map['spentSeconds'] as int? ?? 0,
        startedAt: map['startedAt'] as int?,
      );

  TaskModel copyWith({
    TaskStatus? status,
    int? spentSeconds,
    int? startedAt,
  }) =>
      TaskModel(
        id: id,
        orderId: orderId,
        stageId: stageId,
        status: status ?? this.status,
        spentSeconds: spentSeconds ?? this.spentSeconds,
        startedAt: startedAt ?? this.startedAt,
      );
}
