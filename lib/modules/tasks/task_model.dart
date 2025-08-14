/// Возможные статусы задачи.
enum TaskStatus { waiting, inProgress, paused, completed, problem }

/// Модель комментария к задаче. Каждый комментарий хранит тип (pause/problem),
/// текст, идентификатор автора и временную метку. Используется для
/// информирования технического лидера о причинах пауз и проблем на этапе.
class TaskComment {
  final String id;
  final String type;
  final String text;
  final String userId;
  final int timestamp;

  TaskComment({
    required this.id,
    required this.type,
    required this.text,
    required this.userId,
    required this.timestamp,
  });

  factory TaskComment.fromMap(Map<String, dynamic> map, String id) {
    return TaskComment(
      id: id,
      type: map['type'] as String? ?? '',
      text: map['text'] as String? ?? '',
      userId: map['userId'] as String? ?? '',
      timestamp: map['timestamp'] is int ? map['timestamp'] as int : 0,
    );
  }

  Map<String, dynamic> toMap() => {
        'type': type,
        'text': text,
        'userId': userId,
        'timestamp': timestamp,
      };
}

/// Модель задачи, назначенной на рабочее место и конкретный этап заказа.
///
/// Каждая задача содержит ссылку на заказ, идентификатор этапа, список
/// исполнителей, статус, затраченное время, время начала и список
/// комментариев, оставленных сотрудниками (например, причины пауз/проблем).
class TaskModel {
  final String id;
  final String orderId;
  final String stageId;
  final TaskStatus status;
  final int spentSeconds;
  final int? startedAt;
  final List<String> assignees;
  final List<TaskComment> comments;

  TaskModel({
    required this.id,
    required this.orderId,
    required this.stageId,
    this.status = TaskStatus.waiting,
    this.spentSeconds = 0,
    this.startedAt,
    this.assignees = const [],
    this.comments = const [],
  });

  /// Преобразует задачу в Map для сохранения в Firebase. Комментарии
  /// сохраняются как подузел comments со случайными ключами, поэтому в
  /// корневой записи задачи хранится только список исполнителей и
  /// обязательные поля.
  Map<String, dynamic> toMap() => {
        'orderId': orderId,
        'stageId': stageId,
        'status': status.name,
        'spentSeconds': spentSeconds,
        if (startedAt != null) 'startedAt': startedAt,
        if (assignees.isNotEmpty) 'assignees': assignees,
        if (comments.isNotEmpty)
          'comments': {
            for (final c in comments) c.id: c.toMap(),
          },
      };

  /// Создаёт модель задачи из Firebase. При чтении комментариев из базы
  /// используется Map, где ключи — это push-ключи Firebase. Комментарии
  /// сортируются по возрастанию временной метки.
  factory TaskModel.fromMap(Map<String, dynamic> map, String id) {
    List<String> assignees = const [];
    if (map['assignees'] is List) {
      assignees = List<String>.from(
          (map['assignees'] as List).map((e) => e.toString()));
    }
    // Parse comments if present.
    List<TaskComment> comments = [];
    final commentsData = map['comments'];
    if (commentsData is Map) {
      commentsData.forEach((key, value) {
        final data = Map<String, dynamic>.from(value as Map);
        comments.add(TaskComment.fromMap(data, key));
      });
      comments.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    }
    return TaskModel(
      id: id,
      orderId: map['orderId'] as String,
      stageId: map['stageId'] as String,
      status: TaskStatus.values
          .byName(map['status'] as String? ?? 'waiting'),
      spentSeconds: map['spentSeconds'] as int? ?? 0,
      startedAt: map['startedAt'] as int?,
      assignees: assignees,
      comments: comments,
    );
  }

  /// Создаёт копию задачи с обновлёнными полями. Для сохранения текущих
  /// комментариев передайте [comments], иначе будут использованы существующие.
  TaskModel copyWith({
    TaskStatus? status,
    int? spentSeconds,
    int? startedAt,
    List<String>? assignees,
    List<TaskComment>? comments,
  }) {
    return TaskModel(
      id: id,
      orderId: orderId,
      stageId: stageId,
      status: status ?? this.status,
      spentSeconds: spentSeconds ?? this.spentSeconds,
      startedAt: startedAt ?? this.startedAt,
      assignees: assignees ?? this.assignees,
      comments: comments ?? this.comments,
    );
  }
}