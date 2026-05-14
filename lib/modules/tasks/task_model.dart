import 'dart:convert';

/// Возможные статусы задачи.
enum TaskStatus { waiting, inProgress, paused, completed, problem }

/// Типы интервалов времени по задаче.
enum TaskTimeType { production, pause, problem, shiftChange, setup }

TaskTimeType? _parseTaskTimeType(String raw) {
  final value = raw.trim().toLowerCase();
  switch (value) {
    case 'production':
    case 'work':
    case 'produce':
      return TaskTimeType.production;
    case 'pause':
    case 'break':
      return TaskTimeType.pause;
    case 'problem':
    case 'issue':
      return TaskTimeType.problem;
    case 'shift_change':
    case 'shiftchange':
    case 'shift':
      return TaskTimeType.shiftChange;
    case 'setup':
    case 'naladka':
      return TaskTimeType.setup;
  }
  return null;
}

String taskTimeTypeToString(TaskTimeType type) {
  switch (type) {
    case TaskTimeType.production:
      return 'production';
    case TaskTimeType.pause:
      return 'pause';
    case TaskTimeType.problem:
      return 'problem';
    case TaskTimeType.shiftChange:
      return 'shift_change';
    case TaskTimeType.setup:
      return 'setup';
  }
}

/// Событие учёта времени по задаче.
class TaskTimeEvent {
  final String id;
  final TaskTimeType type;
  final DateTime startTime;
  final DateTime? endTime;
  final String initiatedBy;
  final String subjectUserId;
  final String taskId;
  final String workplaceId;
  final List<String> participantsSnapshot;
  final String? executionMode;
  final String? helperId;
  final String? note;

  const TaskTimeEvent({
    required this.id,
    required this.type,
    required this.startTime,
    required this.endTime,
    required this.initiatedBy,
    required this.subjectUserId,
    required this.taskId,
    required this.workplaceId,
    required this.participantsSnapshot,
    this.executionMode,
    this.helperId,
    this.note,
  });

  TaskTimeEvent copyWith({
    TaskTimeType? type,
    DateTime? startTime,
    DateTime? endTime,
    String? initiatedBy,
    String? subjectUserId,
    String? taskId,
    String? workplaceId,
    List<String>? participantsSnapshot,
    String? executionMode,
    String? helperId,
    String? note,
  }) {
    return TaskTimeEvent(
      id: id,
      type: type ?? this.type,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      initiatedBy: initiatedBy ?? this.initiatedBy,
      subjectUserId: subjectUserId ?? this.subjectUserId,
      taskId: taskId ?? this.taskId,
      workplaceId: workplaceId ?? this.workplaceId,
      participantsSnapshot: participantsSnapshot ?? this.participantsSnapshot,
      executionMode: executionMode ?? this.executionMode,
      helperId: helperId ?? this.helperId,
      note: note ?? this.note,
    );
  }

  Map<String, dynamic> toMap() => {
        'type': taskTimeTypeToString(type),
        'startTime': startTime.toUtc().toIso8601String(),
        if (endTime != null) 'endTime': endTime!.toUtc().toIso8601String(),
        'initiatedBy': initiatedBy,
        'subjectUserId': subjectUserId,
        'taskId': taskId,
        'workplaceId': workplaceId,
        'participantsSnapshot': participantsSnapshot,
        if (executionMode != null) 'executionMode': executionMode,
        if (helperId != null) 'helperId': helperId,
        if (note != null) 'note': note,
      };

  static TaskTimeEvent? fromPayload(
      String payload, String id, int timestamp, String userId) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      final rawType = (map['type'] ?? '').toString();
      final type = _parseTaskTimeType(rawType);
      if (type == null) return null;
      DateTime? parseTime(dynamic value) {
        if (value == null) return null;
        if (value is DateTime) return value.toUtc();
        if (value is String && value.trim().isNotEmpty) {
          try {
            return DateTime.parse(value).toUtc();
          } catch (_) {}
        }
        return null;
      }

