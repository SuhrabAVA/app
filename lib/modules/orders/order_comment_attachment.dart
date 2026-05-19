class OrderCommentAttachment {
  final String id;
  final String orderId;
  final String commentId;
  final String fileName;
  final String storagePath;
  final String mimeType;
  final int sizeBytes;
  final String attachmentType;
  final String uploadedBy;
  final DateTime createdAt;
  final String? fileUrl;

  const OrderCommentAttachment({
    required this.id,
    required this.orderId,
    required this.commentId,
    required this.fileName,
    required this.storagePath,
    required this.mimeType,
    required this.sizeBytes,
    required this.attachmentType,
    required this.uploadedBy,
    required this.createdAt,
    this.fileUrl,
  });

  factory OrderCommentAttachment.fromMap(Map<String, dynamic> map) {
    int parseSize(dynamic value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value) ?? 0;
      return 0;
    }

    DateTime parseCreatedAt(dynamic value) {
      if (value is DateTime) return value;
      if (value is String) return DateTime.tryParse(value) ?? DateTime.now();
      return DateTime.now();
    }

    return OrderCommentAttachment(
      id: (map['id'] ?? '').toString(),
      orderId: (map['order_id'] ?? map['orderId'] ?? '').toString(),
      commentId: (map['comment_id'] ?? map['commentId'] ?? '').toString(),
      fileName: (map['file_name'] ?? map['fileName'] ?? 'attachment').toString(),
      storagePath: (map['storage_path'] ?? map['storagePath'] ?? '').toString(),
      mimeType: (map['mime_type'] ?? map['mimeType'] ?? 'application/octet-stream').toString(),
      sizeBytes: parseSize(map['size_bytes'] ?? map['sizeBytes']),
      attachmentType: (map['attachment_type'] ?? map['attachmentType'] ?? 'file').toString(),
      uploadedBy: (map['uploaded_by'] ?? map['uploadedBy'] ?? '').toString(),
      createdAt: parseCreatedAt(map['created_at'] ?? map['createdAt']),
      fileUrl: (map['file_url'] ?? map['fileUrl'])?.toString(),
    );
  }

  OrderCommentAttachment copyWith({String? fileUrl}) {
    return OrderCommentAttachment(
      id: id,
      orderId: orderId,
      commentId: commentId,
      fileName: fileName,
      storagePath: storagePath,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      attachmentType: attachmentType,
      uploadedBy: uploadedBy,
      createdAt: createdAt,
      fileUrl: fileUrl ?? this.fileUrl,
    );
  }
}
