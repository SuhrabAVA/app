class ClaimModel {
  final String id;

  /// Заказ, к которому относится претензия (для source == 'order').
  /// Претензии из чата к заказу не привязаны.
  final String? orderId;
  final String? commentId;
  final String employeeId;
  final String? workplaceId;
  final String? description;
  final String? createdBy;
  final DateTime createdAt;

  /// Откуда создана претензия: 'order' | 'chat'.
  final String source;

  /// Ссылка на сообщение чата (chat_messages.id) для source == 'chat'.
  final String? messageId;

  /// Денормализованная ссылка на медиа сообщения: переживает очистку чата.
  final String? fileUrl;
  final String? fileMime;

  /// Читаемое имя автора (created_by хранит app-id вида 'tech_leader').
  final String? authorName;

  const ClaimModel({
    required this.id,
    this.orderId,
    this.commentId,
    required this.employeeId,
    this.workplaceId,
    this.description,
    this.createdBy,
    required this.createdAt,
    this.source = 'order',
    this.messageId,
    this.fileUrl,
    this.fileMime,
    this.authorName,
  });

  factory ClaimModel.fromMap(Map<String, dynamic> map) {
    DateTime parseDt(dynamic v) {
      if (v is DateTime) return v;
      if (v is String) return DateTime.tryParse(v) ?? DateTime.now();
      return DateTime.now();
    }

    String? nullable(dynamic v) {
      final s = v?.toString();
      return (s == null || s.isEmpty) ? null : s;
    }

    return ClaimModel(
      id: (map['id'] ?? '').toString(),
      orderId: nullable(map['order_id']),
      commentId: nullable(map['comment_id']),
      employeeId: (map['employee_id'] ?? '').toString(),
      workplaceId: nullable(map['workplace_id']),
      description: nullable(map['description']),
      createdBy: nullable(map['created_by']),
      createdAt: parseDt(map['created_at']),
      source: nullable(map['source']) ?? 'order',
      messageId: nullable(map['message_id']),
      fileUrl: nullable(map['file_url']),
      fileMime: nullable(map['file_mime']),
      authorName: nullable(map['author_name']),
    );
  }
}