      final start = parseTime(map['startTime']) ??
          DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true);
      final end = parseTime(map['endTime']);
      final participants = <String>[];
      final rawParticipants = map['participantsSnapshot'];
      if (rawParticipants is List) {
        participants.addAll(rawParticipants.map((e) => e.toString()));
      }
      return TaskTimeEvent(
        id: id,
        type: type,
        startTime: start,
        endTime: end,
        initiatedBy: map['initiatedBy']?.toString() ?? userId,
        subjectUserId: map['subjectUserId']?.toString() ?? userId,
        taskId: map['taskId']?.toString() ?? '',
        workplaceId: map['workplaceId']?.toString() ?? '',
        participantsSnapshot: participants,
        executionMode: map['executionMode']?.toString(),
        helperId: map['helperId']?.toString(),
        note: map['note']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }

  static String encodePayload(TaskTimeEvent event) {
    return jsonEncode(event.toMap());
  }
}

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
    int _parseTs(dynamic value) {
      if (value == null) return 0;
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is DateTime) return value.millisecondsSinceEpoch;
      if (value is String) {
        final raw = value.trim();
        if (raw.isEmpty) return 0;
        final intVal = int.tryParse(raw);
        if (intVal != null) return intVal;
        final doubleVal = double.tryParse(raw);
        if (doubleVal != null) return doubleVal.toInt();
        final parsedDate = DateTime.tryParse(raw);
        if (parsedDate != null) return parsedDate.millisecondsSinceEpoch;
      }
      return 0;
    }

    return TaskComment(
      id: id,
      type: map['type'] as String? ?? '',
      text: map['text'] as String? ?? '',
      userId: map['userId'] as String? ?? '',
      timestamp: _parseTs(map['timestamp']),
    );
  }

  Map<String, dynamic> toMap() => {
        'type': type,
        'text': text,
        'userId': userId,
        'timestamp': timestamp,
      };
}


class TaskCommentAttachment {
  final String id;
  final String taskId;
  final String orderId;
  final String stageId;
  final String commentId;
  final String userId;
  final String fileType;
  final String fileName;
  final String storagePath;
  final String? fileUrl;
  final String mimeType;
  final int sizeBytes;
  final DateTime createdAt;

  const TaskCommentAttachment({
    required this.id,
    required this.taskId,
    required this.orderId,
    required this.stageId,
    required this.commentId,
    required this.userId,
    required this.fileType,
    required this.fileName,
    required this.storagePath,
    this.fileUrl,
    required this.mimeType,
    required this.sizeBytes,
    required this.createdAt,
  });

  factory TaskCommentAttachment.fromMap(Map<String, dynamic> map) {
    int parseSize(dynamic value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value) ?? 0;
      return 0;
    }

    DateTime parseCreatedAt(dynamic value) {
      if (value is DateTime) return value;
      if (value is String) {
        return DateTime.tryParse(value) ?? DateTime.now();
      }
      return DateTime.now();
    }

    return TaskCommentAttachment(
      id: (map['id'] ?? '').toString(),
      taskId: (map['task_id'] ?? map['taskId'] ?? '').toString(),
      orderId: (map['order_id'] ?? map['orderId'] ?? '').toString(),
      stageId: (map['stage_id'] ?? map['stageId'] ?? '').toString(),
      commentId: (map['comment_id'] ?? map['commentId'] ?? '').toString(),
      userId: (map['user_id'] ?? map['userId'] ?? '').toString(),
      fileType: (map['file_type'] ?? map['fileType'] ?? 'file').toString(),
      fileName: (map['file_name'] ?? map['fileName'] ?? 'attachment').toString(),
      storagePath: (map['storage_path'] ?? map['storagePath'] ?? '').toString(),
      fileUrl: (map['file_url'] ?? map['fileUrl'])?.toString(),
      mimeType: (map['mime_type'] ?? map['mimeType'] ?? 'application/octet-stream').toString(),
      sizeBytes: parseSize(map['size_bytes'] ?? map['sizeBytes']),
      createdAt: parseCreatedAt(map['created_at'] ?? map['createdAt']),
    );
  }

  TaskCommentAttachment copyWith({String? fileUrl}) {
    return TaskCommentAttachment(
      id: id,
      taskId: taskId,
      orderId: orderId,
      stageId: stageId,
      commentId: commentId,
      userId: userId,
      fileType: fileType,
      fileName: fileName,
      storagePath: storagePath,
      fileUrl: fileUrl ?? this.fileUrl,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'task_id': taskId,
        'order_id': orderId,
        'stage_id': stageId,
        'comment_id': commentId,
        'user_id': userId,
        'file_type': fileType,
        'file_name': fileName,
        'storage_path': storagePath,
        'file_url': fileUrl,
        'mime_type': mimeType,
        'size_bytes': sizeBytes,
        'created_at': createdAt.toUtc().toIso8601String(),
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
  /// Общий ключ этапа для группы альтернативных рабочих мест.
  /// Для одиночного этапа равен `stageId`.
  final String stageGroupKey;
  /// Фактическое рабочее место, которое первым "захватило" этап.
  final String? capturedByWorkplaceId;
  /// Пользователь, который первым начал этап (если известен).
  final String? capturedByUserId;
  /// Время захвата этапа первым рабочим местом.
  final int? capturedAt;
  final TaskStatus status;
  final int spentSeconds;
  final int? startedAt;
  final List<String> assignees;
  final List<TaskComment> comments;

  TaskModel({
    required this.id,
    required this.orderId,
    required this.stageId,
    String? stageGroupKey,
    this.capturedByWorkplaceId,
    this.capturedByUserId,
    this.capturedAt,
    this.status = TaskStatus.waiting,
    this.spentSeconds = 0,
    this.startedAt,
    this.assignees = const [],
    this.comments = const [],
  }) : stageGroupKey = (stageGroupKey == null || stageGroupKey.trim().isEmpty)
            ? stageId
            : stageGroupKey.trim();

  /// Преобразует задачу в Map для сохранения в Firebase. Комментарии
  /// сохраняются как подузел comments со случайными ключами, поэтому в
  /// корневой записи задачи хранится только список исполнителей и
  /// обязательные поля.
  Map<String, dynamic> toMap() => {
        'orderId': orderId,
        'stageId': stageId,
        'stageGroupKey': stageGroupKey,
        'queueStageKey': stageGroupKey,
        if (capturedByWorkplaceId != null)
          'capturedByWorkplaceId': capturedByWorkplaceId,
        if (capturedByUserId != null) 'capturedByUserId': capturedByUserId,
        if (capturedAt != null) 'capturedAt': capturedAt,
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
  // Берём первое непустое значение по списку ключей
  dynamic pick(List<String> keys) {
    for (final k in keys) {
      if (map.containsKey(k) && map[k] != null) return map[k];
    }
    return null;
  }

  int? toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  // assignees
  List<String> assignees = const [];
  final a = map['assignees'];
  if (a is List) {
    assignees = a.map((e) => e.toString()).toList();
  }

  // comments
  List<TaskComment> comments = [];
  final commentsData = map['comments'];
  if (commentsData is Map) {
    commentsData.forEach((key, value) {
      final data = Map<String, dynamic>.from(value as Map);
      comments.add(TaskComment.fromMap(data, key));
    });
    comments.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  // поля с разными названиями
  // orderId и stageId могут быть как строками, так и числами в исходных данных,
  // поэтому приводим найденное значение к строке через `toString()`.
  String _normalizeId(dynamic value) {
    final raw = value?.toString() ?? '';
    return raw.trim();
  }

  final orderId = _normalizeId(pick(['orderId', 'order_id', 'orderid']));
  
  final stageId = _normalizeId(
    pick(['stageId', 'stage_id', 'stageid', 'workplaceId', 'workplace_id']),
  );
  final stageGroupKey = _normalizeId(pick([
    'stageGroupKey',
    'stage_group_key',
    'queueStageKey',
    'queue_stage_key',
  ]));
  final capturedByWorkplaceId = _normalizeId(
    pick(['capturedByWorkplaceId', 'captured_by_workplace_id']),
  );
  final capturedByUserId = _normalizeId(
    pick(['capturedByUserId', 'captured_by_user_id']),
  );

  final statusStr = (map['status'] as String?) ?? 'waiting';
  TaskStatus status;
  try {
    status = TaskStatus.values.byName(statusStr);
  } catch (_) {
    status = TaskStatus.waiting;
  }

  final spentSeconds =
      toInt(pick(['spentSeconds','spent_seconds','spentseconds'])) ?? 0;
  final startedAt =
      toInt(pick(['startedAt','started_at','startedat']));

  return TaskModel(
    id: id,
    orderId: orderId,
    stageId: stageId,
    stageGroupKey: stageGroupKey.isEmpty ? stageId : stageGroupKey,
    capturedByWorkplaceId:
        capturedByWorkplaceId.isEmpty ? null : capturedByWorkplaceId,
    capturedByUserId: capturedByUserId.isEmpty ? null : capturedByUserId,
    capturedAt: toInt(pick(['capturedAt', 'captured_at'])),
    status: status,
    spentSeconds: spentSeconds,
    startedAt: startedAt,
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
    bool clearStartedAt = false,
    String? stageGroupKey,
    String? capturedByWorkplaceId,
    String? capturedByUserId,
    int? capturedAt,
    List<String>? assignees,
    List<TaskComment>? comments,
  }) {
    return TaskModel(
      id: id,
      orderId: orderId,
      stageId: stageId,
      stageGroupKey: stageGroupKey ?? this.stageGroupKey,
      capturedByWorkplaceId: capturedByWorkplaceId ?? this.capturedByWorkplaceId,
      capturedByUserId: capturedByUserId ?? this.capturedByUserId,
      capturedAt: capturedAt ?? this.capturedAt,
      status: status ?? this.status,
      spentSeconds: spentSeconds ?? this.spentSeconds,
      startedAt: clearStartedAt ? null : (startedAt ?? this.startedAt),
      assignees: assignees ?? this.assignees,
      comments: comments ?? this.comments,
    );
  }
}
